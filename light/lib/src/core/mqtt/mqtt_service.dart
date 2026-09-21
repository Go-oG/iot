import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:light/src/core/op_result.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'model.dart';
import 'mqtt_config.dart';

class MqttService {
  final _messages = StreamController<MqttEnvelope>.broadcast();
  final _connections = StreamController<bool>.broadcast();

  MqttServerClient? _client;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? _updates;

  bool _ready = false;

  Stream<MqttEnvelope> get messages => _messages.stream;

  Stream<bool> get connections => _connections.stream;

  Future<OpResult> connect(MqttConfig config, String clientId, List<String> topics) async {
    await disconnect();
    final client =
    MqttServerClient.withPort(config.host, clientId, config.port)
      ..secure = config.tls
      ..keepAlivePeriod = config.keepAlivePeriod
      ..connectTimeoutPeriod = config.connectTimeoutPeriod
      ..autoReconnect = config.autoReconnect
      ..connectionMessage = MqttConnectMessage()
              .withClientIdentifier(clientId)
              .startClean();
    client.setProtocolV311();
    client.logging(on: config.log);

    _client = client;
    client.onDisconnected = () {
      if (_client != client) return;
      _ready = false;
      _connections.add(false);
    };

    try {
      await client.connect(
          config.username.isEmpty ? null : config.username, config.password.isEmpty ? null : config.password);
      if (_client != client) {
        return OpResult.fail("已取消连接");
      }
      if (client.connectionStatus?.state != MqttConnectionState.connected) {
        return OpResult.fail('服务器未接受连接');
      }
      _updates = client.updates!.listen((updates) {
        if (_client != client) return;
        for (final update in updates) {
          final message = update.payload;
          if (message is MqttPublishMessage) {
            _messages.add(MqttEnvelope(
                update.topic,
                MqttPublishPayload.bytesToStringAsString(message.payload.message),
                retained: message.header?.retain ?? false));
          }
        }
      });

      // 上行与在线状态使用 QoS 1 订阅，保证断线重连后能补齐关键消息
      final pendingTopics = topics.toSet();
      final subscribed = Completer<void>();
      client.onSubscribed = (topic) {
        pendingTopics.remove(topic);
        if (pendingTopics.isEmpty && !subscribed.isCompleted) {
          subscribed.complete();
        }
      };
      client.onSubscribeFail = (_) {
        if (!subscribed.isCompleted) {
          subscribed.completeError(StateError('无权订阅设备主题，请检查账号权限'));
        }
      };

      for (final topic in pendingTopics.toList()) {
        client.subscribe(topic, MqttQos.atLeastOnce);
      }
      await subscribed.future.timeout(const Duration(seconds: 8));

      if (_client != client || client.connectionStatus?.state != MqttConnectionState.connected) {
        return OpResult.fail('连接已断开');
      }
      _ready = true;
      _connections.add(true);
      return OpResult.success();
    } catch (e, s) {
      debugPrintStack(stackTrace: s);
      if (_client == client) await disconnect();
      return OpResult.fail('未知异常:$e');
    }
  }

  OpResult publish(String topic, String payload, {MqttQos qos = MqttQos.atLeastOnce, bool retain = false}) {
    if (!_ready || _client?.connectionStatus?.state != MqttConnectionState.connected) {
      return OpResult.fail('MQTT 尚未连接');
    }
    final builder = MqttClientPayloadBuilder()..addUTF8String(payload);
    _client!.publishMessage(topic, qos, builder.payload!, retain: retain);
    return OpResult.success();
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
