import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:light/src/core/protocol/mqtt_service.dart';
import 'package:light/src/data/remote_settings.dart';

class FakeMqtt extends MqttService {
  final incoming = StreamController<MqttEnvelope>.broadcast();
  final statuses = StreamController<bool>.broadcast();
  final List<Map<String, dynamic>> sent = [];
  Map<String, Object?> state = {'revision': 1, 'devices': <Object?>[]};
  bool reply = true;

  /// 每次写步骤后回一帧设备通知，用于验证会话的确认解码
  List<int>? notifyOnWrite;
  @override
  Stream<MqttEnvelope> get messages => incoming.stream;
  @override
  Stream<bool> get connections => statuses.stream;
  @override
  Future<void> connect(
    RemoteSettings settings,
    String clientId,
    List<String> topics,
  ) async {
    expectSync(topics, ['iot/v1/gw/up', 'iot/v1/gw/presence']);
    statuses.add(true);
  }

  @override
  void publish(
    String topic,
    String payload, {
    int qos = 1,
    bool retain = false,
  }) {
    expectSync(topic, 'iot/v1/gw/down');
    expectSync(qos, 1);
    expectSync(retain, false);
    final frame = jsonDecode(payload) as Map<String, dynamic>;
    sent.add(frame);
    for (final req
        in (frame['messages'] as List).cast<Map<String, dynamic>>()) {
      expectSync(req['type'], 'req');
      expectSync(req['reqId'], isNotEmpty);
      if (!reply) continue;
      send([
        {
          'type': 'res',
          'reqId': req['reqId'],
          'op': req['op'],
          'code': 0,
          if (req['deviceId'] != null) 'deviceId': req['deviceId'],
          'data': req['op'] == 'snapshot'
              ? state
              : req['op'] == 'manage' && req['data']['action'] == 'status'
              ? {
                  'devices': [
                    {
                      'device': 'AA:BB:CC:DD:EE:01',
                      'deviceId': 'AA:BB:CC:DD:EE:01',
                      'alias': '鱼缸灯',
                    },
                  ],
                  'states': [
                    {'device': 'AA:BB:CC:DD:EE:01', 'state': 'connected'},
                  ],
                }
              : req['op'] == 'batch'
              ? {
                  'steps': [
                    for (final step in req['data']['steps'])
                      {'id': step['id'], 'code': 0},
                  ],
                }
              : {'scanId': 'scan-1'},
        },
      ], clientId: frame['clientId'] as String);
      // 模拟设备在收到写入后回报，命令字节由调用方给出
      final response = notifyOnWrite;
      final deviceId = req['deviceId'];
      if (response != null && deviceId is String) {
        final hex = response
            .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
            .join();
        incoming.add(
          MqttEnvelope(
            'iot/v1/gw/up',
            jsonEncode({
              'v': 1,
              'gatewayId': 'gw',
              'clientId': frame['clientId'],
              'messages': [
                {
                  'type': 'event',
                  'op': 'notify',
                  'deviceId': deviceId,
                  'service': '8332af20-6d0e-4eea-bb35-665544332211',
                  'char': '8332af20-6d0e-4eea-bb35-665544332211',
                  'value': hex,
                  'format': 'hex',
                },
              ],
            }),
          ),
        );
      }
    }
  }

  void send(
    List<Map<String, Object?>> messages, {
    String clientId = '',
    bool retained = false,
  }) {
    incoming.add(
      MqttEnvelope(
        'iot/v1/gw/up',
        jsonEncode({
          'v': 1,
          'gatewayId': 'gw',
          'clientId': clientId,
          'messages': messages,
        }),
        retained: retained,
      ),
    );
  }

  @override
  Future<void> disconnect() async {}
  @override
  Future<void> dispose() async {
    await incoming.close();
    await statuses.close();
    await super.dispose();
  }
}
