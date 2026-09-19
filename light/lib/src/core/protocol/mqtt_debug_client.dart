import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import '../../data/remote_settings.dart';

/// 消息方向，页面按方向决定气泡靠左还是靠右
enum MqttEntryKind {
  /// 订阅后由服务器推送的消息
  received,

  /// 本机发布的消息
  sent,

  /// 连接、订阅、断开等系统提示
  system,
}

class MqttDebugEntry {
  MqttDebugEntry({
    required this.kind,
    required this.label,
    required this.payload,
    this.topic = '',
    this.retained = false,
    this.qos,
  }) : timestamp = DateTime.now();

  final DateTime timestamp;
  final MqttEntryKind kind;
  final String label;
  final String topic;
  final String payload;
  final bool retained;
  final int? qos;
}

class MqttDebugClient extends ChangeNotifier {
  /// 消息记录上限
  static const int maxEntries = 100;

  /// 自动重连的最短与最长间隔
  static const Duration _retryMin = Duration(seconds: 3);
  static const Duration _retryMax = Duration(seconds: 30);

  /// 心跳周期和心跳响应超时，超时未收到响应时主动断开并交由自动重连处理
  static const int _keepAliveSeconds = 30;
  static const int _keepAliveTimeoutSeconds = 30;

  final List<MqttDebugEntry> _entries = [];
  final Map<String, MqttQos> _desired = {};
  final Map<String, Completer<void>> _pending = {};
  MqttServerClient? _client;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? _updates;
  Timer? _retryTimer;
  RemoteSettings? _settings;
  Duration _retryDelay = _retryMin;
  bool _disposed = false;
  bool _connecting = false;
  bool _connected = false;
  bool _reconnecting = false;
  bool _reconnectWanted = false;
  bool _everConnected = false;

  bool get connecting => _connecting;
  bool get reconnecting => _reconnecting;
  bool get connected => _connected;
  List<MqttDebugEntry> get entries => List.unmodifiable(_entries);

  /// 已订阅和重连后待恢复的主题
  Set<String> get topics => Set.unmodifiable(_desired.keys);

  /// 界面使用的 QoS 数值转换为协议枚举
  static MqttQos qosOf(int qos) => switch (qos) {
    0 => MqttQos.atMostOnce,
    2 => MqttQos.exactlyOnce,
    _ => MqttQos.atLeastOnce,
  };

  /// 协议枚举转换为界面使用的 QoS 数值
  static int qosValue(MqttQos qos) => switch (qos) {
    MqttQos.atMostOnce => 0,
    MqttQos.exactlyOnce => 2,
    _ => 1,
  };

  void _log(
    MqttEntryKind kind,
    String label,
    String payload, {
    String topic = '',
    bool retained = false,
    int? qos,
  }) {
    if (_disposed) return;
    _entries.insert(
      0,
      MqttDebugEntry(
        kind: kind,
        label: label,
        payload: payload,
        topic: topic,
        retained: retained,
        qos: qos,
      ),
    );
    if (_entries.length > maxEntries)
      _entries.removeRange(maxEntries, _entries.length);
    notifyListeners();
  }

  /// 建立调试连接，连接成功后意外断开会自动重连并恢复订阅
  Future<void> connect(RemoteSettings settings) async {
    if (_disposed) return;
    _settings = settings;
    _reconnectWanted = true;
    _retryDelay = _retryMin;
    await _open(settings, manual: true);
  }

  Future<void> _open(RemoteSettings settings, {required bool manual}) async {
    if (_disposed || _connecting || _connected) return;
    _retryTimer?.cancel();
    _retryTimer = null;
    settings.validate();
    final id =
        'debug_${DateTime.now().microsecondsSinceEpoch}_${Random.secure().nextInt(65536)}';
    final client =
        MqttServerClient.withPort(
            settings.host,
            id,
            settings.port,
            maxConnectionAttempts: 1,
          )
          ..secure = settings.tls
          ..keepAlivePeriod = _keepAliveSeconds
          ..disconnectOnNoResponsePeriod = _keepAliveTimeoutSeconds
          ..connectTimeoutPeriod = 8000
          ..autoReconnect = false
          ..connectionMessage = MqttConnectMessage()
              .withClientIdentifier(id)
              .startClean();
    client.setProtocolV311();
    client.logging(on: false);
    _client = client;
    _connecting = true;
    _log(
      MqttEntryKind.system,
      manual ? '连接' : '重连',
      '${manual ? '正在连接' : '正在重新连接'} ${settings.host}:${settings.port}',
    );
    client.onDisconnected = () {
      if (_client != client) return;
      final wasConnecting = _connecting;
      _resetConnection();
      if (_shouldRetry) {
        _scheduleRetry(settings);
      } else {
        _log(
          MqttEntryKind.system,
          '断开',
          wasConnecting ? '连接失败，请检查服务器、证书和账号' : '服务器连接已断开，请重新连接并订阅',
        );
      }
    };
    client.onSubscribed = (topic) {
      if (_client != client) return;
      final pending = _pending[topic];
      if (pending == null || pending.isCompleted) return;
      pending.complete();
    };
    client.onSubscribeFail = (topic) {
      final pending = _pending[topic];
      if (_client == client && pending != null && !pending.isCompleted) {
        pending.completeError(StateError('服务器拒绝订阅，请检查主题权限'));
      }
    };
    try {
      await client.connect(
        settings.username.isEmpty ? null : settings.username,
        settings.password.isEmpty ? null : settings.password,
      );
      if (_client != client || _disposed) {
        client.disconnect();
        return;
      }
      if (client.connectionStatus?.state != MqttConnectionState.connected) {
        throw StateError('服务器未接受连接');
      }
      _updates = client.updates!.listen((updates) {
        if (_client != client || _disposed) return;
        for (final update in updates) {
          final message = update.payload;
          if (message is MqttPublishMessage) {
            _log(
              MqttEntryKind.received,
              '接收',
              utf8.decode(message.payload.message, allowMalformed: true),
              topic: update.topic,
              retained: message.header?.retain ?? false,
            );
          }
        }
      });
      _connecting = false;
      _connected = true;
      _everConnected = true;
      _reconnecting = false;
      _retryDelay = _retryMin;
      _log(MqttEntryKind.system, '连接', '服务器已连接');
      await _restoreSubscriptions(client);
    } catch (_) {
      if (_client != client || _disposed) {
        client.disconnect();
        return;
      }
      _resetConnection();
      client.disconnect();
      if (manual) {
        _log(MqttEntryKind.system, '连接', '连接失败，请检查服务器、证书和账号');
      }
      rethrow;
    }
  }

  /// 重连后恢复断开前的订阅，单个主题失败不影响其他主题
  Future<void> _restoreSubscriptions(MqttServerClient client) async {
    for (final topic in Map.of(_desired).entries) {
      if (_client != client || !_connected) return;
      try {
        await _subscribeTopic(client, topic.key, topic.value);
      } catch (_) {
        if (_client != client) return;
        _log(MqttEntryKind.system, '订阅', '重新订阅失败，请手动重试', topic: topic.key);
      }
    }
  }

  bool get _shouldRetry =>
      _reconnectWanted && _everConnected && _settings != null && !_disposed;

  void _scheduleRetry(RemoteSettings settings) {
    if (!_shouldRetry) return;
    _retryTimer?.cancel();
    _reconnecting = true;
    _log(MqttEntryKind.system, '断开', '连接已中断，${_retryDelay.inSeconds} 秒后自动重连');
    _retryTimer = Timer(_retryDelay, () {
      _retryTimer = null;
      _retryDelay = _retryDelay * 2 > _retryMax ? _retryMax : _retryDelay * 2;
      unawaited(_retry(settings));
    });
  }

  Future<void> _retry(RemoteSettings settings) async {
    if (!_shouldRetry || _settings != settings) return;
    try {
      await _open(settings, manual: false);
    } catch (_) {
      if (_shouldRetry && _settings == settings) _scheduleRetry(settings);
    }
  }

  static void validateTopic(String topic, {required bool subscription}) {
    if (topic.isEmpty ||
        topic.contains('\u0000') ||
        utf8.encode(topic).length > 65535) {
      throw const FormatException('Topic 不能为空、包含空字符或超过 65535 字节');
    }
    try {
      if (subscription) {
        SubscriptionTopic(topic);
        final levels = topic.split('/');
        if (levels.take(levels.length - 1).contains('#')) {
          throw const FormatException();
        }
      } else {
        PublicationTopic(topic);
      }
    } catch (_) {
      throw FormatException(
        subscription
            ? '订阅 Topic 格式无效，+ 必须独占一层，# 只能位于最后一层'
            : '发送 Topic 不能包含 + 或 # 通配符',
      );
    }
  }

  MqttServerClient get _activeClient {
    final client = _client;
    if (!_connected ||
        client?.connectionStatus?.state != MqttConnectionState.connected) {
      throw StateError('请先连接 MQTT 服务器');
    }
    return client!;
  }

  Future<void> subscribe(String topic, {int qos = 1}) async {
    validateTopic(topic, subscription: true);
    final client = _activeClient;
    if (_desired.containsKey(topic)) return;
    if (_pending.containsKey(topic)) throw StateError('正在等待该主题的订阅确认');
    _desired[topic] = qosOf(qos);
    notifyListeners();
    await _subscribeTopic(client, topic, qosOf(qos));
  }

  Future<void> _subscribeTopic(
    MqttServerClient client,
    String topic,
    MqttQos qos,
  ) async {
    final pending = Completer<void>();
    _pending[topic] = pending;
    try {
      if (client.subscribe(topic, qos) == null) {
        throw StateError('无法订阅该主题');
      }
      await pending.future.timeout(const Duration(seconds: 8));
      _log(
        MqttEntryKind.system,
        '订阅',
        '订阅成功 · QoS ${qosValue(qos)}',
        topic: topic,
      );
    } catch (_) {
      _desired.remove(topic);
      if (_client == client && _connected) client.unsubscribe(topic);
      rethrow;
    } finally {
      if (_pending[topic] == pending) _pending.remove(topic);
      if (!_disposed) notifyListeners();
    }
  }

  void unsubscribe(String topic) {
    _activeClient.unsubscribe(topic);
    _desired.remove(topic);
    _log(MqttEntryKind.system, '取消订阅', '已取消订阅', topic: topic);
  }

  void publish(
    String topic,
    String payload, {
    int qos = 1,
    bool retain = false,
  }) {
    validateTopic(topic, subscription: false);
    final client = _activeClient;
    final builder = MqttClientPayloadBuilder()..addUTF8String(payload);
    client.publishMessage(topic, qosOf(qos), builder.payload!, retain: retain);
    _log(
      MqttEntryKind.sent,
      '发送',
      payload,
      topic: topic,
      retained: retain,
      qos: qos,
    );
  }

  void clearEntries() {
    _entries.clear();
    notifyListeners();
  }

  /// 断线时保留期望订阅，重连成功后自动恢复
  void _resetConnection() {
    _client = null;
    _connecting = false;
    _connected = false;
    unawaited(_updates?.cancel());
    _updates = null;
    for (final pending in _pending.values) {
      if (!pending.isCompleted) pending.completeError(StateError('连接已断开'));
    }
    _pending.clear();
  }

  void disconnect() {
    _reconnectWanted = false;
    _everConnected = false;
    _settings = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryDelay = _retryMin;
    _reconnecting = false;
    final client = _client;
    _resetConnection();
    _desired.clear();
    client?.disconnect();
    if (client != null) _log(MqttEntryKind.system, '断开', '调试连接已关闭');
  }

  @override
  void dispose() {
    _disposed = true;
    disconnect();
    super.dispose();
  }
}
