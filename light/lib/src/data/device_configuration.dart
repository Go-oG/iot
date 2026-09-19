import 'dart:convert';

import '../core/device/function_type.dart';
import '../core/device/impl/generic_device.dart';

/// 功能类型的默认状态，取该功能在默认配置下的初始值
extension ConfigurableFunctionDefaults on ConfigurableFunction {
  Object get defaultStatus {
    final device = GenericDevice.fromJson({
      'id': 'default',
      'name': '默认配置',
      'functions': [
        {'type': wire},
      ],
    });
    try {
      return device.status[this]!;
    } finally {
      device.dispose();
    }
  }
}

class DeviceConfiguration {
  DeviceConfiguration._(this._json);

  factory DeviceConfiguration.fromJson(Map<String, Object?> json) {
    final device = GenericDevice.fromJson(json);
    try {
      return DeviceConfiguration._(device.toJson());
    } finally {
      device.dispose();
    }
  }

  factory DeviceConfiguration.fromJsonString(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, Object?>)
      throw const FormatException('设备配置必须是 JSON 对象');
    return DeviceConfiguration.fromJson(decoded);
  }

  final Map<String, Object?> _json;

  String get id => _json['id'] as String;
  String get name => _json['name'] as String;
  String get macd => _json['macd'] as String;

  Map<String, Object?> toJson() =>
      jsonDecode(jsonEncode(_json)) as Map<String, Object?>;

  List<Map<String, Object?>> get functions =>
      (toJson()['functions'] as List).cast<Map<String, Object?>>();

  String toJsonString() => const JsonEncoder.withIndent('  ').convert(_json);
}
