import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light/src/core/device/device_model_session.dart';
import 'helpers/at5_device.dart';
import 'package:light/src/core/device_model.dart';
import 'package:light/src/core/protocol/client.dart';
import 'package:light/src/data/remote_settings.dart';
import 'package:light/src/page/device_model_page.dart';

import 'helpers/fake_mqtt.dart';

const settings = RemoteSettings(
  host: 'localhost',
  gatewayId: 'gw',
  bluetoothDeviceId: 'at5',
);

/// 只读且会主动上报的传感器模型，用于验证只读属性的展示
final DeviceModel sensorModel = DeviceModel.fromJson({
  'id': 'at5',
  'name': '温度传感器',
  'properties': {
    'temperature': {
      'name': '温度',
      'type': 'double',
      'unit': '℃',
      'ui': {'renderer': 'input'},
      'read': {
        'op': 'read',
        'service': 'fff0',
        'characteristic': 'fff1',
        'response': {
          'service': 'fff0',
          'characteristic': 'fff1',
          'template': r'${value:u16le,scale=0.1,at=0}',
        },
      },
      'notify': {
        'op': 'subscribe',
        'service': 'fff0',
        'characteristic': 'fff1',
        'response': {
          'service': 'fff0',
          'characteristic': 'fff1',
          'template': r'${value:u16le,scale=0.1,at=0}',
        },
      },
    },
  },
});

void main() {
  late FakeMqtt mqtt;
  late GatewayClient client;
  late DeviceModelSession session;

  Future<void> prepare({DeviceModel? model}) async {
    mqtt = FakeMqtt()
      ..state = {
        'revision': 1,
        'devices': [
          {'deviceId': 'at5', 'connection': 'connected'},
        ],
      };
    client = GatewayClient(transport: mqtt);
    await client.connect(settings);
    await client.refreshSnapshot();
    session = DeviceModelSession(model: model ?? at5DeviceModel, client: client);
  }

  Future<void> pump(WidgetTester tester) async {
    // 页面较长，放大测试画布，避免控件因未进入视口而不被构建
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: DeviceModelPage(session: session)));
    await tester.pumpAndSettle();
  }

  /// 会话与网关客户端都持有定时器，测试结束前先卸载页面再释放
  Future<void> release(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      session.dispose();
      await client.dispose();
    });
  }

  testWidgets('控件按 ui.renderer 渲染，隐藏属性不出现', (tester) async {
    await prepare();
    await pump(tester);

    expect(find.text('AT5 智能灯'), findsOneWidget);
    // 电源用开关，温控用滑杆，风速用分段选择，五路灯光各一条通道滑杆
    expect(find.byType(Switch), findsOneWidget);
    expect(find.byType(Slider), findsNWidgets(6));
    expect(find.byType(SegmentedButton<Object?>), findsOneWidget);
    expect(find.text('五路灯光'), findsOneWidget);
    // 定时与对时没有独立控件：前者走编辑入口，后者是 hidden
    expect(find.text('编辑定时'), findsOneWidget);
    expect(find.text('时间同步'), findsNothing);
    // 没有上报时提示尚未收到数据
    expect(find.text('尚未收到设备上报'), findsWidgets);
    await release(tester);
  });

  testWidgets('操作控件按模型编码下发并记录结果', (tester) async {
    await prepare();
    await pump(tester);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    final batch = mqtt.sent
        .expand((frame) => (frame['messages'] as List))
        .whereType<Map>()
        .lastWhere((message) => message['op'] == 'batch');
    final writes = (batch['data']['steps'] as List)
        .whereType<Map>()
        .where((step) => step['op'] == 'write')
        .toList();
    expect(writes.single['value'], '3443888805000101230E');
    expect(find.textContaining('write:power · 已写入'), findsOneWidget);
    // 写入只记录期望值，不伪装成设备上报
    expect(find.textContaining('期望值'), findsOneWidget);
    await release(tester);
  });

  testWidgets('只读属性不生成写入控件，上报值带校验状态', (tester) async {
    await prepare(model: sensorModel);
    await pump(tester);

    expect(find.text('温度'), findsOneWidget);
    expect(find.textContaining('可读'), findsOneWidget);
    expect(find.text('尚未收到设备上报'), findsOneWidget);
    // 只读属性没有写入入口，但有读取按钮
    expect(find.text('输入值'), findsNothing);
    expect(find.text('读取'), findsOneWidget);

    mqtt.send([
      {
        'type': 'event',
        'op': 'notify',
        'deviceId': 'at5',
        'service': 'fff0',
        'char': 'fff1',
        'value': '8502',
        'format': 'hex',
      },
    ]);
    await tester.pumpAndSettle();
    final displayed = tester
        .widget<SelectableText>(find.byType(SelectableText))
        .data;
    expect(displayed, contains('64.5'));
    expect(find.textContaining('未校验'), findsOneWidget);
    await release(tester);
  });
}
