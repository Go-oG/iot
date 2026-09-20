import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:light/src/core/device/device_model_session.dart';
import 'helpers/at5_device.dart';
import 'package:light/src/core/device_model.dart';
import 'package:light/src/core/protocol/client.dart';
import 'package:light/src/core/protocol/mqtt_service.dart';
import 'package:light/src/data/remote_settings.dart';

/// 只认识网关协议的假 MQTT：报文内容由会话生成
class SessionMqtt extends MqttService {
  final incoming = StreamController<MqttEnvelope>.broadcast();
  final statuses = StreamController<bool>.broadcast();
  final sent = <Map<String, dynamic>>[];
  final Map<String, String> readValues = {};
  bool omitWrite = false;
  List<int>? notifyOnWrite;
  String notifyService = at5ServiceUuid;
  String notifyCharacteristic = at5CharacteristicUuid;

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
    statuses.add(true);
  }

  @override
  void publish(
    String topic,
    String payload, {
    int qos = 1,
    bool retain = false,
  }) {
    expect(retain, false);
    final frame = jsonDecode(payload) as Map<String, dynamic>;
    for (final raw in frame['messages'] as List) {
      final message = raw as Map<String, dynamic>;
      sent.add(message);
      final op = message['op'];
      incoming.add(
        MqttEnvelope(
          'iot/v1/gw/up',
          jsonEncode({
            'v': 1,
            'gatewayId': 'gw',
            'clientId': frame['clientId'],
            'messages': [
              {
                'type': 'res',
                'reqId': message['reqId'],
                'op': op,
                'deviceId': ?message['deviceId'],
                'service': ?message['service'],
                'char': ?message['char'],
                'code': 0,
                if (op == 'read')
                  'value': readValues[message['char'] as String?] ?? '00',
                if (op == 'read') 'format': 'hex',
                'data': op == 'snapshot'
                    ? {
                        'revision': 1,
                        'bootId': 'boot-1',
                        'devices': [
                          {
                            'deviceId': 'at5',
                            'connection': 'connected',
                            'reportSeq': 10,
                          },
                        ],
                      }
                    : op == 'batch'
                    ? {
                        'steps': [
                          for (final step
                              in (message['data']['steps'] as List).cast<Map>())
                            if (!(omitWrite &&
                                step['op'] == 'write'))
                              {
                                'id': step['id'],
                                'code': 0,
                                if (readValues.containsKey(step['char']))
                                  'value': readValues[step['char']],
                                if (readValues.containsKey(step['char']))
                                  'format': 'hex',
                              },
                        ],
                      }
                    : null,
              },
            ],
          }),
        ),
      );
    }
    final response = notifyOnWrite;
    if (response != null) {
      notify(
        service: notifyService,
        characteristic: notifyCharacteristic,
        value: response
            .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
            .join(),
      );
    }
  }

  void notify({
    required String service,
    required String characteristic,
    required String value,
    String id = 'at5',
    int? seq,
  }) {
    incoming.add(
      MqttEnvelope(
        'iot/v1/gw/up',
        jsonEncode({
          'v': 1,
          'gatewayId': 'gw',
          'messages': [
            {
              'type': 'event',
              'op': 'notify',
              'deviceId': id,
              'service': service,
              'char': characteristic,
              'value': value,
              'format': 'hex',
              if (seq != null) 'data': {'bootId': 'boot-1', 'seq': seq},
            },
          ],
        }),
      ),
    );
  }

  List<Map> get writes => [
    for (final message in sent.where((item) => item['op'] == 'batch'))
      for (final step in message['data']['steps'] as List)
        if (step['op'] == 'write') step as Map,
  ];

  List<Map> get reads => [
    for (final message in sent)
      if (message['op'] == 'read') message,
  ];

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> dispose() async {
    await incoming.close();
    await statuses.close();
  }
}

/// 带状态上报与读取的寄存器型模型，用于验证通用响应解析
Map<String, Object?> registerModel({List<String>? writeRoles}) => {
  'id': 'at5',
  'name': '寄存器设备',
  'properties': {
    'temperature': {
      'name': '温度',
      'type': 'double',
      'unit': '℃',
      'ui': {'renderer': 'slider'},
      'constraints': {'min': 0, 'max': 100},
      if (writeRoles != null)
        'permissions': {'write': writeRoles},
      'read': {
        'op': 'read',
        'service': 'fff0',
        'characteristic': 'fff1',
        'response': {
          'service': 'fff0',
          'characteristic': 'fff1',
          'template': r'${value:u16le,scale=0.1,at=0} ${checksum:sum8,at=2}',
        },
      },
      'write': {
        'op': 'write',
        'service': 'fff0',
        'characteristic': 'fff1',
        'writeMode': 'withoutResponse',
        'request': {
          'template': r'${value:u16le,scale=0.1}',
        },
      },
      'notify': {
        'op': 'subscribe',
        'service': 'fff0',
        'characteristic': 'fff1',
        'response': {
          'service': 'fff0',
          'characteristic': 'fff1',
          'template': r'${value:u16le,scale=0.1,at=0} ${checksum:sum8,at=2}',
        },
      },
    },
  },
};

void main() {
  late SessionMqtt mqtt;
  late GatewayClient client;

  Future<DeviceModelSession> sessionFor(DeviceModel model) async {
    final session = DeviceModelSession(model: model, client: client);
    await session.start();
    return session;
  }

  setUp(() async {
    mqtt = SessionMqtt();
    client = GatewayClient(transport: mqtt);
    await client.connect(
      const RemoteSettings(host: 'test', gatewayId: 'gw', enabled: true),
    );
    await client.refreshSnapshot();
  });

  tearDown(() async {
    await client.dispose();
  });

  test('写入按模型编码，逐字节来自设备定义', () async {
    final session = await sessionFor(at5DeviceModel);
    addTearDown(session.dispose);
    final record = await session.writeProperty('power', true);
    expect(mqtt.writes.single['value'], '3443888805000101230E');
    expect(mqtt.writes.single['data']['writeType'], 'withResponse');
    expect(record.state, ModelCommandState.written);
    expect(record.requestId, isNotEmpty);
    // 写入只记录期望值，不伪造设备上报
    expect(session.reported, isEmpty);
    expect(session.desired['power'], true);
  });

  test('同一批次的属性互相可见，重复报文只写一条', () async {
    final session = await sessionFor(at5DeviceModel);
    addTearDown(session.dispose);
    await session.writeProperties(const [
      ModelPropertyWrite('temperature', 40),
      ModelPropertyWrite('fanSpeed', 2),
    ]);
    // 温度与档位共用 0x06：先写入的帧已经带上本批次的档位值
    expect(mqtt.writes, hasLength(1));
    expect(mqtt.writes.single['value'], '3443888806000228029588');
  });

  test('收到按响应定义匹配的帧后提升为设备确认', () async {
    final session = await sessionFor(at5DeviceModel);
    addTearDown(session.dispose);
    final ack = [
      ...at5ResponseHeader,
      at5CommandBytes['power']!,
      0x00,
      0x01,
      0x00,
    ];
    mqtt.notifyOnWrite = [
      ...ack,
      ...ChecksumCodec.calculate(
        CheckSumAlg.crc16Modbus,
        Uint8List.fromList(ack),
        endian: DataEndian.big,
      ),
    ];
    final record = await session.writeProperty('power', true);
    expect(record.state, ModelCommandState.deviceAck);
  });

  test('设备回报状态的响应同时更新属性并把结果升级为 device_state', () async {
    final session = await sessionFor(DeviceModel.fromJson(registerModel()));
    addTearDown(session.dispose);
    mqtt.notifyService = 'fff0';
    mqtt.notifyCharacteristic = 'fff1';
    // 写入后设备回一帧状态：温度 64.5℃
    mqtt.notifyOnWrite = [0x85, 0x02, 0x87];
    final record = await session.writeProperty('temperature', 30);
    expect(record.state, ModelCommandState.deviceState);
    expect(session.reported['temperature']!.value, closeTo(64.5, .001));
    // 上报值与期望值不一致时保留期望值
    expect(session.desired['temperature'], 30);
  });

  test('通知按响应定义解析成属性状态，无关与过期报文被忽略', () async {
    final session = await sessionFor(DeviceModel.fromJson(registerModel()));
    addTearDown(session.dispose);
    // 8502 + sum8(0x87)，顺序号大于快照里的 10，可以通过设备顺序校验
    mqtt.notify(
      service: 'fff0',
      characteristic: 'fff1',
      value: '850287',
      seq: 11,
    );
    await Future<void>.delayed(Duration.zero);
    expect(session.reported['temperature']!.value, closeTo(64.5, .001));
    expect(session.reported['temperature']!.verified, true);
    expect(session.isFresh(session.reported['temperature']!), true);

    // 特征不匹配的设备报文不参与解析
    mqtt.notify(
      service: 'fff0',
      characteristic: 'fff9',
      value: '850287',
      seq: 12,
    );
    await Future<void>.delayed(Duration.zero);
    expect(session.lastError, isNull);

    // 顺序号没有前进的迟到报文不覆盖已收到的状态
    mqtt.notify(
      service: 'fff0',
      characteristic: 'fff1',
      value: '000000',
      seq: 11,
    );
    await Future<void>.delayed(Duration.zero);
    expect(session.reported['temperature']!.value, closeTo(64.5, .001));

    // 校验和与方法声明不符的报文不会被写坏状态
    mqtt.notify(
      service: 'fff0',
      characteristic: 'fff1',
      value: '850200',
      seq: 13,
    );
    await Future<void>.delayed(Duration.zero);
    expect(session.lastError, isNotNull);
    expect(session.reported['temperature']!.value, closeTo(64.5, .001));
  });

  test('读取按响应定义解码并写回状态', () async {
    final session = await sessionFor(DeviceModel.fromJson(registerModel()));
    addTearDown(session.dispose);
    mqtt.readValues['fff1'] = '850287';
    final record = await session.readProperty('temperature');
    expect(record.state, ModelCommandState.read);
    expect(mqtt.reads.single['service'], 'fff0');
    expect(session.reported['temperature']!.value, closeTo(64.5, .001));
  });

  test('角色权限与属性能力限制下发', () async {
    final session = await sessionFor(
      DeviceModel.fromJson(registerModel(writeRoles: ['admin'])),
    );
    addTearDown(session.dispose);
    expect(session.canWrite('temperature'), false);
    await expectLater(
      session.writeProperty('temperature', 30),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      session.writeProperty('unknown', 30),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      session.writeProperty('temperature', 'warm'),
      throwsA(isA<StateError>()),
    );

    final admin = DeviceModelSession(
      model: DeviceModel.fromJson(registerModel(writeRoles: ['admin'])),
      client: client,
      role: Role.admin,
    );
    addTearDown(admin.dispose);
    expect(admin.canWrite('temperature'), true);
    final record = await admin.writeProperty('temperature', 30);
    expect(record.state, ModelCommandState.written);
    expect(mqtt.writes.last['value'], '2C01');
  });

  test('批量步骤结果缺失时不冒充成功', () async {
    final session = await sessionFor(at5DeviceModel);
    addTearDown(session.dispose);
    mqtt.omitWrite = true;
    await expectLater(
      session.writeProperty('power', true),
      throwsA(isA<StateError>()),
    );
  });
}
