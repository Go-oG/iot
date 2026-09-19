import 'dart:async';

import '../protocol/client.dart';
import '../protocol/protocol.dart';
import '../protocol/remote_protocol.dart';
import 'function_type.dart';
import 'generic_codec.dart';
import 'impl/generic_device.dart';

/// 一次远程命令的结果
class GenericCommandOutcome {
  const GenericCommandOutcome({
    required this.confirmation,
    this.appliedFunctions = const [],
    this.message,
  });

  final RemoteConfirmation confirmation;

  /// 本次回报并写入的功能类型
  final List<ConfigurableFunction> appliedFunctions;
  final String? message;
}

/// 把通用设备的编解码接到 MQTT 网关
///
/// 编解码全部在 App 内完成，网关只收到十六进制报文，与 At5Client 的下发路径一致。
/// 一个会话对应网关上的一台 BLE 设备。
class GenericDeviceSession implements RemoteDeviceSession {
  GenericDeviceSession({
    required this.client,
    required Map<String, Object?> config,
    required this.deviceId,
    this.ackWindow = const Duration(seconds: 1),
  }) {
    device = GenericDevice.fromJson(
      config,
      execute: _execute,
      refresh: _refresh,
      connect: _connect,
      disconnect: _disconnect,
    );
  }

  final GatewayClient client;
  final String deviceId;
  late final GenericDevice device;

  /// 写入成功后等待设备回报状态或确认的窗口
  final Duration ackWindow;

  StreamSubscription<GatewayEvent>? _events;
  bool _executing = false;
  bool _disposed = false;

  GenericCodec get codec => device.codec;

  /// 是否已经具备下发条件
  @override
  bool get ready =>
      !_disposed &&
      client.connected &&
      device.isConnection &&
      device.supportsRemoteControl;

  /// 通用设备按功能类型下发，整机状态命令由功能回调直接驱动
  @override
  Future<RemoteCommandResult> execute(
    DeviceCommand command,
    Map<String, Object?> payload,
  ) async {
    throw RemoteCommandRejected('通用设备需要按功能类型下发：${command.wire}');
  }

  /// 本机预览：只按功能规则校验并更新状态，不发出任何报文
  ///
  /// 供滑块拖动时使用，真实下发由 [executeFunction] 完成。
  bool applyPreview(ConfigurableFunction type, Object? value) =>
      device.applyReported(type, value);

  /// 按配置中的功能类型下发一次命令
  ///
  /// [value] 使用该功能的状态结构，例如电源用布尔值、灯光用通道对象。
  /// 类型不符会在功能内部被拒绝，不会发出报文。
  Future<bool> executeFunction(ConfigurableFunction type, Object value) async {
    final function = device.functionOf(type);
    if (function == null) throw UnsupportedError('设备没有声明功能 ${type.wire}');
    return await (function as dynamic).execute(device, value) as bool;
  }

  /// 连接设备并订阅需要通知的特征
  ///
  /// 走 [GenericDevice.connection]，连接成功后功能才允许下发。
  Future<void> start() async {
    if (!device.supportsRemoteControl) {
      throw UnsupportedError('设备配置没有声明 commands，无法远程读写');
    }
    await device.connection();
  }

  /// 断开设备；网关保留其他设备的连接
  Future<void> stop() async {
    await _events?.cancel();
    _events = null;
    if (device.isConnection) {
      await device.disConnection();
    } else if (client.connected) {
      await _checked(GatewayOption.disconnect);
    }
  }

  Future<bool> _connect(GenericDevice target) async {
    _listen();
    await _checked(
      GatewayOption.connect,
      timeout: const Duration(seconds: 15),
      data: {GatewayField.policy.wire: GatewayConnectPolicy.queue.wire},
    );
    await _subscribeAll();
    return true;
  }

  Future<bool> _disconnect(GenericDevice target) async {
    if (client.connected) await _checked(GatewayOption.disconnect);
    return true;
  }

  /// 订阅配置里声明的特征，重复调用只补充缺失的
  Future<void> _subscribeAll() async {
    final names = codec.subscribe;
    if (names.isEmpty) return;
    final steps = <Map<String, Object?>>[
      for (var index = 0; index < names.length; index++)
        {
          GatewayField.id.wire: RemoteStep.subscribe.indexed(index),
          GatewayField.op.wire: GatewayOption.subscribe.wire,
          GatewayField.service.wire: codec.chars[names[index]]!.service,
          GatewayField.char.wire: codec.chars[names[index]]!.char,
          GatewayField.data.wire: {
            GatewayField.enabled.wire: true,
            GatewayField.mode.wire: GatewayNotifyMode.auto.wire,
            GatewayField.delivery.wire: GatewayDelivery.stream.wire,
          },
        },
    ];
    final response = await _checked(
      GatewayOption.batch,
      timeout: const Duration(seconds: 15),
      data: {
        GatewayField.stopOnError.wire: false,
        GatewayField.steps.wire: steps,
      },
    );
    final failed = response.steps.where((step) => !step.ok).toList();
    if (failed.isNotEmpty) {
      throw GatewayError.fromCode(
        failed.first.code,
        '订阅特征失败：${failed.first.message ?? failed.first.id}',
      );
    }
  }

  void _listen() {
    _events ??= client.events.listen((event) {
      if (_disposed ||
          event.op != GatewayOption.notify ||
          event.deviceId != deviceId)
        return;
      final value = event.value;
      if (value == null) return;
      _applyBytes(
        ValueFormat.decode(value, event.message.format ?? ValueFormat.hex),
        charName: _charNameOf(event.service, event.characteristic),
      );
    });
  }

  /// 解析一帧报文并写回设备状态；无法归属或解析失败时静默忽略
  List<ConfigurableFunction> _applyBytes(List<int> bytes, {String? charName}) {
    GenericDecodedResponse? decoded;
    try {
      decoded = codec.decode(bytes, charName: charName);
    } on FormatException {
      return const [];
    }
    if (decoded == null || !decoded.isState) return const [];
    return device.applyReportedAll(decoded.values);
  }

  String? _charNameOf(String? service, String? characteristic) {
    if (service == null || characteristic == null) return null;
    final target = GenericCharacteristic(
      service: _normalize(service),
      char: _normalize(characteristic),
    );
    for (final entry in codec.chars.entries) {
      if (entry.value == target) return entry.key;
    }
    return null;
  }

  static String _normalize(String uuid) {
    final clean = uuid.trim().toLowerCase().replaceAll('-', '');
    return switch (clean.length) {
      4 => '0000$clean-0000-1000-8000-00805f9b34fb',
      8 => '$clean-0000-1000-8000-00805f9b34fb',
      32 =>
        '${clean.substring(0, 8)}-${clean.substring(8, 12)}-${clean.substring(12, 16)}-'
            '${clean.substring(16, 20)}-${clean.substring(20)}',
      _ => uuid.toLowerCase(),
    };
  }

  Future<bool> _execute(
    GenericDevice target,
    ConfigurableFunction type,
    Object value,
  ) async {
    if (_disposed) throw StateError('会话已关闭');
    final names = codec.writeCommandsFor([type]);
    if (names.isEmpty) {
      throw RemoteCommandRejected(
        '设备没有为 ${type.wire} 声明写命令',
        code: GatewayErrorCode.unsupportedOp,
      );
    }
    if (_executing) throw StateError('请等待当前命令完成');
    _executing = true;
    try {
      final outcome = await _writeAll(names, type, value);
      if (outcome.confirmation == RemoteConfirmation.ack &&
          outcome.message != null) {
        throw RemoteCommandRejected(
          outcome.message!,
          code: GatewayErrorCode.writeFailed,
        );
      }
      return true;
    } finally {
      _executing = false;
    }
  }

  /// 下发一组写命令
  ///
  /// 编码用的状态是「设备当前状态叠加本次新值」：被改动的功能取新值，
  /// 共享同一条命令的其它功能取各自最后已知的值，与 AT5 的组包行为一致。
  Future<GenericCommandOutcome> _writeAll(
    List<String> names,
    ConfigurableFunction type,
    Object? value,
  ) async {
    final state = <ConfigurableFunction, Object?>{
      ...device.status,
      type: value,
    };
    final pending = <int, String>{};
    for (final name in names) {
      final byte = codec.commands[name]!.command;
      if (byte != null) pending[byte] = name;
    }
    final outcomes = <String, GenericDecodedResponse>{};

    // 写入期间监听响应，命令字节用于把回报归属到具体命令
    final subscription = client.events.listen((event) {
      if (event.op != GatewayOption.notify || event.deviceId != deviceId)
        return;
      final text = event.value;
      if (text == null) return;
      try {
        final decoded = codec.decode(
          ValueFormat.decode(text, event.message.format ?? ValueFormat.hex),
          charName: _charNameOf(event.service, event.characteristic),
        );
        if (decoded == null) return;
        if (decoded.commandByte != null &&
            !pending.containsKey(decoded.commandByte))
          return;
        outcomes[decoded.commandName] = decoded;
      } on FormatException {
        // 与本设备无关或结构不符的报文直接忽略
      }
    });

    try {
      final steps = <Map<String, Object?>>[
        for (final name in names)
          {
            GatewayField.id.wire: RemoteStep.write.named(name),
            GatewayField.op.wire: GatewayOption.write.wire,
            GatewayField.service.wire: codec.commands[name]!.target.service,
            GatewayField.char.wire: codec.commands[name]!.target.char,
            GatewayField.value.wire: codec.encodeHex(name, state, value: value),
            GatewayField.format.wire: ValueFormat.hex.wire,
            GatewayField.data.wire: {
              GatewayField.writeType.wire: codec.commands[name]!.writeType.wire,
            },
          },
      ];
      final response = await _checked(
        GatewayOption.batch,
        timeout: const Duration(seconds: 15),
        data: {
          GatewayField.stopOnError.wire: true,
          GatewayField.autoConnect.wire: false,
          GatewayField.steps.wire: steps,
        },
      );
      for (final step in response.steps) {
        if (!step.ok) {
          throw GatewayError.fromCode(
            step.code,
            '${step.id} 未成功：${step.message ?? '缺少结果'}',
          );
        }
      }
      // 写入成功后再给设备一点时间回报状态或确认
      await Future<void>.delayed(ackWindow);

      final applied = <ConfigurableFunction>[];
      var confirmation = RemoteConfirmation.written;
      for (final entry in outcomes.entries) {
        if (entry.value.isState) {
          applied.addAll(device.applyReportedAll(entry.value.values));
          confirmation = RemoteConfirmation.deviceState;
        } else if (!entry.value.accepted) {
          return GenericCommandOutcome(
            confirmation: RemoteConfirmation.ack,
            message: '设备拒绝了 ${entry.key}',
          );
        } else if (confirmation != RemoteConfirmation.deviceState) {
          confirmation = RemoteConfirmation.ack;
        }
      }
      return GenericCommandOutcome(
        confirmation: confirmation,
        appliedFunctions: applied,
      );
    } finally {
      await subscription.cancel();
    }
  }

  /// 刷新功能值
  ///
  /// 状态主要由订阅到的通知更新；这里只在设备声明了主动读命令时补一次取值。
  Future<Object?> _refresh(
    GenericDevice target,
    ConfigurableFunction type,
  ) async {
    if (codec.polledCommands.isNotEmpty) await refreshAll();
    return target.status[type];
  }

  /// 主动读取所有声明了 `source: read` 的命令并写回状态
  Future<List<ConfigurableFunction>> refreshAll() async {
    final applied = <ConfigurableFunction>[];
    for (final name in codec.polledCommands) {
      final command = codec.commands[name]!;
      final response = await _checked(
        GatewayOption.read,
        service: command.target.service,
        characteristic: command.target.char,
        timeout: const Duration(seconds: 10),
      );
      final value = response.value;
      if (value == null) continue;
      applied.addAll(
        _applyBytes(
          ValueFormat.decode(value, response.format ?? ValueFormat.hex),
          charName: command.charName,
        ),
      );
    }
    return applied;
  }

  Future<GatewayMessage> _checked(
    GatewayOption op, {
    String? service,
    String? characteristic,
    Map<String, Object?>? data,
    Duration? timeout,
  }) async {
    if (!client.connected) throw StateError('请先连接 MQTT 服务器');
    final response = await client.request(
      op,
      deviceId: deviceId,
      service: service,
      characteristic: characteristic,
      data: data,
      timeout: timeout,
    );
    if (response.error != null) throw response.error!;
    return response;
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _events?.cancel();
    _events = null;
    device.dispose();
  }
}
