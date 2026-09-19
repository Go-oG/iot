import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:light/src/core/device/checksum.dart';
import 'package:light/src/core/device/function_type.dart';
import 'package:light/src/core/functions/fan_speed.dart';
import 'package:light/src/core/device/generic_session.dart';
import 'package:light/src/core/protocol/client.dart';
import 'package:light/src/core/protocol/mqtt_service.dart';
import 'package:light/src/data/remote_settings.dart';

import 'helpers/device_examples.dart';

/// 记录下发帧并按请求逐条回复的假传输
class FakeMqtt extends MqttService {
  final incoming = StreamController<MqttEnvelope>.broadcast();
  final statuses = StreamController<bool>.broadcast();

  /// 收到的所有下行帧
  final List<Map<String, dynamic>> sent = [];

  /// 每次 publish 携带的下行消息
  List<Map<String, dynamic>> get downMessages => [
    for (final frame in sent)
      ...(frame['messages'] as List).cast<Map<String, dynamic>>(),
  ];

  /// 找到指定 op 的最后一条消息
  Map<String, dynamic>? lastOf(String op) =>
      downMessages.where((m) => m['op'] == op).lastOrNull;

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
    final frame = jsonDecode(payload) as Map<String, dynamic>;
    sent.add(frame);
    for (final message
        in (frame['messages'] as List).cast<Map<String, dynamic>>()) {
      final op = message['op'];
      final data = switch (op) {
        'batch' => {
          'steps': [
            for (final step in (message['data'] as Map)['steps'] as List)
              {'id': (step as Map)['id'], 'code': 0},
          ],
        },
        _ => null,
      };
      incoming.add(
        MqttEnvelope(
          'iot/v1/gw/up',
          jsonEncode({
            'v': 1,
            'gatewayId': 'gw',
            'clientId': clientIdOf(frame),
            'messages': [
              {
                'type': 'res',
                'reqId': message['reqId'],
                'op': op,
                'code': 0,
                'deviceId': ?message['deviceId'],
                'data': ?data,
              },
            ],
          }),
        ),
      );
    }
  }

  static String clientIdOf(Map<String, dynamic> frame) =>
      frame['clientId'] as String;

  /// 推一条 AT5 通知到上行主题
  void notify(String deviceId, int command, List<int> payload) {
    final body = [
      0x43,
      0x34,
      0x88,
      0x88,
      command,
      0x00,
      payload.length,
      ...payload,
    ];
    final crc = Checksums.crc16Modbus(body);
    final value = [
      ...body,
      (crc >> 8) & 0xFF,
      crc & 0xFF,
    ].map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    pushNotify(
      deviceId,
      '8332af20-6d0e-4eea-bb35-665544332211',
      '8332af20-6d0e-4eea-bb35-665544332211',
      value,
    );
  }

  /// 推一条任意特征的十六进制通知到上行主题
  void pushNotify(
    String deviceId,
    String service,
    String characteristic,
    String value,
  ) {
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
              'deviceId': deviceId,
              'service': service,
              'char': characteristic,
              'value': value,
              'format': 'hex',
            },
          ],
        }),
      ),
    );
  }

  Future<void> disposeAll() async {
    await incoming.close();
    await statuses.close();
  }
}

const settings = RemoteSettings(
  host: 'broker.test',
  port: 1883,
  gatewayId: 'gw',
  enabled: true,
);

void main() {
  late FakeMqtt transport;
  late GatewayClient client;
  late GenericDeviceSession session;

  setUp(() async {
    transport = FakeMqtt();
    client = GatewayClient(transport: transport);
    session = GenericDeviceSession(
      client: client,
      config: at5ExampleConfig,
      deviceId: 'dev-01',
      ackWindow: Duration.zero,
    );
    await client.connect(settings);
  });

  tearDown(() async {
    await session.dispose();
    await client.dispose();
    await transport.disposeAll();
  });

  test('建立会话时连接设备并订阅通知', () async {
    await session.start();

    final connect = transport.lastOf('connect');
    expect(connect, isNotNull);
    expect(connect!['deviceId'], 'dev-01');
    expect((connect['data'] as Map)['policy'], 'queue');

    final batch = transport.lastOf('batch');
    expect(batch, isNotNull);
    final steps = ((batch!['data'] as Map)['steps'] as List).cast<Map>();
    expect(steps.length, 1);
    expect(steps.first['op'], 'subscribe');
    expect(steps.first['char'], '8332af20-6d0e-4eea-bb35-665544332211');
    expect((steps.first['data'] as Map)['delivery'], 'stream');
  });

  test('电源命令按 AT5 规则编码后下发', () async {
    await session.start();
    await session.executeFunction(ConfigurableFunction.power, true);

    final batch = transport.lastOf('batch');
    final steps = ((batch!['data'] as Map)['steps'] as List).cast<Map>();
    expect(steps.length, 1);
    expect(steps.first['op'], 'write');
    expect(steps.first['value'], '3443888805000101230e');
    expect((steps.first['data'] as Map)['writeType'], 'withResponse');
  });

  test('温控与风扇共用一条命令，一次下发两个值', () async {
    await session.start();
    session.applyPreview(ConfigurableFunction.fanSpeed, FanSpeed.high.wire);
    await session.executeFunction(ConfigurableFunction.temperature, 31.0);

    final batch = transport.lastOf('batch');
    final steps = ((batch!['data'] as Map)['steps'] as List).cast<Map>();
    expect(steps.length, 1, reason: '两个功能指向同一条命令，不应重复下发');
    // 温度取本次新值 31，风速取设备最后已知的 high
    expect(steps.first['value'], '344388880600021f02a59e');
  });

  test('未改动的功能沿用设备当前状态', () async {
    await session.start();
    // 设备回报风速为高速，随后只改温度
    transport.notify('dev-01', 0x06, [31, 2]);
    await Future<void>.delayed(Duration.zero);
    await session.executeFunction(ConfigurableFunction.temperature, 55.0);

    final batch = transport.lastOf('batch');
    final steps = ((batch!['data'] as Map)['steps'] as List).cast<Map>();
    expect(steps.first['value'], startsWith('3443888806000237'));
  });

  test('未连接设备时拒绝下发', () async {
    expect(
      () => session.executeFunction(ConfigurableFunction.power, true),
      throwsA(isA<StateError>()),
    );
  });

  test('设备回报的状态写回功能并更新设备快照', () async {
    await session.start();
    transport.notify('dev-01', 0x06, [31, 2]);
    await Future<void>.delayed(Duration.zero);

    expect(session.device.status[ConfigurableFunction.temperature], 31);
    expect(session.device.status[ConfigurableFunction.fanSpeed], FanSpeed.high.wire);
  });

  test('无法解析的回报不会污染状态', () async {
    await session.start();
    final before = Map<ConfigurableFunction, Object>.of(session.device.status);

    // 校验和被破坏的报文
    transport.incoming.add(
      MqttEnvelope(
        'iot/v1/gw/up',
        jsonEncode({
          'v': 1,
          'gatewayId': 'gw',
          'messages': [
            {
              'type': 'event',
              'op': 'notify',
              'deviceId': 'dev-01',
              'service': '8332af20-6d0e-4eea-bb35-665544332211',
              'char': '8332af20-6d0e-4eea-bb35-665544332211',
              'value': '433488880600021f02ffff',
              'format': 'hex',
            },
          ],
        }),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(session.device.status, before);
  });

  test('其它设备的上报被忽略', () async {
    await session.start();
    transport.notify('dev-99', 0x06, [55, 2]);
    await Future<void>.delayed(Duration.zero);

    expect(session.device.status[ConfigurableFunction.temperature], isNot(55));
  });

  test('未声明的功能被拒绝', () async {
    expect(
      () => session.executeFunction(ConfigurableFunction.fanSpeedPercent, 1),
      throwsA(isA<UnsupportedError>()),
    );
  });

  test('没有绑定写命令的功能不可下发', () async {
    final preview = GenericDeviceSession(
      client: client,
      deviceId: 'dev-02',
      config: const {
        'id': 'preview-only',
        'name': '只读设备',
        'chars': {
          'a': {'service': 'fff0', 'char': 'fff1'},
        },
        'commands': {
          'readPower': {
            'char': 'a',
            'fields': [
              {'index': 0, 'as': 'int'},
            ],
          },
        },
        'functions': [
          {'type': 'power', 'status': false},
        ],
      },
    );
    // 没有 commands 时不会建立可下发的会话
    expect(preview.device.supportsRemoteControl, isFalse);
    await preview.dispose();
  });

  test('会话就绪状态跟随 MQTT 连接', () async {
    expect(session.ready, isFalse, reason: '尚未连接设备');
    await session.start();
    expect(session.ready, isTrue);
    await client.disconnect();
    expect(session.ready, isFalse);
  });

  // 换一种结构的设备走同一条链路：寻址方式、帧结构、校验、值编码全都不同
  group('寄存器型设备（温控器）', () {
    late GenericDeviceSession thermostat;

    setUp(() {
      thermostat = GenericDeviceSession(
        client: client,
        config: thermostatExampleConfig,
        deviceId: 'dev-T1',
        ackWindow: Duration.zero,
      );
    });

    tearDown(() => thermostat.dispose());

    test('订阅上报特征，写命令落在另一个特征上', () async {
      await thermostat.start();

      final subscribe =
          ((transport.lastOf('batch')!['data'] as Map)['steps'] as List)
              .cast<Map>()
              .single;
      expect(subscribe['op'], 'subscribe');
      expect(subscribe['char'], '0000fff2-0000-1000-8000-00805f9b34fb');

      await thermostat.executeFunction(ConfigurableFunction.temperature, 24.5);
      final write =
          ((transport.lastOf('batch')!['data'] as Map)['steps'] as List)
              .cast<Map>()
              .single;
      expect(write['char'], '0000fff1-0000-1000-8000-00805f9b34fb');
      expect(write['value'], 'f500f5');
      expect((write['data'] as Map)['writeType'], 'withoutResponse');
    });

    test('上报特征的通知写回温度', () async {
      await thermostat.start();
      transport.pushNotify('dev-T1', 'fff0', 'fff2', '110112');
      await Future<void>.delayed(Duration.zero);

      expect(thermostat.device.status[ConfigurableFunction.temperature], 27.3);
    });

    test('上报值越界时不写回', () async {
      await thermostat.start();
      transport.pushNotify('dev-T1', 'fff0', 'fff2', '320032');
      await Future<void>.delayed(Duration.zero);

      expect(thermostat.device.status[ConfigurableFunction.temperature], 24.5);
    });
  });
}
