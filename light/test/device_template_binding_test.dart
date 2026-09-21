import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:light/src/app/controller.dart';
import 'package:light/src/core/device/device.dart';
import 'package:light/src/data/database.dart';
import 'package:light/src/data/device_template.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  setUpAll(() {
    final source = File('assets/devices/at5.json').readAsStringSync();
    Device.loadDefinitionSources({'at5': source});
  });

  test('一份协议模板可以绑定并创建多台独立设备会话', () async {
    final decoded = jsonDecode(
      File('assets/devices/at5.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final template = DeviceTemplate.fromJson({
      ...decoded,
      'id': 'at5-shared',
      'name': '共享 AT5 模板',
    });
    final controller = AppController(AppDatabase.memory());
    addTearDown(controller.dispose);
    controller.initialize();
    controller.saveDeviceTemplate(template);

    for (var index = 1; index <= 6; index++) {
      await controller.bindDeviceModel(
        'device-$index',
        template.id,
        name: '鱼缸灯 $index',
      );
    }

    expect(controller.deviceTemplates, hasLength(1));
    expect(controller.savedDevices, hasLength(6));
    expect(controller.savedDevices.map((item) => item.modelId).toSet(), {
      template.id,
    });
    expect(controller.resolvedModelIdFor('device-1'), template.id);

    final first = controller.deviceFor('device-1');
    final second = controller.deviceFor('device-2');
    expect(first, isNotNull);
    expect(second, isNotNull);
    expect(first, isNot(same(second)));
    expect(first!.deviceId, 'device-1');
    expect(first.modelId, template.id);
    expect(second!.deviceId, 'device-2');
    expect(second.modelId, template.id);
  });

  test('旧 device_configurations 数据迁移为协议模板', () async {
    final directory = await Directory.systemTemp.createTemp('light-db-test-');
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}/light.sqlite3';
    final legacy = sqlite3.open(path);
    legacy.execute(
      'CREATE TABLE device_configurations ('
      'id TEXT NOT NULL PRIMARY KEY, data_json TEXT NOT NULL) STRICT',
    );
    legacy.execute(
      'INSERT INTO device_configurations(id, data_json) VALUES (?, ?)',
      [
        'at5-old',
        jsonEncode({
          ...jsonDecode(File('assets/devices/at5.json').readAsStringSync())
              as Map<String, dynamic>,
          'id': 'at5-old',
          'name': '旧协议模板',
        }),
      ],
    );
    legacy.execute('PRAGMA user_version = 5');
    legacy.close();

    final database = AppDatabase.openFile(path);
    addTearDown(database.close);
    final templates = database.loadDeviceTemplates();
    expect(templates, hasLength(1));
    expect(templates.single.id, 'at5-old');
    expect(templates.single.name, '旧协议模板');
  });
}
