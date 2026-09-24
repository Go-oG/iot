import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:mqtt_client/mqtt_client.dart';

import '../mqtt/model.dart';
import '../mqtt/mqtt_config.dart';
import '../connection_status.dart';
import '../mqtt/mqtt_service.dart';
import 'model.dart';
import 'protocol.dart';

class _PendingRequest {
  _PendingRequest(this.request, this.completer);

  final GatewayMessage request;
  final Completer<GatewayMessage> completer;

  bool matches(GatewayMessage response) =>
      request.op == response.op &&
      request.deviceId == response.deviceId &&
      _sameUuid(request.service, response.service) &&
      _sameUuid(request.characteristic, response.characteristic);

  static bool _sameUuid(String? expected, String? actual) =>
      expected == null || actual == null
      ? expected == actual
      : GatewayUuid.normalize(expected) == GatewayUuid.normalize(actual);
}

/// App 侧的 MQTT 网关客户端，负责帧编解码、请求关联、去重、状态缓存与在线状态
/// 只处理协议层，不包含任何业务语义，业务由上层解析 notify 与特征值
class GatewayClient {

  GatewayClient({
    this.opTimeout = const Duration(seconds: 4),
    this.queueTimeout = const Duration(seconds: 8),
    this.freshness = const Duration(seconds: 90),
    this.reconnectBase = const Duration(seconds: 2),
    this.reconnectMax = const Duration(seconds: 60),
  }) : _mqttService = MqttService() {
    _msgSubs = _mqttService.messages.listen(_onEnvelope);
    _connectionSubs = _mqttService.connections.listen(_onConnection);
  }

  final MqttService _mqttService;

  /// BLE 操作执行超时
  final Duration opTimeout;

  /// 调度队列等待超时
  final Duration queueTimeout;

  /// 超过该时长没有新的状态或在线消息时判定网关离线
  final Duration freshness;

  /// 重连退避的起始间隔与上限
  final Duration reconnectBase;
  final Duration reconnectMax;

  final _changes = StreamController<GatewayClientSnapshot>.broadcast();
  final _events = StreamController<GatewayEvent>.broadcast();
  final _random = Random();
  final String clientId = 'app-${List
      .generate(8, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'))
      .join()}';

  ///存待处理响应的请求
  final Map<String, _PendingRequest> _pending = {};

  final Map<String, GatewayReportCursor> _reportCursors = {};

  GatewayReportCursor? reportCursor(String deviceId) => _reportCursors[deviceId];

  late final StreamSubscription<MqttEnvelope> _msgSubs;

  late final StreamSubscription<bool> _connectionSubs;

  GatewayClientSnapshot _snapshot = const GatewayClientSnapshot();
  Future<void>? _snapshotRequest;

  MqttConfig? _config;
  Timer? _reconnectTimer;
  Timer? _healthTimer;

  int _sequence = 0;
  int _generation = 0;
  int _reconnectAttempts = 0;
  bool _disposed = false;
  bool _connecting = false;

  GatewayClientSnapshot get snapshot => _snapshot;

  Stream<GatewayClientSnapshot> get changes => _changes.stream;

  Stream<GatewayEvent> get events => _events.stream;

  bool get connected => _snapshot.connected;

  bool get gatewayOnline => _snapshot.gatewayOnline;

  bool get isReady=>connected&&gatewayOnline;

  GatewayDeviceState? deviceOf(String deviceId) => _snapshot.devices[deviceId];

  /// 建立 MQTT 连接，订阅上行与在线状态主题后主动拉取一次快照
  Future<void> connect(MqttConfig config) async {
    config.validate();
    await disconnect();
    _config = config;
    // 用户主动连接从最短间隔重新开始退避
    _reconnectAttempts = 0;
    if (!config.enabled) return;
    await _connectOnce();
  }

  Future<void> _connectOnce() async {
    final config = _config;
    if (_disposed || _connecting || config == null || !config.enabled) {
      return;
    }
    final generation = _generation;
    _connecting = true;
    _emit(_snapshot, connection: ConnectionStatus.connecting);
    try {
      final topics = MqttTopics(config.gatewayId);
      final result = await _mqttService.connect(config, clientId, topics.subscriptions);

      if (!result.success) throw StateError(result.message);

    } catch (_) {
      if (!_disposed && generation == _generation) {
        _emit(const GatewayClientSnapshot(message: '远程连接失败，请检查网络、服务器、证书或账号权限'));
        _scheduleReconnect();
      }
    } finally {
      if (generation == _generation) _connecting = false;
    }
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    if (_disposed || _config?.enabled != true) return;
    // 连续失败时逐步拉长间隔，避免 Broker 或网络长时间不可用时持续空转
    final exponent = _reconnectAttempts > 5 ? 5 : _reconnectAttempts;
    _reconnectAttempts++;
    var delay = reconnectBase * (1 << exponent);
    if (delay > reconnectMax) delay = reconnectMax;
    // 加入抖动，避免多台设备在服务恢复瞬间同时重连
    delay += Duration(milliseconds: _random.nextInt(1000));
    _reconnectTimer = Timer(delay, _connectOnce);
  }

  void _onConnection(bool connected) {
    if (_disposed || _config?.enabled != true) return;
    if (connected) {
      _reconnectTimer?.cancel();
      _reconnectAttempts = 0;
      _emit(_snapshot, connection: ConnectionStatus.connected, message: null);
      _healthTimer?.cancel();
      _healthTimer = Timer.periodic(const Duration(seconds: 30), (_) => unawaited(_refreshQuietly()));
      unawaited(_refreshQuietly());
    } else {
      _reportCursors.clear();
      _failPending('连接中断，执行结果未确认');
      _emit(const GatewayClientSnapshot());
      _scheduleReconnect();
    }
  }

  Future<void> refreshSnapshot() => _snapshotRequest ??= _fetchSnapshot().whenComplete(() => _snapshotRequest = null);

  Future<void> _fetchSnapshot() async {
    final generation = _generation;
    final response = await request(GatewayOption.snapshot);

    if (generation != _generation || _disposed) return;

    if (response.error != null) throw response.error!;

    if (response.data?[GatewayField.revision.wire] is! int ||
        response.data?[GatewayField.devices.wire] is! List) {
      throw const FormatException('网关快照缺少 revision 或 devices');
    }

    _applySnapshot(response.data ?? const {});
  }

  Future<void> _refreshQuietly() async {
    try {
      await refreshSnapshot();
    } catch (error) {
      if (connected && !_fresh(_snapshot.lastSeen)) {
        _emit(_snapshot, gatewayOnline: false, message: '网关未响应：$error');
      }
    }
  }

  /// 发送单个请求并等待对应响应
  Future<GatewayMessage> request(
    GatewayOption op, {
    String? deviceId,
    String? service,
    String? characteristic,
    String? value,
    ValueFormat? format,
    Map<String, Object?>? data,
    Duration? timeout,
    Duration? queueWait,
  }) async {
    final message = GatewayMessage.request(
      op: op,
      reqId: _nextRequestId(),
      deviceId: deviceId,
      service: service,
      characteristic: characteristic,
      value: value,
      format: format,
      timeout: (timeout ?? opTimeout).inMilliseconds,
      queueTimeout: (queueWait ?? queueTimeout).inMilliseconds,
        data: data);
    final responses = await _exchange([message], wait: _waitFor(timeout, queueWait));
    return responses.first;
  }

  /// 在一个帧中携带多条独立请求
  Future<List<GatewayMessage>> exchange(
    List<GatewayMessage> messages, {
    Duration? wait,
  }) {
    return _exchange([
      for (final message in messages) _withRequestId(message),
    ], wait: wait ?? _waitFor(null, null));
  }

  GatewayMessage _withRequestId(GatewayMessage message) {
    if (message.reqId != null) return message;
    return message.copyWith(reqId: _nextRequestId());
  }

  Duration _waitFor(Duration? timeout, Duration? queueWait) {
    return (queueWait ?? queueTimeout) + (timeout ?? opTimeout) + const Duration(seconds: 2);
  }

  Future<List<GatewayMessage>> _exchange(
    List<GatewayMessage> messages, {
    required Duration wait,
  }) async {
    if (messages.isEmpty) return const [];
    if (messages.length > 64) {
      throw GatewayError(GatewayErrorCode.invalidRequest, '单帧请求不能超过 64 条');
    }
    final settings = _config;
    if (_disposed || settings == null) throw StateError('远程服务器未连接');
    if (!connected) throw StateError('远程服务器未连接');
    final ids = messages.map((m) => m.reqId).toList();
    if (messages.any((m) =>
    !m.isRequest || m.version != GatewayFrame.protocolVersion ||
        m.reqId == null || m.reqId!.isEmpty) ||
        ids.toSet().length != ids.length ||
        ids.any(_pending.containsKey) ||
        ids.any((id) => utf8.encode(id!).length > 64)) {
      throw GatewayError(GatewayErrorCode.invalidRequest, '请求标识为空或重复');
    }


    final requests = messages;
    final completers = <String, Completer<GatewayMessage>>{};
    for (final message in requests) {
      final reqId = message.reqId!;
      final completer = Completer<GatewayMessage>()
        ..future.ignore();
      _pending[reqId] = _PendingRequest(message, completer);
      completers[reqId] = completer;
    }
    final frame = GatewayFrame(
      gatewayId: settings.gatewayId,
        clientId: clientId, ts: _nowTimeMSSE, messages: requests);
    try {
      final payload = frame.encode();
      final limit = _snapshot.capabilities?[GatewayField.maxFrameBytes.wire];
      if (utf8.encode(payload).length > (limit is int ? limit : 65536)) {
        throw GatewayError(GatewayErrorCode.invalidArgument, '请求超过网关单帧容量，请减少设备或订阅数量');
      }
      // 命令不设置 retain，避免网关重连后重新执行历史请求
      final result = _mqttService.publish(
        MqttTopics(settings.gatewayId).down,
        payload,
        qos: MqttQos.atLeastOnce,
      );
      if (!result.success) throw StateError(result.message);
      return await Future.wait([
        for (final entry in completers.entries)
          entry.value.future.timeout(
            wait,
            onTimeout: () => throw TimeoutException('网关未在预期时间内响应 ${entry.key}'),
          ),
      ]);
    } finally {
      for (final entry in completers.entries) {
        if (identical(_pending[entry.key]?.completer, entry.value)) {
          _pending.remove(entry.key);
        }
      }
    }
  }

  String _nextRequestId() => '$clientId-${++_sequence}';

  void _onEnvelope(MqttEnvelope envelope) {
    final config = _config;
    if (_disposed || config == null) return;

    final topics = MqttTopics(config.gatewayId);
    if (envelope.topic == topics.presence) {
      _onPresence(envelope);
      return;
    }

    if (envelope.topic != topics.up || envelope.retained) return;

    try {
      final frame = GatewayFrame.decode(envelope.payload);
      if (frame.gatewayId != config.gatewayId) return;
      if (frame.clientId.isNotEmpty && frame.clientId != clientId) return;
      for (final message in frame.messages) {
        if (message.isResponse) {
          _onResponse(message);
        } else if (message.isEvent) {
          _onEvent(GatewayEvent(message, retained: envelope.retained));
        }
      }
    } on FormatException {
      return;
    } on TypeError {
      return;
    }
  }

  void _onPresence(MqttEnvelope envelope) {
    try {
      final json = jsonDecode(envelope.payload);
      if (json is! Map<String, dynamic>) return;

      final online = json[GatewayField.online.wire];
      if (online is! bool) return;

      final ts = json[GatewayField.ts.wire];
      final timestamp = ts is int ? DateTime.fromMillisecondsSinceEpoch(ts, isUtc: true) : null;

      if (!online) {
        _reportCursors.clear();
        // 遗嘱消息是保留消息，收到即表示网关已经掉线
        _failPending('网关离线，执行结果未确认');
        _emit(GatewayClientSnapshot(connection: _snapshot.connection));
        return;
      }
      if (!_snapshot.gatewayOnline && connected) unawaited(_refreshQuietly());
      _emit(
        _snapshot,
        gatewayOnline: true,
        lastSeen: timestamp != null && _fresh(timestamp) ? timestamp : _snapshot.lastSeen,
      );
    } on FormatException {
      return;
    }
  }

  void _onResponse(GatewayMessage message) {
    final reqId = message.reqId;
    if (reqId == null) return;
    final pendingReq = _pending[reqId];
    // 迟到的重复响应不再参与任何请求
    if (pendingReq == null || pendingReq.completer.isCompleted) {
      return;
    }

    // 响应必须回显原请求的操作与目标，避免错误报文污染状态或完成其它命令
    if (!pendingReq.matches(message)) {
      return;
    }

    final frameLimit = message.data?[GatewayField.maxFrameBytes.wire];
    _emit(_snapshot, gatewayOnline: true, lastSeen: nowTime, capabilities: frameLimit is int ? {
              ...?_snapshot.capabilities,
              GatewayField.maxFrameBytes.wire: frameLimit,
    } : null);

    if (message.op == GatewayOption.read && message.error == null) {
      _applyNotifyEvent(GatewayEvent(message));
    }

    pendingReq.completer.complete(message);
  }

  void _onEvent(GatewayEvent event) {
    if (event.op == GatewayOption.hello) {
      _reportCursors.clear();
    }

    if (event.op == GatewayOption.hello || event.op == GatewayOption.overflow) {
      _requestSnapshotIfIdle();
    }

    if (event.op == GatewayOption.hello) {
      _emit(_snapshot, capabilities: event.data, lastSeen: nowTime);
    } else if (event.op == GatewayOption.connection) {
      _applyConnectionEvent(event);
    } else if (event.op == GatewayOption.state) {
      _applyStateEvent(event);
    } else if (event.op == GatewayOption.notify) {
      _applyNotifyEvent(event);
    }

    if (!_events.isClosed) {
      _events.add(event);
    }
  }

  void _applyConnectionEvent(GatewayEvent event) {
    final deviceId = event.deviceId;
    final state = ConnectionStatus.valueOf(event.data?[GatewayField.state.wire]);
    if (deviceId == null || state == null) return;
    final devices = Map<String, GatewayDeviceState>.of(_snapshot.devices);
    final previous = devices[deviceId] ?? GatewayDeviceState(deviceId: deviceId);
    devices[deviceId] = previous.copyWith(
      connection: state,
        lastSeen: event.message.ts ?? _nowTimeMSSE);

    _emit(_snapshot, devices: devices, lastSeen: nowTime);
  }

  void _applyNotifyEvent(GatewayEvent event) {
    final deviceId = event.deviceId;
    final service = event.service;
    final characteristic = event.characteristic;
    final value = event.value;
    if (deviceId == null ||
        service == null ||
        characteristic == null ||
        value == null) {
      return;
    }
    final devices = Map<String, GatewayDeviceState>.of(_snapshot.devices);
    final previous =
        devices[deviceId] ?? GatewayDeviceState(deviceId: deviceId);
    final characteristics = Map<String, GatewayCharacteristicValue>.of(
      previous.characteristics,
    );
    characteristics['${GatewayUuid.normalize(service)}/${GatewayUuid.normalize(characteristic)}'] =
        GatewayCharacteristicValue(
          value: value,
          ts: event.message.ts ?? _nowTimeMSSE,
        );
    devices[deviceId] = previous.copyWith(
      characteristics: characteristics,
      lastSeen: event.message.ts ?? _nowTimeMSSE,
    );
    _emit(_snapshot, devices: devices, lastSeen: nowTime);
  }

  void _applyStateEvent(GatewayEvent event) {
    final data = event.data;
    if (data == null) return;
    final revision = data[GatewayField.revision.wire];
    final tracked = _snapshot.version;
    if (revision is! int || tracked == null) {
      _requestSnapshotIfIdle();
      return;
    }
    if (revision <= tracked) return;
    final devices = Map<String, GatewayDeviceState>.of(_snapshot.devices);
    _mergeDevices(devices, data[GatewayField.devices.wire]);
    if (revision > tracked + 1) {
      // 版本断档说明中间状态丢失，重新拉取快照，对应协议第 17 节
      _requestSnapshotIfIdle();
      return;
    }
    _emit(
      _snapshot,
      devices: devices,
      revision: revision,
      gatewayOnline: true,
      lastSeen: nowTime,
    );
  }

  void _applySnapshot(Map<String, Object?> data) {
    _reportCursors.clear();
    final bootId = data['bootId'];
    if (bootId is String && bootId.isNotEmpty) {
      for (final device in data[GatewayField.devices.wire] as List? ?? const []) {
        if (device is Map && device['deviceId'] is String && device['reportSeq'] is int && device['reportSeq'] >= 0) {
          _reportCursors[device['deviceId'] as String] = GatewayReportCursor(bootId, device['reportSeq'] as int);
        }
      }
    }
    final devices = <String, GatewayDeviceState>{};
    _mergeDevices(devices, data[GatewayField.devices.wire], full: true);
    final revision = data[GatewayField.revision.wire];
    _emit(
      _snapshot,
      devices: devices,
      revision: revision is int ? revision : _snapshot.version,
      gatewayOnline: true,
      lastSeen: nowTime,
      message: null,
    );
  }

  void _mergeDevices(
    Map<String, GatewayDeviceState> devices,
    Object? raw, {
    bool full = false,
  }) {
    if (raw is! List) return;


    for (final entry in raw) {
      if (entry is! Map<String, dynamic>) {
        continue;
      }
      final deviceId = entry[GatewayField.deviceId.wire];
      if (deviceId is! String || deviceId.isEmpty) {
        continue;
      }

      final previous =
          devices[deviceId] ?? (full ? null : _snapshot.devices[deviceId]) ?? GatewayDeviceState(deviceId: deviceId);

      final connection = ConnectionStatus.valueOf(
        entry[GatewayField.connection.wire],
      );
      final rssi = entry[GatewayField.rssi.wire];
      final lastSeen = entry[GatewayField.lastSeen.wire];
      final characteristics = Map<String, GatewayCharacteristicValue>.of(previous.characteristics);
      final services = entry[GatewayField.services.wire];


      if (services is List) {
        for (final service in services) {
          if (service is! Map<String, dynamic>) continue;

          final serviceUuid = service[GatewayField.uuid.wire];

          final chars = service[GatewayField.chars.wire];

          if (serviceUuid is! String || chars is! List) continue;

          for (final characteristic in chars) {
            if (characteristic is! Map<String, dynamic>) continue;

            final uuid = characteristic[GatewayField.uuid.wire];
            final value = characteristic[GatewayField.value.wire];

            if (uuid is! String || value is! String) continue;

            characteristics['${GatewayUuid.normalize(serviceUuid)}/${GatewayUuid.normalize(uuid)}'] =
                GatewayCharacteristicValue(
                  value: value,
                  ts: characteristic[GatewayField.ts.wire] is int
                      ? characteristic[GatewayField.ts.wire] as int : _nowTimeMSSE,
                );
          }
        }
      }

      devices[deviceId] = previous.copyWith(
        deviceId: deviceId,
        mac: entry[GatewayField.mac.wire] as String?,
        name: entry[GatewayField.name.wire] as String?,
        addrType:
        entry[GatewayField.addrType.wire] as String?,
        connection: connection,
        rssi: rssi as int?,
        lastSeen: lastSeen as int?,
        characteristics: characteristics,
      );
    }
  }

  void _requestSnapshotIfIdle() {
    if (connected) unawaited(_refreshQuietly());
  }

  bool _fresh(DateTime? timestamp) {
    if (timestamp == null) return false;
    final age = nowTime.difference(timestamp);
    return age >= const Duration(seconds: -5) && age <= freshness;
  }

  void _failPending(String message) {
    for (final pending in _pending.values) {
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(StateError(message));
      }
    }
    _pending.clear();
  }

  void _emit(
    GatewayClientSnapshot previous, {
        ConnectionStatus? connection,
    bool? gatewayOnline,
    int? revision,
    Map<String, GatewayDeviceState>? devices,
    Map<String, Object?>? capabilities,
    DateTime? lastSeen,
    String? message,
  }) {
    if (_disposed) return;
    _snapshot = previous.copyWith(
      connection: connection,
      gatewayOnline: gatewayOnline,
      version: revision,
      devices: devices,
      capabilities: capabilities,
      lastSeen: lastSeen,
      message: message,
    );
    if (!_changes.isClosed) {
      _changes.add(_snapshot);
    }
  }

  Future<void> disconnect() async {
    _reportCursors.clear();
    _generation++;
    _config = null;
    _connecting = false;
    _reconnectTimer?.cancel();
    _healthTimer?.cancel();
    _failPending('连接已关闭，执行结果未确认');
    await _mqttService.disconnect();
    // 释放阶段没有订阅方
    // 再发布一次会让监听者收到已失效的空快照
    if (!_disposed) {
      _emit(const GatewayClientSnapshot());
    }
  }

  Future<void> dispose() async {
    await disconnect();
    _disposed = true;
    await _msgSubs.cancel();
    await _connectionSubs.cancel();
    await _mqttService.dispose();
    await _events.close();
    await _changes.close();
  }

  int get _nowTimeMSSE {
    return DateTime
        .now()
        .millisecondsSinceEpoch;
  }

  DateTime get nowTime {
    return DateTime.now();
  }

}
