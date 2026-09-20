import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:light/src/app/controller.dart';
import 'package:light/src/core/device_model.dart';
import 'package:light/src/core/protocol/client.dart';
import 'package:light/src/core/remote_gateway.dart';
import 'package:light/src/data/database.dart';
import 'package:light/src/data/models.dart';
import 'package:light/src/data/remote_settings.dart';
import 'package:sqlite3/sqlite3.dart';

import 'helpers/at5_device.dart';
import 'helpers/fake_mqtt.dart';

const settings = RemoteSettings(
  host: 'localhost',
  gatewayId: 'gw',
  bluetoothDeviceId: 'at5',
);

Future<void> flush() => Future<void>.delayed(const Duration(milliseconds: 10));

const scene = ScenePreset(
  id: 'scene-1',
  name: '测试配色',
  subtitle: '会话下发',
  accentValue: 0xFF38A7FF,
  properties: {
    'power': true,
    'channels': {'red': 10, 'green': 20, 'blue': 30, 'white': 40, 'uv': 0},
  },
);

void main() {
  setUpAll(loadDeviceModelCatalog);

  test('配色与计划保存属性值，旧字段自动转换', () {
    final legacy = ScenePreset.fromJson({
      'id': 'legacy',
      'name': '旧配色',
      'subtitle': '来自旧版本',
      'accentValue': 0xFF0878F9,
      'state': {'red': 30, 'green': 20, 'blue': 10, 'white': 5, 'uv': 0},
    });
    expect(legacy.properties['power'], true);
    expect(legacy.properties['channels'], {
      'red': 30,
      'green': 20,
      'blue': 10,
      'white': 5,
      'uv': 0,
    });
    expect(legacy.brightness, 13);
    expect(ScenePreset.fromJson(legacy.toJson()).properties, legacy.properties);

    final plan = SchedulePlan.fromJson({
      'id': 2,
      'enabled': true,
      'startHour': 7,
      'startMinute': 5,
      'endHour': 8,
      'endMinute': 0,
      'repeatLabel': '每天',
      'sceneId': 'legacy',
    });
    expect(plan.enabled, true);
    expect(plan.timeLabel, '07:05 – 08:00');
    expect(plan.properties[SchedulePlan.timerProperty], containsPair('index', 2));

    final toggled = plan.copyWith(enabled: false);
    expect(toggled.enabled, false);
    expect(SchedulePlan.fromJson(toggled.toJson()).enabled, false);
  });

  test('备份不再包含控制设置，旧版本仍可导入', () {
    final bundle = AppDataBundle(
      scenes: const [],
      schedules: const [],
      devices: const [],
      exportedAt: DateTime(2026),
    );
    expect(bundle.toJson()['schemaVersion'], 4);
    expect(bundle.toJson().containsKey('settings'), isFalse);
    expect(bundle.toJson().containsKey('deviceSettings'), isFalse);

    final restored = AppDataBundle.fromJson({
      'schemaVersion': 3,
      'exportedAt': '2026-01-01T00:00:00.000',
      'scenes': [
        {
          'id': 'legacy',
          'name': '旧配色',
          'subtitle': '',
          'accentValue': 0xFF0878F9,
          'state': {'red': 30, 'green': 20, 'blue': 10, 'white': 5, 'uv': 0},
        },
      ],
      'schedules': const [],
      'devices': const [],
      'settings': {'outputLimit': 30},
      'deviceSettings': const [],
    });
    expect(restored.scenes.single.channels['red'], 30);
  });

  test('本机数据库不再保留设置表', () async {
    final directory = await Directory.systemTemp.createTemp('light_db');
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}${Platform.pathSeparator}light.sqlite3';
    AppDatabase.openFile(path).close();

    final raw = sqlite3.open(path);
    final tables = raw
        .select("SELECT name FROM sqlite_master WHERE type = 'table'")
        .map((row) => row['name'] as String)
        .toSet();
    raw.close();

    expect(tables, containsAll(['scenes', 'schedules', 'saved_devices']));
    expect(tables, isNot(contains('app_settings')));
    expect(tables, isNot(contains('device_settings')));
  });

  test('配色、计划与输出上限都经设备模型会话下发', () async {
    final store = MemoryRemoteSettingsStore();
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
    addTearDown(controller.dispose);
    await controller.startConnections();
    await flush();
    await controller.selectDevice(settings.bluetoothDeviceId, '鱼缸灯');

    await controller.applyScene(scene);
    expect(_writeSteps(mqtt)['write:power'], '3443888805000101230E');
    expect(_writeSteps(mqtt)['write:channels'], '344388880300050A141E2800BBAC');

    await controller.setOutputLimit(25);
    final runtime = DeviceModelRuntime(at5DeviceModel);
    final clamped = HexCodec.encode(
      runtime.encodeWrite('channels', const {
        'red': 10,
        'green': 20,
        'blue': 25,
        'white': 25,
        'uv': 0,
      }),
    );
    expect(_writeSteps(mqtt)['write:channels'], clamped);

    final plan = SchedulePlan.fromFields(
      id: 2,
      enabled: true,
      startHour: 7,
      startMinute: 5,
      endHour: 8,
      endMinute: 0,
      repeatLabel: '每天',
      sceneId: scene.id,
    );
    controller.saveSchedule(plan);
    await controller.toggleSchedule(plan);
    final timerSteps = _writeSteps(mqtt);
    // toggleSchedule 取反后再下发，期望值是关闭状态的那一份属性值
    expect(
      timerSteps['write:timer'],
      HexCodec.encode(
        runtime.encodeWrite(
          'timer',
          plan.copyWith(enabled: false).properties[SchedulePlan.timerProperty]!,
        ),
      ),
    );
    expect(
      controller.schedules.firstWhere((item) => item.id == plan.id).enabled,
      false,
    );
    expect(timerSteps.containsKey('write:time'), true);

    // 超出模型声明的槽位数量时由设备模型校验拒绝，不产生新的写入
    final overflow = SchedulePlan.fromFields(
      id: 3,
      enabled: false,
      startHour: 9,
      startMinute: 0,
      endHour: 10,
      endMinute: 0,
      repeatLabel: '每天',
      sceneId: scene.id,
    );
    await controller.toggleSchedule(overflow);
    expect(controller.userMessage, contains('未确认'));
    await controller.mqttGateway.disconnect();
  });
}

/// 最近一次批量下发里每个写步骤的十六进制报文
Map<String, Object?> _writeSteps(FakeMqtt mqtt) {
  final steps = <String, Object?>{};
  for (final frame in mqtt.sent) {
    for (final message in (frame['messages'] as List).whereType<Map>()) {
      if (message['op'] != 'batch') continue;
      final batch = (message['data'] as Map)['steps'] as List;
      for (final step in batch.whereType<Map>()) {
        if (step['op'] != 'write') continue;
        final id = step['id'];
        if (id is String) steps[id] = step['value'];
      }
    }
  }
  return steps;
}
