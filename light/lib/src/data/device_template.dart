import 'dart:convert';

import '../core/device/device.dart';
import '../core/device/device_definition.dart';
import 'device_key.dart';

/// 一份可被多台真实设备复用的协议模板
///
/// [Device] 在这里只保存属性、报文和界面定义，不携带真实设备标识。
class DeviceTemplate {
  DeviceTemplate._(
    this.definition, {
    this.gatewayId = '',
    this.builtIn = false,
  });

  factory DeviceTemplate.fromJson(Map<String, Object?> json) {
    return DeviceTemplate._(DeviceDefinition.fromJson(json));
  }

  factory DeviceTemplate.fromJsonString(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('设备模板必须是 JSON 对象');
    }
    return DeviceTemplate.fromJson(decoded);
  }

  factory DeviceTemplate.fromDevice(
    Device device, {
    String gatewayId = '',
    bool builtIn = false,
  }) {
    return DeviceTemplate._(
      DeviceDefinition.fromJson(device.toJson()),
      gatewayId: gatewayId,
      builtIn: builtIn,
    );
  }

  final DeviceDefinition definition;
  final String gatewayId;
  final bool builtIn;

  DeviceKey get key => DeviceKey(gatewayId, id);

  DeviceTemplate withGateway(String gatewayId, {bool? builtIn}) =>
      DeviceTemplate._(
        definition,
        gatewayId: gatewayId,
        builtIn: builtIn ?? this.builtIn,
      );

  String get id => definition.id;
  String get name => definition.name;
  int get propertyCount => definition.properties.length;

  Map<String, dynamic> toJson() => definition.toJson();

  String toJsonString() =>
      const JsonEncoder.withIndent('  ').convert(definition.toJson());
}
