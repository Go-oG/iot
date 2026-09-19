import 'package:flutter_test/flutter_test.dart';
import 'package:light/src/core/device/impl/at5_device.dart';
import 'package:light/src/core/device_registry.dart';
import 'package:light/src/core/protocol/client.dart';
import 'package:light/src/core/protocol/mqtt_service.dart';
import 'package:light/src/core/protocol/protocol.dart';
import 'package:light/src/core/protocol/remote_protocol.dart';
import 'package:light/src/core/remote/device_session.dart';
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

  test('AT5 控制不发送 waitNotify，写入成功不冒充设备回读', () async {
    final mqtt = FakeMqtt()
      ..state = {
        'revision': 1,
        'devices': [
          {'deviceId': 'lamp', 'connection': 'connected'},
        ],
      };
    final gateway = RemoteGateway(client: GatewayClient(transport: mqtt));
    await gateway.connect(settings);
    await flush();
    final codec = At5Client();
    addTearDown(codec.dispose);
    final session = DeviceRemoteSession(
      gateway: gateway,
      codec: codec,
      deviceId: 'lamp',
    );
    expect(session.ready, true);
    final result = await session.execute(DeviceCommand.setState, {
      'channels': {'red': 10, 'green': 20, 'blue': 30, 'white': 40, 'uv': 0},
      'temperature': 30,
      'fanSpeed': 1,
      'power': true,
    });
    final batch = (mqtt.sent.last['messages'] as List).first;
    expect((batch['data']['steps'] as List).map((s) => s['op']), [
      'subscribe',
      'write',
      'write',
      'write',
    ]);
    expect((batch['data']['steps'] as List).map((s) => s['id']), [
      'sub',
      'brightness',
      'temperatureFan',
      'power',
    ]);
    expect(result.confirmation, RemoteConfirmation.written);
    await session.dispose();
    await gateway.dispose();
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

  test('会话从转发的通知里解码设备确认，网关不参与解析', () async {
    final mqtt = FakeMqtt()
      ..state = {
        'revision': 1,
        'devices': [
          {'deviceId': 'lamp', 'connection': 'connected'},
        ],
      };
    final gateway = RemoteGateway(client: GatewayClient(transport: mqtt));
    await gateway.connect(settings);
    await flush();
    final codec = At5Client();
    addTearDown(codec.dispose);
    final session = DeviceRemoteSession(
      gateway: gateway,
      codec: codec,
      deviceId: 'lamp',
    );
    // 设备对 CMD 0x05 的成功确认：响应帧头 + 命令 + 00 + 长度 + ACK + CRC
    final ack = [
      ...At5Client.responseHeader,
      At5Client.commandPower,
      0x00,
      0x01,
      0x00,
    ];
    final crc = At5Client.crc16Modbus(ack);
    mqtt.notifyOnWrite = [...ack, (crc >> 8) & 0xFF, crc & 0xFF];

    final result = await session.execute(DeviceCommand.setState, {
      'channels': {'red': 1, 'green': 1, 'blue': 1, 'white': 1, 'uv': 0},
      'temperature': 30,
      'fanSpeed': 1,
      'power': true,
    });
    expect(result.confirmation, RemoteConfirmation.deviceAck);

    mqtt.notifyOnWrite = null;
    await session.dispose();
    await gateway.dispose();
  });

  test('设备回报失败确认时会话抛出拒绝', () async {
    final mqtt = FakeMqtt()
      ..state = {
        'revision': 1,
        'devices': [
          {'deviceId': 'lamp', 'connection': 'connected'},
        ],
      };
    final gateway = RemoteGateway(client: GatewayClient(transport: mqtt));
    await gateway.connect(settings);
    await flush();
    final codec = At5Client();
    addTearDown(codec.dispose);
    final session = DeviceRemoteSession(
      gateway: gateway,
      codec: codec,
      deviceId: 'lamp',
    );
    // CMD 0x05 返回非 0 状态码表示设备没有接受
    final reject = [
      ...At5Client.responseHeader,
      At5Client.commandPower,
      0x00,
      0x01,
      0x01,
    ];
    final crc = At5Client.crc16Modbus(reject);
    mqtt.notifyOnWrite = [...reject, (crc >> 8) & 0xFF, crc & 0xFF];

    await expectLater(
      session.execute(DeviceCommand.setState, {
        'channels': {'red': 1, 'green': 1, 'blue': 1, 'white': 1, 'uv': 0},
        'temperature': 30,
        'fanSpeed': 1,
        'power': true,
      }),
      throwsA(isA<RemoteCommandRejected>()),
    );
    mqtt.notifyOnWrite = null;
    await session.dispose();
    await gateway.dispose();
  });
}
