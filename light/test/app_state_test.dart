import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light/main.dart';
import 'package:light/src/app/controller.dart';
import 'package:light/src/app/scope.dart';
import 'package:light/src/core/protocol/client.dart';
import 'package:light/src/core/remote_gateway.dart';
import 'package:light/src/data/database.dart';
import 'package:light/src/data/remote_settings.dart';
import 'package:light/src/widgets/app_widgets.dart';
import 'package:marquee/marquee.dart';

import 'helpers/fake_mqtt.dart';

void main() {
  testWidgets('启动使用传入的持久化依赖并显示已停用的配置', (tester) async {
    final store = MemoryRemoteSettingsStore();
    await store.write(
      const RemoteSettings(
        host: 'localhost',
        gatewayId: 'saved-gateway',
        enabled: false,
        bluetoothDeviceId: 'saved-lamp',
      ),
    );
    final database = AppDatabase.memory();
    final controller = AppController(database, remoteStore: store);
    await controller.setOutputLimit(65);

    await tester.pumpWidget(MyApp(controller: controller));
    await tester.pumpAndSettle();

    expect(AppScope.controller, same(controller));
    expect(controller.outputLimit, 65);
    expect(controller.selectedDeviceId, 'saved-lamp');
    expect(find.text('saved-gateway'), findsOneWidget);
    expect(controller.remoteSettings?.enabled, isFalse);
    expect(
      tester.widget<OnlineStatusView>(find.byType(OnlineStatusView)).online,
      isFalse,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('保存配置返回首页立即刷新，重建应用后仍能恢复配置', (tester) async {
    final store = MemoryRemoteSettingsStore();
    final controller = AppController(AppDatabase.memory(), remoteStore: store);
    await tester.pumpWidget(MyApp(controller: controller));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('配置连接'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('启用远程控制'));
    await tester.enterText(find.byType(TextField).at(0), 'localhost');
    await tester.enterText(find.byType(TextField).at(2), 'new-gateway');
    await tester.tap(find.text('保存配置'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.text('new-gateway'), findsOneWidget);
    expect(find.byTooltip('编辑连接'), findsOneWidget);
    expect((await store.read())?.gatewayId, 'new-gateway');
    await tester.pumpWidget(const SizedBox.shrink());

    final restarted = AppController(AppDatabase.memory(), remoteStore: store);
    await tester.pumpWidget(MyApp(controller: restarted));
    await tester.pumpAndSettle();
    expect(find.text('new-gateway'), findsOneWidget);

    await restarted.clearRemoteSettings();
    await tester.pumpAndSettle();
    expect(find.byTooltip('配置连接'), findsOneWidget);
    expect(find.text('new-gateway'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('连接及登记状态自动刷新，重新配置保留选中的设备', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = MemoryRemoteSettingsStore();
    const settings = RemoteSettings(
      host: 'localhost',
      gatewayId: 'gw',
      bluetoothDeviceId: 'AA:BB:CC:DD:EE:01',
    );
    await store.write(settings);
    final mqtt = FakeMqtt()
      ..state = {
        'revision': 1,
        'devices': [
          {'deviceId': settings.bluetoothDeviceId, 'connection': 'connected'},
        ],
      };
    final controller = AppController(
      AppDatabase.memory(),
      remoteStore: store,
      remoteGateway: RemoteGateway(client: GatewayClient(transport: mqtt)),
    );
    await tester.pumpWidget(MyApp(controller: controller));
    await tester.pumpAndSettle();

    expect(controller.gatewayState.connected, isTrue);
    expect(controller.gatewayState.gatewayOnline, isTrue);
    expect(controller.deviceRegistry.registered, hasLength(1));
    expect(find.text('网关在线 · 共 1 台设备'), findsOneWidget);
    expect(find.text('鱼缸灯'), findsOneWidget);
    expect(controller.remote.lampConnected, isTrue);
    expect(
      tester.widget<OnlineStatusView>(find.byType(OnlineStatusView)).online,
      isTrue,
    );
    await controller.saveRemoteSettings(settings);
    await tester.pumpAndSettle();
    expect(controller.selectedDeviceId, settings.bluetoothDeviceId);
    expect(controller.remote.lampConnected, isTrue);
    expect(find.text('网关在线 · 共 1 台设备'), findsOneWidget);

    mqtt.statuses.add(false);
    await tester.pumpAndSettle();
    expect(find.text('MQTT 未连接'), findsOneWidget);
    expect(
      tester.widget<OnlineStatusView>(find.byType(OnlineStatusView)).online,
      isFalse,
    );
    await controller.mqttGateway.disconnect();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('窄屏首页启动及长网关标题滚动时布局正常', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = AppController(AppDatabase.memory());
    await tester.pumpWidget(MyApp(controller: controller));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(Marquee), findsNothing);
    expect(find.text('暂未连接'), findsOneWidget);

    await controller.saveRemoteSettings(
      RemoteSettings(
        host: 'localhost',
        gatewayId: 'gateway-${List.filled(56, 'a').join()}',
        enabled: false,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull);
    expect(find.byType(Marquee), findsOneWidget);
    final titleSize = tester.getSize(find.byType(Marquee));
    expect(titleSize.width, inExclusiveRange(0, 320));
    expect(titleSize.height, greaterThan(0));
    expect(find.byTooltip('编辑连接'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
