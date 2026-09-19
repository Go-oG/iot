import 'dart:async';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import '../../data/remote_settings.dart';

class MqttEnvelope {
  const MqttEnvelope(this.topic, this.payload, {this.retained = false});
  final String topic;
  final String payload;
  final bool retained;
}

class MqttService {
  final _messages = StreamController<MqttEnvelope>.broadcast();
  final _connections = StreamController<bool>.broadcast();
  MqttServerClient? _client;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? _updates;
  bool _ready = false;

  Stream<MqttEnvelope> get messages => _messages.stream;

  Stream<bool> get connections => _connections.stream;

  Future<void> connect(
    RemoteSettings settings,
    String clientId,
    List<String> topics,
  ) async {
    await disconnect();
    final client =
        MqttServerClient.withPort(settings.host, clientId, settings.port)
          ..secure = settings.tls
          ..keepAlivePeriod = 20
          ..connectTimeoutPeriod = 8000
          ..autoReconnect = false
          ..connectionMessage = MqttConnectMessage()
              .withClientIdentifier(clientId)
              .startClean();
    client.setProtocolV311();
    client.logging(on: false);
    _client = client;
    client.onDisconnected = () {
      if (_client != client) return;
      _ready = false;
      _connections.add(false);
    };
    try {
      await client.connect(
        settings.username.isEmpty ? null : settings.username,
        settings.password.isEmpty ? null : settings.password,
      );
      if (_client != client) throw StateError('连接已取消');
      if (client.connectionStatus?.state != MqttConnectionState.connected)
        throw StateError('服务器未接受连接');
      _updates = client.updates!.listen((updates) {
        if (_client != client) return;
        for (final update in updates) {
          final message = update.payload;
          if (message is MqttPublishMessage) {
            _messages.add(
              MqttEnvelope(
                update.topic,
                MqttPublishPayload.bytesToStringAsString(
                  message.payload.message,
                ),
                retained: message.header?.retain ?? false,
              ),
            );
          }
        }
      });
      // 上行与在线状态使用 QoS 1 订阅，保证断线重连后能补齐关键消息
      final pendingTopics = topics.toSet();
      final subscribed = Completer<void>();
      client.onSubscribed = (topic) {
        pendingTopics.remove(topic);
        if (pendingTopics.isEmpty && !subscribed.isCompleted)
          subscribed.complete();
      };
      client.onSubscribeFail = (_) {
        if (!subscribed.isCompleted)
          subscribed.completeError(StateError('无权订阅设备主题，请检查账号权限'));
      };
      for (final topic in pendingTopics.toList()) {
        client.subscribe(topic, MqttQos.atLeastOnce);
      }
      await subscribed.future.timeout(const Duration(seconds: 8));
      if (_client != client ||
          client.connectionStatus?.state != MqttConnectionState.connected) {
        throw StateError('连接已断开');
      }
      _ready = true;
      _connections.add(true);
    } catch (_) {
      if (_client == client) await disconnect();
      rethrow;
    }
  }

  void publish(
    String topic,
    String payload, {
    int qos = 1,
    bool retain = false,
  }) {
    if (!_ready ||
        _client?.connectionStatus?.state != MqttConnectionState.connected)
      throw StateError('MQTT 尚未连接');
    final builder = MqttClientPayloadBuilder()..addUTF8String(payload);
    _client!.publishMessage(
      topic,
      _qosOf(qos),
      builder.payload!,
      retain: retain,
    );
  }

  Future<void> disconnect() async {
    _ready = false;
    final client = _client;
    _client = null;
    client?.disconnect();
    await _updates?.cancel();
    _updates = null;
    if (client != null) _connections.add(false);
  }

  Future<void> dispose() async {
    await disconnect();
    await _messages.close();
    await _connections.close();
  }
}

MqttQos _qosOf(int qos) => switch (qos) {
  0 => MqttQos.atMostOnce,
  2 => MqttQos.exactlyOnce,
  _ => MqttQos.atLeastOnce,
};
