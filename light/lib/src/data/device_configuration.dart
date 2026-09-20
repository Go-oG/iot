import 'dart:convert';

import 'device_key.dart';

import '../core/device_model.dart';

/// 一台设备的定义：直接保存 [DeviceModel] 的 JSON
///
/// 设备模型同时描述属性、能力、报文布局和界面渲染器，因此配置里不再区分
/// 协议类型，也不再保存任何设备私有的 Dart 结构。
class DeviceConfiguration {
  DeviceConfiguration._(this.model, [this.gatewayId = '']);

  factory DeviceConfiguration.fromJson(Map<String, Object?> json) {
    return DeviceConfiguration._(DeviceModel.fromJson(json));
  }

  factory DeviceConfiguration.fromJsonString(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, Object?>)
      throw const FormatException('设备配置必须是 JSON 对象');
    return DeviceConfiguration.fromJson(decoded);
  }

  final DeviceModel model;
  final String gatewayId;
  DeviceKey get key => DeviceKey(gatewayId, id);
  DeviceConfiguration withGateway(String gatewayId) =>
      DeviceConfiguration._(model, gatewayId);

  String get id => model.id;
  String get name => model.name;

  Map<String, Object?> toJson() => model.toJson();

  String toJsonString() =>
      const JsonEncoder.withIndent('  ').convert(model.toJson());
}
