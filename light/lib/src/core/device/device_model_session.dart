import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../device_model.dart' hide ValueFormat;
import '../protocol/client.dart';
import '../protocol/protocol.dart';
import 'json_value.dart';

/// 属性上报值及其校验依据
class ModelPropertyState {
  const ModelPropertyState(
    this.value, {
    required this.receivedAt,
    required this.epoch,
    required this.verified,
    this.sampledAt,
    this.bootId,
    this.sequence,
  });

  final Object? value;

  /// 本机会话收到该值的时间
  final DateTime receivedAt;

  /// 连接纪元，重连或网关重启后旧值不再新鲜
  final int epoch;

  /// 是否通过设备顺序校验
  final bool verified;

  /// 设备采样时间，缺失时只能按接收时间判断
  final DateTime? sampledAt;
  final String? bootId;
  final int? sequence;
}

/// 一次属性写入：属性标识与按声明类型校验过的值
class ModelPropertyWrite {
  const ModelPropertyWrite(this.property, this.value);

  final String property;
  final Object? value;
}

/// 一次下发/读取的记录
///
/// [ModelCommandState.written] 只表示网关完成 BLE 写入，不代表设备已执行。
class ModelCommandRecord {
  const ModelCommandRecord({
    required this.operation,
    required this.state,
    required this.at,
    this.requestId,
    this.message,
  });

  final String operation;
  final String? requestId;
  final ModelCommandState state;
  final DateTime at;
  final String? message;
}

enum ModelCommandState implements WireEnum {
  /// 网关完成 GATT 写入
  written('written'),

  /// 收到设备按模型匹配的响应帧
  deviceAck('device_ack'),

  /// 设备主动回报了属性状态
  deviceState('device_state'),

  /// 读取成功
  read('read'),

  /// 执行失败
  failed('failed'),

  /// 结果未确认
  unknown('unknown');

  const ModelCommandState(this.wire);

  @override
  final String wire;
}

/// 等待设备确认的一次写入
class _AckWaiter {
  _AckWaiter(this.properties);

  final Map<String, PacketDecodeSpec> properties;
  final Completer<String> completer = Completer<String>();
}

/// 由 [DeviceModel] 驱动的设备会话
///
/// 命令下发：写入按 [DeviceModelRuntime.encodeWrite] 编码，帧内 kind=property
/// 字段从设备已知状态补齐，多条属性写入合成一次批量请求。
/// 响应解析：通知与读取都按响应定义校验帧头、命令字节、校验和，再转换成属性状态。
/// 会话不包含任何具体设备的字节布局，换一份 [DeviceModel] 即可驱动另一台设备。
class DeviceModelSession extends ChangeNotifier {
  DeviceModelSession({
    required this.model,
    required this.client,
    this.role = Role.user,
    this.maxAge = const Duration(minutes: 2),
    this.ackWindow = const Duration(seconds: 1),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    _wasOnline = client.connected && client.gatewayOnline;
    _wasConnected = _deviceConnected;
    _events = client.events.listen(_onEvent);
    _connection = client.changes.listen(_onConnectionChanged);
  }

  final DeviceModel model;
  final GatewayClient client;

  /// 属性能力之外还要按角色判断读写通知权限
  final Role role;

  /// 没有设备采样时间时，上报值在本机的有效期
  final Duration maxAge;

  /// 写入后等待设备响应帧的窗口
  final Duration ackWindow;

  final DateTime Function() _now;
  late final DeviceModelRuntime _runtime = DeviceModelRuntime(model);
  final Map<String, ModelPropertyState> _reported = {};
  final Map<String, Object?> _desired = {};
  final List<ModelCommandRecord> _commands = [];
  final List<_AckWaiter> _ackWaiters = [];
  late final StreamSubscription<GatewayEvent> _events;
  late final StreamSubscription<GatewayClientSnapshot> _connection;
  GatewayReportCursor? _cursor;
  Timer? _expiryTimer;
  Future<void> _tail = Future.value();
  int _epoch = 0;
  int _queued = 0;
  int _sequence = 0;
  bool _disposed = false;
  bool _started = false;
  bool _wasOnline = false;
  bool _wasConnected = false;

  String? lastError;

  Map<String, ModelPropertyState> get reported => Map.unmodifiable(_reported);

  Map<String, Object?> get desired => Map.unmodifiable(_desired);

  List<ModelCommandRecord> get commands => List.unmodifiable(_commands);

  bool get ready => !_disposed && client.connected && client.gatewayOnline;

  bool get busy => _queued > 0;

  bool get stale =>
      _reported.isEmpty || _reported.values.any((value) => !isFresh(value));

  bool isFresh(ModelPropertyState state) =>
      !_disposed &&
      ready &&
      state.verified &&
      state.epoch == _epoch &&
      !_now().isBefore(state.receivedAt) &&
      _now().isBefore(_expiresAt(state));

  bool canRead(String property) {
    final definition = model.properties[property];
    return definition != null && definition.canRoleRead(role);
  }

  bool canWrite(String property) {
    final definition = model.properties[property];
    return definition != null && definition.canRoleWrite(role);
  }

  bool canNotify(String property) {
    final definition = model.properties[property];
    return definition != null && definition.canRoleNotify(role);
  }

  /// 连接设备并订阅模型声明了 notify 的服务与特征
  Future<void> start() => _enqueue(_start);

  Future<void> _start() async {
    if (_started) return;
    final epoch = _epoch;
    await _request(
      GatewayOption.connect,
      data: {GatewayField.policy.wire: GatewayConnectPolicy.queue.wire},
    );
    await client.refreshSnapshot();
    if (_disposed || !ready || epoch != _epoch) {
      throw StateError('连接已变化，不能建立设备会话');
    }
    _cursor = client.reportCursor(model.id);
    final steps = <Map<String, Object?>>[];
    for (final target in _notifyTargets()) {
      steps.add({
        GatewayField.id.wire: 'sub:${target.service}:${target.characteristic}',
        GatewayField.op.wire: GatewayOption.subscribe.wire,
        GatewayField.service.wire: target.service,
        GatewayField.char.wire: target.characteristic,
        GatewayField.data.wire: {
          GatewayField.enabled.wire: true,
          GatewayField.mode.wire: GatewayNotifyMode.auto.wire,
          GatewayField.delivery.wire: GatewayDelivery.stream.wire,
        },
      });
    }
    if (steps.isNotEmpty) await _batch(steps);
    _started = true;
  }

  /// 读取所有可读属性
  Future<void> refresh() => _enqueue(() async {
    await _start();
    for (final entry in model.properties.entries) {
      if (entry.value.read == null) continue;
      if (!canRead(entry.key)) continue;
      await _read(entry.key);
    }
  });

  Future<ModelCommandRecord> readProperty(String property) =>
      _enqueue(() async {
        await _start();
        await _read(property);
        return _record(
          ModelCommandRecord(
            operation: 'read:$property',
            state: ModelCommandState.read,
            at: _now(),
          ),
        );
      });

  Future<ModelCommandRecord> writeProperty(String property, Object? value) =>
      writeProperties([ModelPropertyWrite(property, value)]);

  /// 一次写入多条属性：同一服务与特征上的写入合成一次批量请求
  Future<ModelCommandRecord> writeProperties(
    Iterable<ModelPropertyWrite> values,
  ) {
    final writes = values.toList(growable: false);
    if (writes.isEmpty) {
      return Future.error(StateError('没有需要写入的属性'));
    }
    final captured = <ModelPropertyWrite>[];
    final seen = <String>{};
    final operations = <String, BlePropertyOperation>{};
    for (final write in writes) {
      final definition = model.properties[write.property];
      if (definition == null) {
        return Future.error(StateError('未定义属性 ${write.property}'));
      }
      if (!canWrite(write.property)) {
        return Future.error(StateError('属性 ${write.property} 不可写'));
      }
      if (!seen.add(write.property)) {
        return Future.error(StateError('属性 ${write.property} 重复写入'));
      }
      try {
        ValueValidator.validate(
          write.value,
          definition.value,
          path: 'properties.${write.property}',
        );
      } on ArgumentError catch (error) {
        return Future.error(StateError('${error.message}'));
      }
      operations[write.property] = definition.write!;
      captured.add(ModelPropertyWrite(write.property, freezeThingValue(write.value)));
    }

    return _enqueue(() async {
      await _start();
      final steps = <Map<String, Object?>>[];
      // 同一次业务操作里的属性互相可见，重复报文只保留一条
      final known = {
        ..._knownState(),
        for (final write in captured) write.property: write.value,
      };
      final sent = <String>{};
      final written = <ModelPropertyWrite>[];
      for (final write in captured) {
        final operation = operations[write.property]!;
        final bytes = _runtime.encodeWrite(
          write.property,
          write.value,
          propertyState: known,
          sequence: ++_sequence,
          timestamp: _now(),
        );
        if (!sent.add(HexCodec.encode(bytes))) continue;
        steps.add(_writeStep('write:${write.property}', bytes, operation));
        written.add(write);
      }
      final waiter = _AckWaiter({
        for (final write in written)
          if (model.properties[write.property]!.notify?.response != null)
            write.property: model.properties[write.property]!.notify!.response!,
      });
      if (waiter.properties.isNotEmpty) _ackWaiters.add(waiter);
      final response = await _batch(steps);
      var state = ModelCommandState.written;
      if (waiter.properties.isNotEmpty) {
        state = await waiter.completer.future
            .timeout(ackWindow, onTimeout: () => '')
            .then(
              (confirmed) => switch (confirmed) {
                '' => ModelCommandState.written,
                'state' => ModelCommandState.deviceState,
                _ => ModelCommandState.deviceAck,
              },
            );
        _ackWaiters.remove(waiter);
      }
      for (final write in written) {
        _desired[write.property] = write.value;
      }
      _resolveDesired();
      return _record(
        ModelCommandRecord(
          operation: 'write:${captured.map((write) => write.property).join(',')}',
          requestId: response.reqId,
          state: state,
          at: _now(),
        ),
      );
    });
  }

  /// 解析一帧设备报文，返回本次更新到的属性增量
  ///
  /// 会话自身已经订阅网关事件，这里同样对外暴露，便于调试页或测试直接投喂报文。
  List<DecodedNotification> handleFrame(
    Uint8List packet, {
    required String service,
    required String characteristic,
    DateTime? sampledAt,
    bool verified = false,
    String? bootId,
    int? sequence,
  }) {
    final notifications = <DecodedNotification>[];
    for (final entry in model.properties.entries) {
      final operation = entry.value.notify;
      final response = operation?.response;
      if (operation == null || response == null) continue;
      if (!_sameUuid(operation.service, service) ||
          !_sameUuid(operation.characteristic, characteristic)) {
        continue;
      }
      final Object? decoded;
      try {
        // 校验帧头、匹配条件与校验和
        decoded = PacketDecoder.decode(response, packet);
      } on FormatException catch (error) {
        lastError = '设备上报无效：$error';
        notifyListeners();
        continue;
      }
      _confirm(entry.key, packet, hasState: decoded != null);
      // 只声明了确认、没有声明上报属性的响应不产生状态增量
      if (decoded == null) continue;
      final patch = response.isMultiValue
          ? decoded as Map<String, Object?>
          : {entry.key: decoded};
      try {
        _apply(
          patch,
          verified: verified,
          sampledAt: sampledAt,
          bootId: bootId,
          sequence: sequence,
        );
      } on FormatException catch (error) {
        lastError = '设备上报无效：$error';
        notifyListeners();
        continue;
      } on ArgumentError catch (error) {
        lastError = '设备上报无效：$error';
        notifyListeners();
        continue;
      }
      notifications.add(
        DecodedNotification(sourceProperty: entry.key, values: patch),
      );
    }
    return notifications;
  }

  /// 命中响应定义的帧即视为设备已确认本次写入
  void _confirm(String property, Uint8List packet, {required bool hasState}) {
    for (final waiter in _ackWaiters.toList()) {
      final response = waiter.properties[property];
      if (response == null || !PacketDecoder.matches(response, packet)) continue;
      if (!waiter.completer.isCompleted) {
        waiter.completer.complete(hasState ? 'state' : 'ack');
      }
    }
  }

  Future<Map<String, Object?>> _read(String property) async {
    final definition = model.properties[property];
    if (definition == null) throw StateError('未定义属性 $property');
    final operation = definition.read;
    if (operation == null) throw StateError('属性 $property 不可读');
    if (!canRead(property)) throw StateError('属性 $property 没有读取权限');
    final response = operation.response!;

    final request = _runtime.encodeReadRequest(
      property,
      propertyState: _knownState(),
      sequence: ++_sequence,
      timestamp: _now(),
    );
    // 需要先写请求帧的协议把读请求和读取合成一次批量，否则直接读取特征
    final String? raw;
    final ValueFormat? format;
    final DateTime? sampledAt;
    if (request == null) {
      final result = await _request(
        GatewayOption.read,
        service: operation.service,
        characteristic: operation.characteristic,
      );
      raw = result.value;
      format = result.format;
      sampledAt = _sampledAt(result.ts);
    } else {
      final result = await _batch([
        _writeStep('read-request:$property', request, operation),
        {
          GatewayField.id.wire: 'read:$property',
          GatewayField.op.wire: GatewayOption.read.wire,
          GatewayField.service.wire: operation.service,
          GatewayField.char.wire: operation.characteristic,
        },
      ]);
      final step = result.steps
          .where((step) => step.id == 'read:$property')
          .firstOrNull;
      raw = step?.value;
      format = step?.format;
      sampledAt = _sampledAt(result.ts);
    }
    if (raw == null) throw FormatException('读取 $property 没有返回特征值');
    final packet = ValueFormat.decode(raw, format ?? ValueFormat.hex);
    final decoded = PacketDecoder.decode(response, packet);
    final patch = _patch(property, response, decoded);
    _apply(patch, verified: true, sampledAt: sampledAt);
    return patch;
  }

  /// 多值响应本身就是增量，单值响应包装成 {property: value}
  Map<String, Object?> _patch(
    String property,
    PacketDecodeSpec response,
    Object? decoded,
  ) {
    if (!response.isMultiValue) return {property: decoded};
    if (decoded is! Map<String, Object?>) {
      throw FormatException('属性 $property 的多值响应没有解析成对象');
    }
    return decoded;
  }

  void _apply(
    Map<String, Object?> patch, {
    required bool verified,
    DateTime? sampledAt,
    String? bootId,
    int? sequence,
  }) {
    if (_disposed || patch.isEmpty) return;
    final now = _now();
    final updates = <String, ModelPropertyState>{};
    for (final entry in patch.entries) {
      final definition = model.properties[entry.key];
      if (definition == null) {
        throw FormatException('上报里出现未声明的属性：${entry.key}');
      }
      ValueValidator.validate(
        entry.value,
        definition.value,
        path: 'properties.${entry.key}',
      );
      final previous = _reported[entry.key];
      if (!verified && previous != null && isFresh(previous)) continue;
      final value = freezeThingValue(entry.value);
      final state = ModelPropertyState(
        value,
        receivedAt: now,
        epoch: _epoch,
        verified: verified,
        sampledAt: sampledAt,
        bootId: bootId,
        sequence: sequence,
      );
      if (sampledAt != null && !_expiresAt(state).isAfter(now)) continue;
      updates[entry.key] = state;
    }
    if (updates.isEmpty) return;
    _reported.addAll(updates);
    _resolveDesired();
    _scheduleExpiry();
    lastError = null;
    notifyListeners();
  }

  /// 上报值与期望值一致时清除期望值
  void _resolveDesired() {
    for (final entry in _desired.entries.toList()) {
      final state = _reported[entry.key];
      if (state != null && isFresh(state) && sameThingValue(state.value, entry.value)) {
        _desired.remove(entry.key);
      }
    }
  }

  DateTime _expiresAt(ModelPropertyState state) =>
      (state.sampledAt ?? state.receivedAt).add(maxAge);

  /// 帧内 kind=property 字段的取值来源：新鲜上报优先，其次是刚写入的目标值
  Map<String, Object?> _knownState() {
    return {
      for (final entry in _desired.entries) entry.key: entry.value,
      for (final entry in _reported.entries)
        if (isFresh(entry.value)) entry.key: entry.value.value,
    };
  }

  Map<String, Object?> _writeStep(
    String id,
    Uint8List bytes,
    BlePropertyOperation operation,
  ) {
    return {
      GatewayField.id.wire: id,
      GatewayField.op.wire: GatewayOption.write.wire,
      GatewayField.service.wire: operation.service,
      GatewayField.char.wire: operation.characteristic,
      GatewayField.value.wire: HexCodec.encode(bytes),
      GatewayField.format.wire: ValueFormat.hex.wire,
      GatewayField.data.wire: {
        GatewayField.writeType.wire:
            (operation.writeMode ?? WriteMode.withResponse).wireName,
      },
    };
  }

  /// 模型里声明了 notify 的服务与特征
  List<_NotifyTarget> _notifyTargets() {
    final targets = <_NotifyTarget>[];
    for (final property in model.properties.values) {
      final operation = property.notify;
      if (operation == null) continue;
      final isNew = !targets.any(
        (target) =>
            _sameUuid(target.service, operation.service) &&
            _sameUuid(target.characteristic, operation.characteristic),
      );
      if (isNew) {
        targets.add(_NotifyTarget(operation.service, operation.characteristic));
      }
    }
    return targets;
  }

  Future<GatewayMessage> _batch(List<Map<String, Object?>> steps) async {
    final result = await _request(
      GatewayOption.batch,
      data: {
        GatewayField.stopOnError.wire: true,
        GatewayField.autoConnect.wire: false,
        GatewayField.steps.wire: steps,
      },
    );
    final results = {for (final step in result.steps) step.id: step};
    if (result.steps.length != steps.length || results.length != steps.length) {
      throw StateError('网关步骤结果数量或标识不一致，执行结果未确认');
    }
    for (final step in steps) {
      final actual = results[step[GatewayField.id.wire]];
      if (actual == null) {
        throw StateError('网关缺少步骤 ${step[GatewayField.id.wire]} 的结果，执行结果未确认');
      }
      if (!actual.ok) {
        throw GatewayError.fromCode(actual.code, actual.message ?? '执行失败');
      }
    }
    return result;
  }

  Future<GatewayMessage> _request(
    GatewayOption op, {
    String? service,
    String? characteristic,
    Map<String, Object?>? data,
  }) async {
    if (!ready) throw StateError('设备会话不可用');
    final epoch = _epoch;
    final result = await client.request(
      op,
      deviceId: model.id,
      service: service,
      characteristic: characteristic,
      data: data,
      timeout: const Duration(seconds: 15),
    );
    if (_disposed || epoch != _epoch) throw StateError('连接已变化，执行结果未确认');
    if (result.error != null) throw result.error!;
    return result;
  }

  Future<T> _enqueue<T>(Future<T> Function() work) {
    if (_disposed) return Future.error(StateError('设备会话已关闭'));
    if (_queued >= 32) return Future.error(StateError('设备命令队列已满'));
    final epoch = _epoch;
    _queued++;
    notifyListeners();
    final next = _tail.then((_) async {
      if (_disposed || epoch != _epoch) throw StateError('连接已变化，请重新确认后下发');
      if (!ready) throw StateError('网关离线');
      return work();
    });
    final result = next.whenComplete(() {
      _queued--;
      if (!_disposed) notifyListeners();
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  void _onConnectionChanged(GatewayClientSnapshot snapshot) {
    final online = client.connected && client.gatewayOnline;
    final connected = _deviceConnected;
    if ((_wasOnline && !online) || (_wasConnected && !connected)) {
      _epoch++;
      _started = false;
      _cursor = null;
      _desired.clear();
    }
    _wasOnline = online;
    _wasConnected = connected;
    if (!_disposed) notifyListeners();
  }

  void _onEvent(GatewayEvent event) {
    if (_disposed) return;
    if (event.op == GatewayOption.hello) {
      _epoch++;
      _started = false;
      _cursor = null;
      notifyListeners();
      return;
    }
    if (!ready ||
        event.retained ||
        event.deviceId != model.id ||
        event.op != GatewayOption.notify) {
      return;
    }
    final service = event.service;
    final characteristic = event.characteristic;
    final value = event.value;
    if (service == null || characteristic == null || value == null) return;
    final Uint8List packet;
    try {
      packet = ValueFormat.decode(
        value,
        event.message.format ?? ValueFormat.hex,
      );
    } on FormatException {
      return;
    }
    final bootId = event.data?['bootId'];
    final sequence = event.data?['seq'];
    final cursor = _cursor;
    final verified =
        cursor != null &&
        bootId == cursor.bootId &&
        sequence is int &&
        sequence > cursor.sequence;
    if (cursor != null && bootId != null && !verified) return;
    final sampledAt = _sampledAt(event.data?['sampledAt'] ?? event.message.ts);
    if (sampledAt != null &&
        sampledAt.isAfter(_now().add(const Duration(seconds: 5)))) {
      return;
    }
    final reportBootId = bootId is String ? bootId : null;
    final reportSequence = sequence is int ? sequence : null;

    final decoded = handleFrame(
      packet,
      service: service,
      characteristic: characteristic,
      sampledAt: sampledAt,
      verified: verified,
      bootId: reportBootId,
      sequence: reportSequence,
    );
    if (decoded.isEmpty) return;
    if (verified && reportBootId != null && reportSequence != null) {
      _cursor = GatewayReportCursor(reportBootId, reportSequence);
    }
  }

  void _scheduleExpiry() {
    _expiryTimer?.cancel();
    final deadlines =
        _reported.values
            .where((value) => isFresh(value))
            .map((value) => _expiresAt(value))
            .toList()
          ..sort();
    if (deadlines.isEmpty) return;
    final delay = deadlines.first.difference(_now());
    _expiryTimer = Timer(delay.isNegative ? Duration.zero : delay, () {
      if (_disposed) return;
      notifyListeners();
      _scheduleExpiry();
    });
  }

  ModelCommandRecord _record(ModelCommandRecord record) {
    _commands.insert(0, record);
    if (_commands.length > 50) _commands.removeLast();
    if (!_disposed) notifyListeners();
    return record;
  }

  bool get _deviceConnected => client.device(model.id)?.connected == true;

  static DateTime? _sampledAt(Object? value) => value is int && value > 0
      ? DateTime.fromMillisecondsSinceEpoch(value)
      : null;

  static bool _sameUuid(String left, String right) {
    try {
      return GatewayUuid.normalize(left) == GatewayUuid.normalize(right);
    } on FormatException {
      return left == right;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _expiryTimer?.cancel();
    _events.cancel();
    _connection.cancel();
    super.dispose();
  }
}

class _NotifyTarget {
  const _NotifyTarget(this.service, this.characteristic);

  final String service;
  final String characteristic;
}
