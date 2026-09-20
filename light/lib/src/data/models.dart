import 'device_configuration.dart';
import 'device_key.dart';

/// 配色：直接保存设备模型里的属性值
///
/// 应用配色就是把这里的属性值经 DeviceModelSession 写进设备，
/// 因此本机不再保存灯光面板状态，也不再按设备私有结构序列化
class ScenePreset {
  const ScenePreset({
    required this.id,
    required this.name,
    required this.subtitle,
    required this.accentValue,
    required this.properties,
  });

  final String id;
  final String name;
  final String subtitle;
  final int accentValue;

  /// 属性值，键是设备模型里的属性标识
  final Map<String, Object?> properties;

  ScenePreset copyWith({
    String? name,
    String? subtitle,
    int? accentValue,
    Map<String, Object?>? properties,
  }) {
    return ScenePreset(
      id: id,
      name: name ?? this.name,
      subtitle: subtitle ?? this.subtitle,
      accentValue: accentValue ?? this.accentValue,
      properties: properties ?? this.properties,
    );
  }

  /// 颜色通道：取第一个数值型对象属性，供卡片展示与配色模板使用
  Map<String, int> get channels {
    for (final value in properties.values) {
      if (value is! Map) continue;
      final channels = <String, int>{};
      for (final entry in value.entries) {
        final item = entry.value;
        if (item is num) channels['${entry.key}'] = item.round();
      }
      if (channels.isNotEmpty) return channels;
    }
    return const {};
  }

  /// 通道平均值，只用于卡片展示
  int get brightness {
    final values = channels.values;
    if (values.isEmpty) return 0;
    return (values.reduce((left, right) => left + right) / values.length)
        .round();
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'name': name,
      'subtitle': subtitle,
      'accentValue': accentValue,
      'properties': properties,
    };
  }

  factory ScenePreset.fromJson(Map<String, Object?> json) {
    return ScenePreset(
      id: _string(json['id']),
      name: _string(json['name']),
      subtitle: _string(json['subtitle']),
      accentValue: _integer(json['accentValue'], 0xFF0878F9),
      properties: _sceneProperties(json),
    );
  }

  /// 旧版本把五路数值写在 state 字段里，这里转换成属性值
  static Map<String, Object?> _sceneProperties(Map<String, Object?> json) {
    final properties = _map(json['properties']);
    if (properties.isNotEmpty) return properties;
    final state = _map(json['state']);
    if (state.isEmpty) return const {};
    return {
      'power': true,
      'channels': {
        for (final key in _legacyChannelKeys)
          key: _boundedInteger(state[key], 0, 0, 100),
      },
    };
  }
}

/// 旧版本配色里的五路通道名，与内置 AT5 模型的 channels 字段一致
const List<String> _legacyChannelKeys = ['red', 'green', 'blue', 'white', 'uv'];

/// 计划：定时槽位同样以属性值保存，开关计划时按属性下发
class SchedulePlan {
  const SchedulePlan({
    required this.id,
    required this.repeatLabel,
    required this.sceneId,
    required this.properties,
  });

  /// 定时槽位的属性标识
  static const String timerProperty = 'timer';

  final int id;
  final String repeatLabel;
  final String sceneId;

  /// 属性值，键是设备模型里的属性标识
  final Map<String, Object?> properties;

  Map<String, Object?> get timer => _map(properties[timerProperty]);

  bool get enabled => timer['enabled'] == true;

  int get startHour => _integer(timer['startHour']);

  int get startMinute => _integer(timer['startMinute']);

  int get endHour => _integer(timer['endHour']);

  int get endMinute => _integer(timer['endMinute']);

  String get timeLabel =>
      '${_two(startHour)}:${_two(startMinute)} – ${_two(endHour)}:${_two(endMinute)}';

  /// 用界面字段拼出一份定时槽位属性值
  factory SchedulePlan.fromFields({
    required int id,
    required bool enabled,
    required int startHour,
    required int startMinute,
    required int endHour,
    required int endMinute,
    required String repeatLabel,
    required String sceneId,
  }) {
    return SchedulePlan(
      id: id,
      repeatLabel: repeatLabel,
      sceneId: sceneId,
      properties: {
        timerProperty: {
          'index': id,
          'enabled': enabled,
          'startHour': startHour,
          'startMinute': startMinute,
          'endHour': endHour,
          'endMinute': endMinute,
          'sunriseSunsetEnabled': true,
          'sunriseMinutes': 30,
          'sunsetMinutes': 30,
        },
      },
    );
  }

  SchedulePlan copyWith({
    bool? enabled,
    int? startHour,
    int? startMinute,
    int? endHour,
    int? endMinute,
    String? repeatLabel,
    String? sceneId,
  }) {
    final current = timer;
    return SchedulePlan(
      id: id,
      repeatLabel: repeatLabel ?? this.repeatLabel,
      sceneId: sceneId ?? this.sceneId,
      properties: {
        ...properties,
        timerProperty: {
          ...current,
          'index': current['index'] ?? id,
          'enabled': enabled ?? this.enabled,
          'startHour': startHour ?? this.startHour,
          'startMinute': startMinute ?? this.startMinute,
          'endHour': endHour ?? this.endHour,
          'endMinute': endMinute ?? this.endMinute,
          'sunriseSunsetEnabled': current['sunriseSunsetEnabled'] ?? true,
          'sunriseMinutes': current['sunriseMinutes'] ?? 30,
          'sunsetMinutes': current['sunsetMinutes'] ?? 30,
        },
      },
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'repeatLabel': repeatLabel,
      'sceneId': sceneId,
      'properties': properties,
    };
  }

  factory SchedulePlan.fromJson(Map<String, Object?> json) {
    final properties = _map(json['properties']);
    if (properties.isNotEmpty) {
      return SchedulePlan(
        id: _integer(json['id']),
        repeatLabel: _string(json['repeatLabel'], '每天'),
        sceneId: _string(json['sceneId']),
        properties: properties,
      );
    }
    // 旧版本把定时字段平铺在计划里，这里转换成定时槽位属性值
    return SchedulePlan.fromFields(
      id: _integer(json['id']),
      enabled: _boolean(json['enabled'], true),
      startHour: _boundedInteger(json['startHour'], 0, 0, 23),
      startMinute: _boundedInteger(json['startMinute'], 0, 0, 59),
      endHour: _boundedInteger(json['endHour'], 0, 0, 23),
      endMinute: _boundedInteger(json['endMinute'], 0, 0, 59),
      repeatLabel: _string(json['repeatLabel'], '每天'),
      sceneId: _string(json['sceneId']),
    );
  }

  static String _two(int value) => value.toString().padLeft(2, '0');
}

class SavedDevice {
  const SavedDevice({
    required this.id,
    required this.name,
    required this.room,
    required this.lastConnectedAt,
    this.gatewayId = '',
  });

  final String id;
  final String gatewayId;
  DeviceKey get key => DeviceKey(gatewayId, id);
  final String name;
  final String room;
  final DateTime lastConnectedAt;

  SavedDevice copyWith({
    String? gatewayId,
    String? name,
    String? room,
    DateTime? lastConnectedAt,
  }) {
    return SavedDevice(
      id: id,
      gatewayId: gatewayId ?? this.gatewayId,
      name: name ?? this.name,
      room: room ?? this.room,
      lastConnectedAt: lastConnectedAt ?? this.lastConnectedAt,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'gatewayId': gatewayId,
      'name': name,
      'room': room,
      'lastConnectedAt': lastConnectedAt.toIso8601String(),
    };
  }

  factory SavedDevice.fromJson(Map<String, Object?> json) {
    return SavedDevice(
      id: _string(json['id']),
      gatewayId: _string(json['gatewayId']),
      name: _string(json['name']),
      room: _string(json['room'], '未分组'),
      lastConnectedAt:
          DateTime.tryParse(_string(json['lastConnectedAt'])) ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

/// 本机数据：配色、计划、设备与设备模型，全部是设备无关的属性值
class AppDataBundle {
  const AppDataBundle({
    required this.scenes,
    required this.schedules,
    required this.devices,
    required this.exportedAt,
    this.deviceConfigurations = const [],
  });

  final List<ScenePreset> scenes;
  final List<SchedulePlan> schedules;
  final List<SavedDevice> devices;
  final DateTime exportedAt;
  final List<DeviceConfiguration> deviceConfigurations;

  Map<String, Object?> toJson() {
    return {
      'schemaVersion': 4,
      'kind': 'backup',
      'exportedAt': exportedAt.toIso8601String(),
      'scenes': scenes.map((item) => item.toJson()).toList(),
      'schedules': schedules.map((item) => item.toJson()).toList(),
      'devices': devices.map((item) => item.toJson()).toList(),
      'deviceConfigurations': deviceConfigurations
          .map(
            (item) => {
              'gatewayId': item.gatewayId,
              'configuration': item.toJson(),
            },
          )
          .toList(),
    };
  }

  factory AppDataBundle.fromJson(Map<String, Object?> json) {
    final version = _integer(json['schemaVersion']);
    // 3 是旧的面板状态版本，导入时按属性值转换
    if (version != 3 && version != 4) {
      throw const FormatException('不支持的备份文件版本');
    }
    return AppDataBundle(
      scenes: _list(json['scenes'])
          .map((item) => ScenePreset.fromJson(_map(item)))
          .toList(),
      schedules: _list(json['schedules'])
          .map((item) => SchedulePlan.fromJson(_map(item)))
          .toList(),
      devices: _list(json['devices'])
          .map((item) => SavedDevice.fromJson(_map(item)))
          .toList(),
      deviceConfigurations: switch (json['deviceConfigurations']) {
        null => const [],
        List values =>
          values
              .map(
                (item) => DeviceConfiguration.fromJson(
                  _map(_map(item)['configuration']),
                ).withGateway(_string(_map(item)['gatewayId'])),
              )
              .toList(),
        _ => throw const FormatException('deviceConfigurations 必须是数组'),
      },
      exportedAt:
          DateTime.tryParse(_string(json['exportedAt'])) ?? DateTime.now(),
    );
  }
}

Map<String, Object?> _map(Object? value) {
  if (value is Map<String, Object?>) {
    return value;
  }
  if (value is Map) {
    return value.map((key, item) => MapEntry(key.toString(), item));
  }
  return const {};
}

List<Object?> _list(Object? value) => value is List ? value : const [];

String _string(Object? value, [String fallback = '']) =>
    value is String ? value : fallback;

int _integer(Object? value, [int fallback = 0]) =>
    value is num ? value.toInt() : fallback;

int _boundedInteger(Object? value, int fallback, int minimum, int maximum) {
  return _integer(value, fallback).clamp(minimum, maximum);
}

bool _boolean(Object? value, [bool fallback = false]) =>
    value is bool ? value : fallback;
