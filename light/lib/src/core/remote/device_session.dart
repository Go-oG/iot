import 'dart:async';

import '../protocol/protocol.dart';
import '../protocol/remote_protocol.dart';
import '../remote_gateway.dart';

/// 只做设备专属编解码的会话：订阅自有写步骤的确认并回报结果
///
/// 传输、订阅与事件转发都由 [RemoteGateway] 完成，这里不碰 MQTT 细节。
class DeviceRemoteSession implements RemoteDeviceSession {
  DeviceRemoteSession({
    required RemoteGateway gateway,
    required RemoteDeviceCodec codec,
    required this.deviceId,
    this.ackWindow = const Duration(seconds: 1),
  }) : _gateway = gateway,
       _codec = codec;

  final RemoteGateway _gateway;
  final RemoteDeviceCodec _codec;
  final String deviceId;

  /// 写入成功后等待设备回报或确认的窗口
  final Duration ackWindow;

  bool _executing = false;
  bool _disposed = false;

  @override
  bool get ready =>
      !_disposed &&
      _gateway.client.connected &&
      _gateway.client.device(deviceId)?.connected == true;

  @override
  Future<RemoteCommandResult> execute(
    DeviceCommand command,
    Map<String, Object?> payload,
  ) async {
    if (_disposed) throw StateError('会话已关闭');
    if (_executing) throw StateError('请等待当前命令完成');
    final frames = _frameMap(_codec.buildRemoteSteps(command, payload));
    _executing = true;
    try {
      return await _write(frames);
    } finally {
      _executing = false;
    }
  }

  /// 先订阅再写入，命令字节用于把回报归属到具体命令
  Future<RemoteCommandResult> _write(Map<int, _Frame> frames) async {
    final acknowledgements = <int, RemoteDecodedFrame>{};
    final done = Completer<void>();
    final listener = _gateway.events.listen((event) {
      if (_disposed || event.retained) return;
      if (event.op != GatewayOption.notify || event.deviceId != deviceId) {
        return;
      }
      final value = event.value;
      final service = event.service;
      final characteristic = event.characteristic;
      if (value == null || service == null || characteristic == null) return;
      if (!_sameUuid(service, _codec.remoteService) ||
          !_sameUuid(characteristic, _codec.remoteCharacteristic)) {
        return;
      }
      final decoded = _decode(value, event.message.format);
      if (decoded == null || !frames.containsKey(decoded.commandByte)) return;
      acknowledgements[decoded.commandByte] = decoded;
      if (acknowledgements.length == frames.length && !done.isCompleted) {
        done.complete();
      }
    });
    try {
      final response = await _batch(frames);
      await done.future.timeout(ackWindow, onTimeout: () {});
      if (acknowledgements.values.any((frame) => !frame.accepted)) {
        throw RemoteCommandRejected('设备返回失败确认');
      }
      return RemoteCommandResult(
        commandId: response.reqId ?? '',
        // 设备会选择性回报，拿到任意一条接受确认就不算静默写入
        confirmation: acknowledgements.isEmpty
            ? RemoteConfirmation.written
            : RemoteConfirmation.deviceAck,
      );
    } finally {
      await listener.cancel();
    }
  }

  /// 订阅与写入合并成一次批量请求，失败步骤直接暴露给上层
  Future<GatewayMessage> _batch(Map<int, _Frame> frames) async {
    final response = await _gateway.checked(
      GatewayOption.batch,
      deviceId: deviceId,
      timeout: const Duration(seconds: 15),
      data: {
        GatewayField.stopOnError.wire: true,
        GatewayField.autoConnect.wire: false,
        GatewayField.steps.wire: [
          {
            GatewayField.id.wire: RemoteStep.subscribe.wire,
            GatewayField.op.wire: GatewayOption.subscribe.wire,
            GatewayField.service.wire: _codec.remoteService,
            GatewayField.char.wire: _codec.remoteCharacteristic,
            GatewayField.data.wire: {
              GatewayField.enabled.wire: true,
              GatewayField.mode.wire: GatewayNotifyMode.auto.wire,
              GatewayField.delivery.wire: GatewayDelivery.stream.wire,
            },
          },
          for (final frame in frames.values) frame.json,
        ],
      },
    );
    final results = <String, GatewayStepResult>{
      for (final step in response.steps) step.id: step,
    };
    final expected = [
      RemoteStep.subscribe.wire,
      for (final frame in frames.values) frame.id,
    ];
    for (final id in expected) {
      final result = results[id];
      if (result?.ok == true) continue;
      throw StateError('步骤 $id 未成功：${result?.error ?? '缺少结果'}');
    }
    return response;
  }

  RemoteDecodedFrame? _decode(String value, ValueFormat? format) {
    if (value.isEmpty) return null;
    try {
      return _codec.decodeRemoteFrame(
        ValueFormat.decode(value, format ?? ValueFormat.hex),
      );
    } on FormatException {
      // 与本设备无关或结构不符的报文直接忽略
      return null;
    }
  }

  /// 同一命令字节只保留一条写步骤，避免重复写
  Map<int, _Frame> _frameMap(List<RemoteWriteStep> steps) {
    final frames = <int, _Frame>{};
    for (var index = 0; index < steps.length; index++) {
      final step = steps[index];
      final bytes = step.bytes;
      if (bytes.length < 5) {
        throw RemoteCommandRejected(
          '${step.id} 的报文长度不足，无法识别命令字节',
          code: GatewayErrorCode.invalidArgument,
        );
      }
      frames[bytes[4]] = _Frame(
        id: step.id.isEmpty ? 'w$index' : step.id,
        step: step,
      );
    }
    return frames;
  }

  static bool _sameUuid(String left, String right) =>
      GatewayUuid.normalize(left) == GatewayUuid.normalize(right);

  @override
  Future<void> dispose() async {
    _disposed = true;
  }
}

class _Frame {
  const _Frame({required this.id, required this.step});

  final String id;
  final RemoteWriteStep step;

  Map<String, Object?> get json => step.toJson();
}
