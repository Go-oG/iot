import 'dart:convert';
import 'dart:io';

import 'package:light/src/data/color_presets.dart';
import 'package:light/src/data/models.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import 'device_template.dart';

/// 本机数据库：只保存与设备无关的数据和属性值
///
/// 控制面板状态与设备模型会话都在内存里，数据库不再保存灯光参数、
/// 输出上限或按设备划分的本机设置，因此没有设置表
class AppDatabase {
  AppDatabase._(this._database);

  final Database _database;

  /// 当前 schema 版本，写入 SQLite 的 user_version
  static const int schemaVersion = 6;

  static Future<AppDatabase> open() async {
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    final path = '${directory.path}${Platform.pathSeparator}light.sqlite3';
    return AppDatabase.openFile(path);
  }

  factory AppDatabase.openFile(String path) {
    final appDatabase = AppDatabase._(sqlite3.open(path));
    appDatabase._migrate();
    return appDatabase;
  }

  static AppDatabase memory() {
    final appDatabase = AppDatabase._(sqlite3.openInMemory());
    appDatabase._migrate();
    return appDatabase;
  }

  List<ScenePreset> loadScenes() {
    return _database
        .select('SELECT id, data_json FROM scenes ORDER BY rowid')
        .map(
          (row) =>
              ScenePreset.fromJson(_decodeJson(row['data_json'] as String)),
        )
        .toList();
  }

  List<SchedulePlan> loadSchedules() {
    return _database
        .select('SELECT id, data_json FROM schedules ORDER BY id')
        .map(
          (row) =>
              SchedulePlan.fromJson(_decodeJson(row['data_json'] as String)),
        )
        .toList();
  }

  List<SavedDevice> loadDevices({String? gatewayId}) {
    final devices = _database
        .select(
          'SELECT gateway_id, id, data_json FROM saved_devices${gatewayId == null ? '' : ' WHERE gateway_id = ?'}',
          [?gatewayId],
        )
        .map(
          (row) =>
              SavedDevice.fromJson(_decodeJson(row['data_json'] as String))
                  .copyWith(gatewayId: row['gateway_id'] as String),
        )
        .toList();
    devices.sort(
      (left, right) => right.lastConnectedAt.compareTo(left.lastConnectedAt),
    );
    return devices;
  }

  void saveScene(ScenePreset scene) {
    _database.execute(
      'INSERT INTO scenes(id, data_json) VALUES (?, ?) '
      'ON CONFLICT(id) DO UPDATE SET data_json = excluded.data_json',
      [scene.id, jsonEncode(scene.toJson())],
    );
  }

  void deleteScene(String id) {
    final schedules = loadSchedules()
        .where((item) => item.sceneId == id)
        .toList();
    _transaction(() {
      for (final schedule in schedules) {
        _database.execute('DELETE FROM schedules WHERE id = ?', [schedule.id]);
      }
      _database.execute('DELETE FROM scenes WHERE id = ?', [id]);
    });
  }

  void saveSchedule(SchedulePlan plan) {
    _database.execute(
      'INSERT INTO schedules(id, data_json) VALUES (?, ?) '
      'ON CONFLICT(id) DO UPDATE SET data_json = excluded.data_json',
      [plan.id, jsonEncode(plan.toJson())],
    );
  }

  void deleteSchedule(int id) {
    _database.execute('DELETE FROM schedules WHERE id = ?', [id]);
  }

  void saveDevice(SavedDevice device) {
    _database.execute(
      'INSERT INTO saved_devices(gateway_id, id, data_json) VALUES (?, ?, ?) '
      'ON CONFLICT(gateway_id, id) DO UPDATE SET data_json = excluded.data_json',
      [device.gatewayId, device.id, jsonEncode(device.toJson())],
    );
  }

  void deleteDevice(String id, {String gatewayId = ''}) {
    _database.execute(
      'DELETE FROM saved_devices WHERE gateway_id = ? AND id = ?',
      [gatewayId, id],
    );
  }

  List<DeviceTemplate> loadDeviceTemplates({String? gatewayId}) => _database
      .select(
        'SELECT gateway_id, data_json FROM device_templates${gatewayId == null ? '' : ' WHERE gateway_id = ?'} ORDER BY rowid DESC',
        [?gatewayId],
      )
      .map(
        (row) =>
            DeviceTemplate.fromJsonString(row['data_json'] as String)
                .withGateway(row['gateway_id'] as String),
      )
      .toList();

  void saveDeviceTemplate(DeviceTemplate template, {String? previousId}) {
    _transaction(() {
      if (template.id != previousId &&
          _database.select(
            'SELECT id FROM device_templates WHERE gateway_id = ? AND id = ?',
            [template.gatewayId, template.id],
          ).isNotEmpty) {
        throw StateError('模板标识已存在，请更换标识后保存');
      }
      _database.execute(
        'INSERT INTO device_templates(gateway_id, id, data_json) VALUES (?, ?, ?) '
        'ON CONFLICT(gateway_id, id) DO UPDATE SET data_json = excluded.data_json',
        [template.gatewayId, template.id, template.toJsonString()],
      );
      if (previousId != null && previousId != template.id) {
        deleteDeviceTemplate(previousId, gatewayId: template.gatewayId);
      }
    });
  }

  void deleteDeviceTemplate(String id, {String gatewayId = ''}) =>
      _database.execute(
        'DELETE FROM device_templates WHERE gateway_id = ? AND id = ?',
        [gatewayId, id],
      );

  /// 旧版本的数据没有网关归属，连接成功后统一归到当前网关
  void bindLegacyGateway(String gatewayId) {
    if (gatewayId.isEmpty) return;
    _transaction(() {
      _database.execute(
        'UPDATE OR IGNORE saved_devices SET gateway_id = ? WHERE gateway_id = ?',
        [gatewayId, ''],
      );
    });
  }

  AppDataBundle exportData() {
    return AppDataBundle(
      scenes: loadScenes(),
      schedules: loadSchedules(),
      devices: loadDevices(),
      deviceTemplates: loadDeviceTemplates(),
      exportedAt: DateTime.now(),
    );
  }

  void replaceData(AppDataBundle data, {String legacyGatewayId = ''}) {
    _validateBackup(data);
    _transaction(() {
      _database.execute('DELETE FROM schedules');
      _database.execute('DELETE FROM scenes');
      _database.execute('DELETE FROM saved_devices');
      _database.execute('DELETE FROM device_templates');
      for (final scene in data.scenes) {
        saveScene(scene);
      }
      for (final schedule in data.schedules) {
        saveSchedule(schedule);
      }
      for (final device in data.devices) {
        saveDevice(
          device.gatewayId.isEmpty
              ? device.copyWith(gatewayId: legacyGatewayId)
              : device,
        );
      }
      for (final template in data.deviceTemplates) {
        _database.execute(
          'INSERT INTO device_templates(gateway_id, id, data_json) VALUES (?, ?, ?)',
          [
            template.gatewayId.isEmpty ? legacyGatewayId : template.gatewayId,
            template.id,
            template.toJsonString(),
          ],
        );
      }
    });
  }

  void resetData() {
    _transaction(() {
      _database.execute('DELETE FROM schedules');
      _database.execute('DELETE FROM scenes');
      _database.execute('DELETE FROM saved_devices');
      _database.execute('DELETE FROM device_templates');
    });
    _seed();
  }

  void close() => _database.close();

  void _migrate() {
    _database.execute('PRAGMA foreign_keys = OFF');
    final version = _userVersion();
    final legacyColumns =
        _tableExists('scenes') && !_columnExists('scenes', 'data_json');
    if (legacyColumns) _migrateLegacyTables();
    final legacyTemplateTable = _tableExists('device_configurations');
    _createJsonTables();
    _migrateScopedDevices();
    if (legacyTemplateTable) {
      _database.execute(
        'INSERT OR REPLACE INTO device_templates(gateway_id, id, data_json) '
        'SELECT gateway_id, id, data_json FROM device_configurations',
      );
      _database.execute('DROP TABLE device_configurations');
    }
    // 操作历史与面板设置表都已停用，旧库升级时直接删除
    _database.execute('DROP TABLE IF EXISTS activity_logs');
    _database.execute('DROP TABLE IF EXISTS device_settings');
    _database.execute('DROP TABLE IF EXISTS app_settings');
    _database.execute('PRAGMA user_version = $schemaVersion');
    // 只有全新数据库写入内置配色与默认计划，升级不覆盖用户改过的数据
    if (version < 1) {
      _seed();
    }
  }

  void _migrateScopedDevices() {
    _transaction(() {
      final tables = ['saved_devices'];
      if (_tableExists('device_configurations')) {
        tables.add('device_configurations');
      }
      for (final table in tables) {
        if (_columnExists(table, 'gateway_id')) continue;
        _database.execute('ALTER TABLE $table RENAME TO ${table}_v3');
        _database.execute(
          "CREATE TABLE $table (gateway_id TEXT NOT NULL DEFAULT '', id TEXT NOT NULL, data_json TEXT NOT NULL, PRIMARY KEY(gateway_id, id)) STRICT",
        );
        _database.execute(
          "INSERT INTO $table(gateway_id, id, data_json) SELECT '', id, data_json FROM ${table}_v3",
        );
        _database.execute('DROP TABLE ${table}_v3');
      }
    });
  }

  /// 旧版本把配色和计划拆成多列，这里按属性值重新写入 JSON 表
  void _migrateLegacyTables() {
    final scenes = _database
        .select('SELECT * FROM scenes ORDER BY sort_order')
        .map(_legacyScene)
        .toList();
    final schedules = _database
        .select('SELECT * FROM schedules ORDER BY id')
        .map(_legacySchedule)
        .toList();
    final devices = _database
        .select('SELECT * FROM saved_devices')
        .map(_legacyDevice)
        .toList();

    _transaction(() {
      _database.execute('DROP TABLE IF EXISTS schedules');
      _database.execute('DROP TABLE IF EXISTS scenes');
      _database.execute('DROP TABLE IF EXISTS saved_devices');
      _createJsonTables();
      for (final scene in scenes) {
        saveScene(scene);
      }
      for (final schedule in schedules) {
        saveSchedule(schedule);
      }
      for (final device in devices) {
        saveDevice(device);
      }
    });
  }

  void _createJsonTables() {
    _database.execute(
      "CREATE TABLE IF NOT EXISTS device_templates (gateway_id TEXT NOT NULL DEFAULT '', id TEXT NOT NULL, data_json TEXT NOT NULL, PRIMARY KEY(gateway_id, id)) STRICT",
    );
    _database.execute('''
      CREATE TABLE IF NOT EXISTS scenes (
        id TEXT PRIMARY KEY,
        data_json TEXT NOT NULL
      ) STRICT
    ''');
    _database.execute('''
      CREATE TABLE IF NOT EXISTS schedules (
        id INTEGER PRIMARY KEY,
        data_json TEXT NOT NULL
      ) STRICT
    ''');
    _database.execute('''
      CREATE TABLE IF NOT EXISTS saved_devices (
        gateway_id TEXT NOT NULL DEFAULT '',
        id TEXT NOT NULL,
        data_json TEXT NOT NULL,
        PRIMARY KEY(gateway_id, id)
      ) STRICT
    ''');
  }

  /// 写入内置配色与默认计划，恢复默认数据时同样走这里
  void _seed() {
    _transaction(() {
      if ((_database
                  .select('SELECT COUNT(*) AS count FROM scenes')
                  .first['count']
              as int) ==
          0) {
        for (final preset in [
          ...aquariumColorPresets,
          ...aquariumCommunityColorPresets,
        ]) {
          saveScene(preset);
        }
      }
      if ((_database
                  .select('SELECT COUNT(*) AS count FROM schedules')
                  .first['count']
              as int) ==
          0) {
        _seedSchedules();
      }
    });
  }

  void _seedSchedules() {
    final schedules = [
      SchedulePlan.fromFields(
        id: 1,
        enabled: true,
        startHour: 7,
        startMinute: 0,
        endHour: 8,
        endMinute: 0,
        repeatLabel: '周一至周五',
        sceneId: 'aquarium_daylight',
      ),
      SchedulePlan.fromFields(
        id: 2,
        enabled: true,
        startHour: 12,
        startMinute: 0,
        endHour: 14,
        endMinute: 0,
        repeatLabel: '每天',
        sceneId: 'aquarium_warm',
      ),
      SchedulePlan.fromFields(
        id: 3,
        enabled: true,
        startHour: 18,
        startMinute: 0,
        endHour: 21,
        endMinute: 0,
        repeatLabel: '每天',
        sceneId: 'aquarium_blue',
      ),
      SchedulePlan.fromFields(
        id: 4,
        enabled: false,
        startHour: 22,
        startMinute: 0,
        endHour: 6,
        endMinute: 0,
        repeatLabel: '每天',
        sceneId: 'aquarium_evening',
      ),
    ];
    for (final schedule in schedules) {
      saveSchedule(schedule);
    }
  }

  ScenePreset _legacyScene(Row row) {
    return ScenePreset(
      id: row['id'] as String,
      name: row['name'] as String,
      subtitle: row['subtitle'] as String,
      accentValue: row['accent_value'] as int,
      properties: {
        'power': true,
        presetChannelProperty: {
          'red': row['red'] as int,
          'green': row['green'] as int,
          'blue': row['blue'] as int,
          'white': row['white_channel'] as int,
          'uv': row['uv'] as int,
        },
      },
    );
  }

  SchedulePlan _legacySchedule(Row row) {
    return SchedulePlan.fromFields(
      id: row['id'] as int,
      enabled: (row['enabled'] as int) == 1,
      startHour: row['start_hour'] as int,
      startMinute: row['start_minute'] as int,
      endHour: row['end_hour'] as int,
      endMinute: row['end_minute'] as int,
      repeatLabel: row['repeat_label'] as String,
      sceneId: row['scene_id'] as String,
    );
  }

  SavedDevice _legacyDevice(Row row) {
    return SavedDevice(
      id: row['id'] as String,
      name: row['name'] as String,
      room: row['room'] as String,
      lastConnectedAt: DateTime.fromMillisecondsSinceEpoch(
        row['last_connected_at'] as int,
      ),
    );
  }

  void _validateBackup(AppDataBundle data) {
    final sceneIds = data.scenes.map((item) => item.id).toSet();
    if (sceneIds.length != data.scenes.length ||
        sceneIds.any((id) => id.isEmpty) ||
        data.scenes.any((item) => item.name.isEmpty)) {
      throw const FormatException('配色标识重复或为空');
    }
    final scheduleIds = data.schedules.map((item) => item.id).toSet();
    if (scheduleIds.length != data.schedules.length ||
        scheduleIds.any((id) => id <= 0)) {
      throw const FormatException('计划标识重复或无效');
    }
    if (data.schedules.any((item) => !sceneIds.contains(item.sceneId))) {
      throw const FormatException('计划引用了不存在的配色');
    }
    final deviceIds = data.devices.map((item) => item.key).toSet();
    if (deviceIds.length != data.devices.length ||
        deviceIds.any((key) => key.deviceId.isEmpty)) {
      throw const FormatException('设备标识重复或为空');
    }
    if (data.deviceTemplates.map((item) => item.key).toSet().length !=
        data.deviceTemplates.length) {
      throw const FormatException('协议模板标识重复');
    }
  }

  int _userVersion() =>
      _database.select('PRAGMA user_version').first.values.first as int;

  bool _tableExists(String table) {
    return _database.select(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      [table],
    ).isNotEmpty;
  }

  bool _columnExists(String table, String column) {
    return _database
        .select('PRAGMA table_info($table)')
        .any((row) => row['name'] == column);
  }

  Map<String, Object?> _decodeJson(String value) {
    final decoded = jsonDecode(value);
    if (decoded is! Map) {
      throw const FormatException('数据库中的 JSON 数据格式无效');
    }
    return decoded.map((key, item) => MapEntry(key.toString(), item));
  }

  T _transaction<T>(T Function() action) {
    _database.execute('BEGIN IMMEDIATE');
    try {
      final result = action();
      _database.execute('COMMIT');
      return result;
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
  }
}
