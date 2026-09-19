import 'package:light/src/core/functions/fan_speed.dart';
import 'package:light/src/core/functions/light.dart';
import 'package:light/src/core/protocol/wire.dart';

import 'device_configuration.dart';

/// App 本地记录的设备型号，决定默认按哪套协议控制
enum DeviceModel implements WireEnum {
  /// AT5 灯具，使用 App 内置的报文格式
  at5('AT5'),

  /// 配置驱动的通用设备
  generic('GENERIC');

  const DeviceModel(this.wire);

  @override
  final String wire;

  static DeviceModel? valueOf(Object? raw) => wireValueOf(values, raw);

  /// 读取本地记录里的型号，未知取值按 AT5 处理
  static DeviceModel parse(Object? raw) => valueOf(raw) ?? at5;
}

class ScenePreset {
  const ScenePreset({
    required this.id,
    required this.name,
    required this.subtitle,
    required this.temperature,
    required this.brightness,
    required this.accentValue,
    required this.state,
  });

  final String id;
  final String name;
  final String subtitle;
  final int temperature;
  final int brightness;
  final int accentValue;
  final LightState state;

  ScenePreset copyWith({
    String? name,
    String? subtitle,
    int? temperature,
    int? brightness,
    int? accentValue,
    LightState? state,
  }) {
    return ScenePreset(
      id: id,
      name: name ?? this.name,
      subtitle: subtitle ?? this.subtitle,
      temperature: temperature ?? this.temperature,
      brightness: brightness ?? this.brightness,
      accentValue: accentValue ?? this.accentValue,
      state: state ?? this.state,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'name': name,
      'subtitle': subtitle,
      'temperature': temperature,
      'brightness': brightness,
      'accentValue': accentValue,
      'state': _lightStateToJson(state),
    };
  }

  factory ScenePreset.fromJson(Map<String, Object?> json) {
    return ScenePreset(
      id: _string(json['id']),
      name: _string(json['name']),
      subtitle: _string(json['subtitle']),
      temperature: _boundedInteger(json['temperature'], 4000, 2700, 6500),
      brightness: _boundedInteger(json['brightness'], 50, 0, 100),
      accentValue: _integer(json['accentValue'], 0xFF0878F9),
      state: _lightStateFromJson(_map(json['state'])),
    );
  }
}

class SchedulePlan {
  const SchedulePlan({
    required this.id,
    required this.enabled,
    required this.startHour,
    required this.startMinute,
    required this.endHour,
    required this.endMinute,
    required this.repeatLabel,
    required this.sceneId,
  });

  final int id;
  final bool enabled;
  final int startHour;
  final int startMinute;
  final int endHour;
  final int endMinute;
  final String repeatLabel;
  final String sceneId;

  SchedulePlan copyWith({
    bool? enabled,
    int? startHour,
    int? startMinute,
    int? endHour,
    int? endMinute,
    String? repeatLabel,
    String? sceneId,
  }) {
    return SchedulePlan(
      id: id,
      enabled: enabled ?? this.enabled,
      startHour: startHour ?? this.startHour,
      startMinute: startMinute ?? this.startMinute,
      endHour: endHour ?? this.endHour,
      endMinute: endMinute ?? this.endMinute,
      repeatLabel: repeatLabel ?? this.repeatLabel,
      sceneId: sceneId ?? this.sceneId,
    );
  }

  String get timeLabel =>
      '${_two(startHour)}:${_two(startMinute)} – ${_two(endHour)}:${_two(endMinute)}';

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'enabled': enabled,
      'startHour': startHour,
      'startMinute': startMinute,
      'endHour': endHour,
      'endMinute': endMinute,
      'repeatLabel': repeatLabel,
      'sceneId': sceneId,
    };
  }

  factory SchedulePlan.fromJson(Map<String, Object?> json) {
    return SchedulePlan(
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
    required this.model,
    required this.room,
    required this.lastConnectedAt,
  });

  final String id;
  final String name;
  final DeviceModel model;
  final String room;
  final DateTime lastConnectedAt;

  SavedDevice copyWith({
    String? name,
    String? room,
    DateTime? lastConnectedAt,
  }) {
    return SavedDevice(
      id: id,
      name: name ?? this.name,
      model: model,
      room: room ?? this.room,
      lastConnectedAt: lastConnectedAt ?? this.lastConnectedAt,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'name': name,
      'model': model.wire,
      'room': room,
      'lastConnectedAt': lastConnectedAt.toIso8601String(),
    };
  }

  factory SavedDevice.fromJson(Map<String, Object?> json) {
    return SavedDevice(
      id: _string(json['id']),
      name: _string(json['name']),
      model: DeviceModel.parse(json['model']),
      room: _string(json['room'], '未分组'),
      lastConnectedAt:
          DateTime.tryParse(_string(json['lastConnectedAt'])) ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

class ControlSettings {
  const ControlSettings({
    required this.lightState,
    required this.powerEnabled,
    required this.temperature,
    required this.fanSpeed,
    this.outputLimit = 100,
  });

  static const defaults = ControlSettings(
    lightState: LightState(red: 15, green: 15, blue: 17, white: 25, uv: 0),
    powerEnabled: true,
    temperature: 31,
    fanSpeed: FanSpeed.low,
  );

  final LightState lightState;
  final bool powerEnabled;
  final int temperature;
  final FanSpeed fanSpeed;
  final int outputLimit;

  Map<String, Object?> toJson() {
    return {
      'lightState': _lightStateToJson(lightState),
      'powerEnabled': powerEnabled,
      'temperature': temperature,
      'fanSpeed': fanSpeed.value,
      'outputLimit': outputLimit,
      'outputLimitVersion': 1,
    };
  }

  factory ControlSettings.fromJson(Map<String, Object?> json) {
    return ControlSettings(
      lightState: _lightStateFromJson(_map(json['lightState'])),
      powerEnabled: _boolean(json['powerEnabled'], true),
      temperature: _boundedInteger(json['temperature'], 31, 20, 80),
      fanSpeed:
          FanSpeed.fromValue(_integer(json['fanSpeed'], FanSpeed.low.value)) ??
          FanSpeed.low,
      // 旧版默认上限为 30，升级后使用完整范围并保留新版的手动设置
      outputLimit:
          _integer(json['outputLimitVersion']) < 1 && json['outputLimit'] == 30
          ? 100
          : _boundedInteger(json['outputLimit'], 100, 1, 100),
    );
  }
}

class AppDataBundle {
  const AppDataBundle({
    required this.scenes,
    required this.schedules,
    required this.devices,
    required this.settings,
    required this.exportedAt,
    this.deviceConfigurations = const [],
  });

  final List<ScenePreset> scenes;
  final List<SchedulePlan> schedules;
  final List<SavedDevice> devices;
  final ControlSettings settings;
  final DateTime exportedAt;
  final List<DeviceConfiguration> deviceConfigurations;

  Map<String, Object?> toJson() {
    return {
      'schemaVersion': 2,
      'kind': 'backup',
      'exportedAt': exportedAt.toIso8601String(),
      'scenes': scenes.map((item) => item.toJson()).toList(),
      'schedules': schedules.map((item) => item.toJson()).toList(),
      'devices': devices.map((item) => item.toJson()).toList(),
      'deviceConfigurations': deviceConfigurations
          .map((item) => item.toJson())
          .toList(),
      'settings': settings.toJson(),
    };
  }

  factory AppDataBundle.fromJson(Map<String, Object?> json) {
    final version = _integer(json['schemaVersion']);
    if (version != 2) {
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
              .map((item) => DeviceConfiguration.fromJson(_map(item)))
              .toList(),
        _ => throw const FormatException('deviceConfigurations 必须是数组'),
      },
      settings: ControlSettings.fromJson(_map(json['settings'])),
      exportedAt:
          DateTime.tryParse(_string(json['exportedAt'])) ?? DateTime.now(),
    );
  }
}

Map<String, Object?> _lightStateToJson(LightState state) => state.toJson();

LightState _lightStateFromJson(Map<String, Object?> json) {
  int channel(LightChannel key) =>
      _boundedInteger(json[key.wire], 50, 0, 100);
  return LightState(
    red: channel(LightChannel.red),
    green: channel(LightChannel.green),
    blue: channel(LightChannel.blue),
    white: channel(LightChannel.white),
    uv: channel(LightChannel.uv),
  );
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
