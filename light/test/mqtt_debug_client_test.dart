import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:light/src/core/mqtt/mqtt_debug_client.dart';
import 'package:light/src/core/mqtt/mqtt_config.dart';

void main() {
  test('校验订阅通配符、发布主题和 UTF-8 长度', () {
    for (final topic in ['light/+/state', 'light/#', '#', '/']) {
      MqttDebugClient.validateTopic(topic, subscription: true);
    }
    for (final topic in [
      '',
      'light/#/state',
      '#/#',
      'light/a+',
      'bad\u0000topic',
      '灯' * 22000,
    ]) {
      expect(
        () => MqttDebugClient.validateTopic(topic, subscription: true),
        throwsFormatException,
      );
    }
    for (final topic in ['light/+', 'light/#']) {
      expect(
        () => MqttDebugClient.validateTopic(topic, subscription: false),
        throwsFormatException,
      );
    }
    MqttDebugClient.validateTopic('自定义/主题', subscription: false);
  });

  test('未连接时禁止订阅和发布', () async {
    final client = MqttDebugClient();
    addTearDown(client.dispose);
    await expectLater(client.subscribe('debug/#'), throwsStateError);
    expect(() => client.publish('debug/test', 'hello'), throwsStateError);
  });

  test('真实 Broker 支持自定义主题、中文消息、空消息、取消订阅及重新连接', () async {
    const settings = MqttConfig(
      host: '127.0.0.1',
      port: 18883,
      tls: false,
      gatewayId: 'tank_01',
    );
    final client = MqttDebugClient();
    addTearDown(client.dispose);
    await client.connect(settings);
    expect(client.connected, isTrue);
    final prefix = 'debug/${DateTime.now().microsecondsSinceEpoch}';
    await client.subscribe('$prefix/+');
    expect(client.topics, contains('$prefix/+'));
    final received = Completer<void>();
    client.addListener(() {
      final topics = client.entries
          .where((e) => e.label == '接收')
          .map((e) => e.topic)
          .toSet();
      if (!received.isCompleted &&
          topics.contains('$prefix/中文') &&
          topics.contains('$prefix/empty')) {
        received.complete();
      }
    });
    client.publish('$prefix/中文', '原样发送 {"灯":true}');
    client.publish('$prefix/empty', '');
    await received.future.timeout(const Duration(seconds: 5));
    // 本机测试 Broker 可能在连接时投递其他会话的保留消息，仅校验本测试主题
    final messages = client.entries
        .where((e) => e.label == '接收' && e.topic.startsWith('$prefix/'))
        .toList();
    expect(
      messages.any(
        (e) => e.topic == '$prefix/中文' && e.payload == '原样发送 {"灯":true}',
      ),
      isTrue,
    );
    expect(
      messages.any((e) => e.topic == '$prefix/empty' && e.payload.isEmpty),
      isTrue,
    );
    expect(messages.every((e) => !e.retained), isTrue);
    client.unsubscribe('$prefix/+');
    expect(client.topics, isEmpty);
    client.clearEntries();
    client.publish('$prefix/中文', '取消订阅后不应收到');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(
      client.entries.where(
        (e) => e.label == '接收' && e.topic.startsWith('$prefix/'),
      ),
      isEmpty,
    );
    client.disconnect();
    expect(client.connected, isFalse);
    await client.connect(settings);
    expect(client.connected, isTrue);
    expect(client.topics, isEmpty);
    client.clearEntries();
    expect(client.entries, isEmpty);
    final pendingSubscription = client.subscribe('$prefix/pending');
    final disconnected = expectLater(pendingSubscription, throwsStateError);
    client.disconnect();
    await disconnected;
    final cancelled = MqttDebugClient();
    final connecting = cancelled.connect(settings);
    cancelled.dispose();
    await connecting.timeout(const Duration(seconds: 10));
    expect(cancelled.connected, isFalse);
  }, skip: !const bool.fromEnvironment('MQTT_SMOKE'));
}
