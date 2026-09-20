import 'package:flutter_test/flutter_test.dart';
import 'package:light/src/core/device_registry.dart';
import 'package:light/src/core/protocol/client.dart';
import 'package:light/src/core/protocol/mqtt_service.dart';
import 'package:light/src/core/protocol/protocol.dart';
import 'package:light/src/core/remote_gateway.dart';
import 'package:light/src/data/remote_settings.dart';

import 'helpers/fake_mqtt.dart';

Future<void> flush() => Future<void>.delayed(const Duration(milliseconds: 10));
const settings = RemoteSettings(
  host: 'localhost',
  gatewayId: 'gw',
  bluetoothDeviceId: 'lamp',
);

void main() {
  test('MQTT 建链同步快照，关闭 App 不断开网关设备', () async {
    final mqtt = FakeMqtt()
      ..state = {
        'revision': 1,
        'devices': [
          {'deviceId': 'lamp', 'connection': 'connected'},
        ],
      };
    final client = GatewayClient(transport: mqtt);
    await client.connect(settings);
    await flush();
    expect(client.device('lamp')!.connected, true);
    expect(client.gatewayOnline, true);
    await client.disconnect();
    expect(
      mqtt.sent
          .expand((f) => f['messages'] as List)
          .any((m) => m['op'] == 'disconnect'),
      false,
    );
    await client.dispose();
  });

  test('状态增量忽略重复，断档重同步，完整快照清除旧特征', () async {
    final mqtt = FakeMqtt()
      ..state = {
        'revision': 1,
        'devices': [
          {
            'deviceId': 'lamp',
            'connection': 'connected',
            'services': [
              {
                'uuid': 'fff0',
                'chars': [
                  {'uuid': 'fff1', 'value': '01', 'ts': 1},
                ],
              },
            ],
          },
        ],
      };
    final client = GatewayClient(transport: mqtt);
    await client.connect(settings);
    await flush();
    mqtt.send([
      {
        'type': 'event',
        'op': 'state',
        'data': {
          'revision': 1,
          'devices': [
            {'deviceId': 'lamp', 'connection': 'disconnected'},
          ],
        },
      },
    ]);
    await flush();
    expect(client.device('lamp')!.connected, true);
    mqtt.state = {
      'revision': 5,
      'devices': [
        {'deviceId': 'lamp', 'connection': 'disconnected'},
      ],
    };
    mqtt.send([
      {
        'type': 'event',
        'op': 'state',
        'data': {'revision': 5, 'devices': []},
      },
    ]);
    await flush();
    expect(client.snapshot.revision, 5);
    expect(client.device('lamp')!.characteristics, isEmpty);
    expect(client.device('lamp')!.connected, false);
    await client.dispose();
  });

  test('拒绝保留上行和其他客户端响应，连接事件正确更新状态', () async {
    final mqtt = FakeMqtt();
    final client = GatewayClient(transport: mqtt);
    await client.connect(settings);
    await flush();
    final event = <String, Object?>{
      'type': 'event',
      'op': 'connection',
      'deviceId': 'lamp',
      'data': {'state': 'connected'},
    };
    mqtt.send([event], retained: true);
    await flush();
    expect(client.device('lamp'), null);
    mqtt.send([event]);
    await flush();
    expect(client.device('lamp')!.connected, true);
    mqtt.reply = false;
    final future = client.request(GatewayOption.read, deviceId: 'lamp');
    await flush();
    final req = (mqtt.sent.last['messages'] as List).first;
    final response = <String, Object?>{
      'type': 'res',
      'op': 'read',
      'deviceId': 'lamp',
      'reqId': req['reqId'],
      'code': 0,
    };
    var completed = false;
    future.then((_) => completed = true);
    mqtt.send([response], clientId: 'someone-else');
    await flush();
    expect(completed, false);
    mqtt.send([response], clientId: client.clientId);
    await future;
    await client.dispose();
  });

  test('网关离线立即终止等待，重复请求标识不会覆盖待处理请求', () async {
    final mqtt = FakeMqtt();
    final client = GatewayClient(transport: mqtt);
    await client.connect(settings);
    await flush();
    mqtt.reply = false;
    final future = client.request(GatewayOption.write, deviceId: 'lamp');
    final failed = expectLater(future, throwsStateError);
    mqtt.incoming.add(
      const MqttEnvelope(
        'iot/v1/gw/presence',
        '{"online":false}',
        retained: true,
      ),
    );
    await failed;
    expect(client.gatewayOnline, false);
    await expectLater(
      client.exchange([
        GatewayMessage.request(op: GatewayOption.read, reqId: 'same'),
        GatewayMessage.request(op: GatewayOption.write, reqId: 'same'),
      ]),
      throwsA(isA<GatewayError>()),
    );
    await client.dispose();
  });

  test('响应必须匹配操作设备和特征，UUID 等价格式可以关联', () async {
    final mqtt = FakeMqtt();
    final client = GatewayClient(transport: mqtt);
    addTearDown(client.dispose);
    await client.connect(settings);
    await flush();
    mqtt.reply = false;
    final future = client.request(
      GatewayOption.read,
      deviceId: 'lamp',
      service: 'fff0',
      characteristic: 'fff1',
    );
    final request = (mqtt.sent.last['messages'] as List).single as Map;
    final response = <String, Object?>{
      'type': 'res',
      'reqId': request['reqId'],
      'op': 'read',
      'code': 0,
      'deviceId': 'lamp',
      'service': 'fff0',
      'char': 'fff1',
      'value': '01',
    };
    var completed = false;
    future.then((_) => completed = true);
    for (final override in [
      {'op': 'write'},
      {'deviceId': 'other'},
      {'deviceId': null},
      {'service': 'fff9'},
      {'char': 'fff9'},
      {'char': null},
    ]) {
      mqtt.send([
        {...response, ...override},
      ], clientId: client.clientId);
      await flush();
      expect(completed, isFalse);
      expect(client.device('lamp'), isNull);
    }
    mqtt.send([
      {...response, 'service': '0000FFF0-0000-1000-8000-00805F9B34FB'},
    ], clientId: client.clientId);
    expect((await future).value, '01');
    expect(client.device('lamp')!.value('fff0', 'fff1')!.value, '01');
  });

  test('重置扫描后迟到的启动响应不能覆盖新扫描', () async {
    final mqtt = FakeMqtt();
    final gateway = RemoteGateway(client: GatewayClient(transport: mqtt));
    final registry = DeviceRegistryService(gateway: gateway);
    addTearDown(() async {
      await registry.dispose();
      await gateway.dispose();
    });
    await gateway.connect(settings);
    await flush();
    mqtt.reply = false;
    final oldScan = registry.startScan();
    final oldRequest = (mqtt.sent.last['messages'] as List).single as Map;
    registry.reset();
    final newScan = registry.startScan();
    final newRequest = (mqtt.sent.last['messages'] as List).single as Map;
    void respond(Map request, String scanId) => mqtt.send([
      {
        'type': 'res',
        'op': 'scan',
        'reqId': request['reqId'],
        'code': 0,
        'data': {'scanId': scanId},
      },
    ], clientId: gateway.client.clientId);
    respond(newRequest, 'new');
    await newScan;
    respond(oldRequest, 'old');
    await oldScan;
    for (final id in ['old', 'new']) {
      mqtt.send([
        {
          'type': 'event',
          'op': 'scan',
          'data': {
            'scanId': id,
            'devices': [
              {'deviceId': id},
            ],
          },
        },
      ]);
    }
    await flush();
    expect(registry.scanning, isTrue);
    expect(registry.nearby.keys, ['new']);
  });

  test('网关离线结束扫描，恢复后不接收旧扫描结果', () async {
    final mqtt = FakeMqtt();
    final gateway = RemoteGateway(client: GatewayClient(transport: mqtt));
    final registry = DeviceRegistryService(gateway: gateway);
    addTearDown(() async {
      await registry.dispose();
      await gateway.dispose();
    });
    await gateway.connect(settings);
    await flush();
    await registry.startScan();
    mqtt.incoming.add(
      const MqttEnvelope('iot/v1/gw/presence', '{"online":false}'),
    );
    await flush();
    expect(registry.scanning, isFalse);
    mqtt.send([
      {
        'type': 'event',
        'op': 'scan',
        'data': {
          'scanId': 'scan-1',
          'devices': [
            {'deviceId': 'old'},
          ],
        },
      },
    ]);
    await flush();
    expect(registry.nearby, isEmpty);
  });

  test('设备管理服务负责登记、扫描与附近设备，通道路由它收发', () async {
    final mqtt = FakeMqtt();
    final gateway = RemoteGateway(client: GatewayClient(transport: mqtt));
    await gateway.connect(settings);
    await flush();
    final registry = DeviceRegistryService(gateway: gateway);

    await registry.execute(GatewayManageAction.upsert, {
      GatewayField.device: {'device': 'AA:BB:CC:DD:EE:01'},
    });
    expect(
      (mqtt.sent.last['messages'] as List).first['data']['action'],
      'upsert',
    );

    mqtt.state = {
      'revision': 1,
      'devices': [
        {'deviceId': 'AA:BB:CC:DD:EE:01', 'connection': 'connected'},
      ],
    };
    await registry.execute(GatewayManageAction.status);
    // 登记与运行时状态按设备标识缓存，供界面按 id 取用
    expect(registry.registered.keys, ['AA:BB:CC:DD:EE:01']);
    expect(registry.stateOf('AA:BB:CC:DD:EE:01')?['state'], 'connected');
    expect(registry.snapshot.lampConnected, false);

    registry.select('AA:BB:CC:DD:EE:01');
    mqtt.state = {
      'revision': 2,
      'devices': [
        {'deviceId': 'AA:BB:CC:DD:EE:01', 'connection': 'connected'},
      ],
    };
    await gateway.requestState();
    await flush();
    expect(registry.snapshot.lampConnected, true);

    await registry.startScan();
    expect(registry.scanning, true);
    mqtt.send([
      {
        'type': 'event',
        'op': 'scan',
        'data': {
          'scanId': 'scan-1',
          'devices': [
            {'deviceId': 'AA:BB:CC:DD:EE:02', 'mac': 'AA:BB:CC:DD:EE:02'},
          ],
        },
      },
    ]);
    await flush();
    expect(registry.nearby.keys, ['AA:BB:CC:DD:EE:02']);
    await registry.stopScan();
    expect(registry.scanning, false);

    await registry.dispose();
    await gateway.dispose();
  });

}
