import 'dart:convert';
import 'dart:io';

import 'package:light/src/core/functions/light.dart';
import 'package:light/src/data/color_presets.dart';
import 'package:light/src/data/models.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import 'device_configuration.dart';

class AppDatabase {
  AppDatabase._(this._database);

  final Database _database;

  static Future<AppDatabase> open() async {
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    final path = '${directory.path}${Platform.pathSeparator}light.sqlite3';
    final appDatabase = AppDatabase._(sqlite3.open(path));
    appDatabase._migrate();
    appDatabase._seed();
    return appDatabase;
  }

  static AppDatabase memory() {
    final appDatabase = AppDatabase._(sqlite3.openInMemory());
    appDatabase._migrate();
    appDatabase._seed();
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

  List<SavedDevice> loadDevices() {
    final devices = _database
        .select('SELECT id, data_json FROM saved_devices')
        .map(
          (row) =>
              SavedDevice.fromJson(_decodeJson(row['data_json'] as String)),
        )
        .toList();
    devices.sort(
      (left, right) => right.lastConnectedAt.compareTo(left.lastConnectedAt),
    );
    return devices;
  }

  ControlSettings loadSettings() {
    final rows = _database.select(
      'SELECT data_json FROM app_settings WHERE key = ?',
      ['control'],
    );
    if (rows.isEmpty) {
      return ControlSettings.defaults;
    }
    return ControlSettings.fromJson(
      _decodeJson(rows.first['data_json'] as String),
    );
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
      'INSERT INTO saved_devices(id, data_json) VALUES (?, ?) '
      'ON CONFLICT(id) DO UPDATE SET data_json = excluded.data_json',
      [device.id, jsonEncode(device.toJson())],
    );
  }

  void deleteDevice(String id) {
    _database.execute('DELETE FROM saved_devices WHERE id = ?', [id]);
  }

  List<DeviceConfiguration> loadDeviceConfigurations() => _database
      .select('SELECT data_json FROM device_configurations ORDER BY rowid DESC')
      .map(
        (row) => DeviceConfiguration.fromJsonString(row['data_json'] as String),
      )
      .toList();

  void saveDeviceConfiguration(
    DeviceConfiguration configuration, {
    String? previousId,
  }) {
    _transaction(() {
      if (configuration.id != previousId &&
          _database.select(
            'SELECT id FROM device_configurations WHERE id = ?',
            [configuration.id],
          ).isNotEmpty) {
        throw StateError('设备标识已存在，请更换标识后保存');
      }
      _database.execute(
        'INSERT INTO device_configurations(id, data_json) VALUES (?, ?) '
        'ON CONFLICT(id) DO UPDATE SET data_json = excluded.data_json',
        [configuration.id, configuration.toJsonString()],
      );
      if (previousId != null && previousId != configuration.id)
        deleteDeviceConfiguration(previousId);
    });
  }

  void deleteDeviceConfiguration(String id) =>
      _database.execute('DELETE FROM device_configurations WHERE id = ?', [id]);

  void saveSettings(ControlSettings settings) {
    _database.execute(
      'INSERT INTO app_settings(key, data_json) VALUES (?, ?) '
      'ON CONFLICT(key) DO UPDATE SET data_json = excluded.data_json',
      ['control', jsonEncode(settings.toJson())],
    );
  }

  AppDataBundle exportData() {
    return AppDataBundle(
      scenes: loadScenes(),
      schedules: loadSchedules(),
      devices: loadDevices(),
      deviceConfigurations: loadDeviceConfigurations(),
      settings: loadSettings(),
      exportedAt: DateTime.now(),
    );
  }

  void replaceData(AppDataBundle data) {
    _validateBackup(data);
    _transaction(() {
      _database.execute('DELETE FROM schedules');
      _database.execute('DELETE FROM scenes');
      _database.execute('DELETE FROM saved_devices');
      _database.execute('DELETE FROM device_configurations');
      for (final scene in data.scenes) {
        saveScene(scene);
      }
      for (final schedule in data.schedules) {
        saveSchedule(schedule);
      }
      for (final device in data.devices) {
        saveDevice(device);
      }
      for (final configuration in data.deviceConfigurations) {
        _database.execute(
          'INSERT INTO device_configurations(id, data_json) VALUES (?, ?)',
          [configuration.id, configuration.toJsonString()],
        );
      }
      saveSettings(data.settings);
    });
  }

  void resetData() {
    _transaction(() {
      _database.execute('DELETE FROM schedules');
      _database.execute('DELETE FROM scenes');
      _database.execute('DELETE FROM saved_devices');
      _database.execute('DELETE FROM device_configurations');
      _database.execute('DELETE FROM app_settings');
    });
    _seed();
  }

  void close() => _database.close();

  void _migrate() {
    _database.execute('PRAGMA foreign_keys = OFF');
    if (_tableExists('scenes') && !_columnExists('scenes', 'data_json')) {
      _migrateLegacyTables();
    }
    _createJsonTables();
    // 移除旧版本保存的操作历史
    _database.execute('DROP TABLE IF EXISTS activity_logs');
    _database.execute('PRAGMA user_version = 3');
  }

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
      'CREATE TABLE IF NOT EXISTS device_configurations (id TEXT PRIMARY KEY, data_json TEXT NOT NULL) STRICT',
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
        id TEXT PRIMARY KEY,
        data_json TEXT NOT NULL
      ) STRICT
    ''');
    _database.execute('''
      CREATE TABLE IF NOT EXISTS app_settings (
        key TEXT PRIMARY KEY,
        data_json TEXT NOT NULL
      ) STRICT
    ''');
  }

  void _seed() {
    _seedInitialPresets();
    _seedCommunityPresets();
    _dimSavedPresets();
  }

  void _dimSavedPresets() {
    if (_database.select('SELECT key FROM app_settings WHERE key = ?', [
      'aquarium_presets_v3',
    ]).isNotEmpty) {
      return;
    }
    _transaction(() {
      final existing = {for (final preset in loadScenes()) preset.id: preset};
      // 仅更新完整匹配旧默认值的配色，保留自定义修改与删除记录
      for (
        var index = 0;
        index < originalAquariumColorPresets.length;
        index++
      ) {
        final original = originalAquariumColorPresets[index];
        final current = existing[original.id];
        if (current != null &&
            jsonEncode(current.toJson()) == jsonEncode(original.toJson())) {
          saveScene(aquariumColorPresets[index]);
        }
      }
      _database.execute(
        'INSERT INTO app_settings(key, data_json) VALUES (?, ?)',
        ['aquarium_presets_v3', '{}'],
      );
    });
  }

  void _seedCommunityPresets() {
    if (_database.select('SELECT key FROM app_settings WHERE key = ?', [
      'aquarium_presets_v2',
    ]).isNotEmpty) {
      return;
    }
    _transaction(() {
      final existingIds = loadScenes().map((scene) => scene.id).toSet();
      // 只补充本次新增方案，避免恢复已删除的旧配色或覆盖同标识的自定义数据
      for (final preset in aquariumCommunityColorPresets) {
        if (!existingIds.contains(preset.id)) {
          saveScene(preset);
        }
      }
      _database.execute(
        'INSERT INTO app_settings(key, data_json) VALUES (?, ?)',
        ['aquarium_presets_v2', '{}'],
      );
    });
  }

  void _seedInitialPresets() {
    if (_database.select('SELECT key FROM app_settings WHERE key = ?', [
      'aquarium_presets_v1',
    ]).isNotEmpty) {
      return;
    }
    final existing = loadScenes();
    final isNewDatabase =
        existing.isEmpty &&
        _database.select('SELECT key FROM app_settings WHERE key = ?', [
          'control',
        ]).isEmpty;
    _transaction(() {
      // 仅替换未修改的旧默认方案，并保留计划关联
      for (var index = 0; index < _legacyScenePresets.length; index++) {
        final legacy = _legacyScenePresets[index];
        final current = existing
            .where((item) => item.id == legacy.id)
            .firstOrNull;
        if (current != null &&
            jsonEncode(current.toJson()) == jsonEncode(legacy.toJson())) {
          for (final plan in loadSchedules().where(
            (item) => item.sceneId == legacy.id,
          )) {
            saveSchedule(
              plan.copyWith(sceneId: aquariumColorPresets[index].id),
            );
          }
          _database.execute('DELETE FROM scenes WHERE id = ?', [legacy.id]);
        }
      }
      for (final preset in aquariumColorPresets) {
        if (!existing.any((item) => item.id == preset.id)) {
          saveScene(preset);
        }
      }
      if (isNewDatabase) {
        _seedSchedules();
      }
      if (_database.select('SELECT key FROM app_settings WHERE key = ?', [
        'control',
      ]).isEmpty) {
        saveSettings(ControlSettings.defaults);
      }
      // 用一次性标记避免用户删除的配色和计划在重启后重新出现
      _database.execute(
        'INSERT INTO app_settings(key, data_json) VALUES (?, ?)',
        ['aquarium_presets_v1', '{}'],
      );
    });
  }

  void _seedSchedules() {
    final scheduleCount = _database.select(
      'SELECT COUNT(*) AS count FROM schedules',
    );
    if ((scheduleCount.first['count'] as int) == 0) {
      final schedules = [
        const SchedulePlan(
          id: 1,
          enabled: true,
          startHour: 7,
          startMinute: 0,
          endHour: 8,
          endMinute: 0,
          repeatLabel: '周一至周五',
          sceneId: 'aquarium_daylight',
        ),
        const SchedulePlan(
          id: 2,
          enabled: true,
          startHour: 12,
          startMinute: 0,
          endHour: 14,
          endMinute: 0,
          repeatLabel: '每天',
          sceneId: 'aquarium_warm',
        ),
        const SchedulePlan(
          id: 3,
          enabled: true,
          startHour: 18,
          startMinute: 0,
          endHour: 21,
          endMinute: 0,
          repeatLabel: '每天',
          sceneId: 'aquarium_blue',
        ),
        const SchedulePlan(
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
  }

  ScenePreset _legacyScene(Row row) {
    return ScenePreset(
      id: row['id'] as String,
      name: row['name'] as String,
      subtitle: row['subtitle'] as String,
      temperature: row['temperature'] as int,
      brightness: row['brightness'] as int,
      accentValue: row['accent_value'] as int,
      state: LightState(
        red: row['red'] as int,
        green: row['green'] as int,
        blue: row['blue'] as int,
        white: row['white_channel'] as int,
        uv: row['uv'] as int,
      ),
    );
  }

  SchedulePlan _legacySchedule(Row row) {
    return SchedulePlan(
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
      model: DeviceModel.parse(row['model']),
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
    final deviceIds = data.devices.map((item) => item.id).toSet();
    if (deviceIds.length != data.devices.length ||
        deviceIds.any((id) => id.isEmpty)) {
      throw const FormatException('设备标识重复或为空');
    }
    if (data.deviceConfigurations.map((item) => item.id).toSet().length !=
        data.deviceConfigurations.length) {
      throw const FormatException('功能配置的设备标识重复');
    }
  }

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

// 用完整数据匹配旧默认值，避免覆盖用户改过的名称和通道参数
const _legacyScenePresets = [
  ScenePreset(
    id: 'daylight',
    name: '日光',
    subtitle: '清澈自然',
    temperature: 5000,
    brightness: 80,
    accentValue: 0xFF38A7FF,
    state: LightState(red: 72, green: 68, blue: 56, white: 82, uv: 36),
  ),
  ScenePreset(
    id: 'relax',
    name: '放松',
    subtitle: '柔和舒缓',
    temperature: 4000,
    brightness: 55,
    accentValue: 0xFF62D3B4,
    state: LightState(red: 52, green: 45, blue: 38, white: 70, uv: 22),
  ),
  ScenePreset(
    id: 'reading',
    name: '阅读',
    subtitle: '明亮专注',
    temperature: 5200,
    brightness: 92,
    accentValue: 0xFFFFB449,
    state: LightState(red: 80, green: 76, blue: 68, white: 100, uv: 36),
  ),
  ScenePreset(
    id: 'movie',
    name: '观影',
    subtitle: '低亮沉浸',
    temperature: 3200,
    brightness: 35,
    accentValue: 0xFF7C6BFF,
    state: LightState(red: 28, green: 22, blue: 40, white: 50, uv: 35),
  ),
  ScenePreset(
    id: 'sleep',
    name: '助眠',
    subtitle: '安静夜色',
    temperature: 2700,
    brightness: 22,
    accentValue: 0xFF465FCF,
    state: LightState(red: 12, green: 10, blue: 26, white: 42, uv: 20),
  ),
];
