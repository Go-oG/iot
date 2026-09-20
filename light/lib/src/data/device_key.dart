import 'dart:convert';

/// 网关内的设备标识共同组成持久身份，名称和 MAC 不参与主键
class DeviceKey {
  const DeviceKey(this.gatewayId, this.deviceId);
  final String gatewayId;
  final String deviceId;
  String get storageKey => jsonEncode([gatewayId, deviceId]);
  @override
  bool operator ==(Object other) => other is DeviceKey && gatewayId == other.gatewayId && deviceId == other.deviceId;
  @override
  int get hashCode => Object.hash(gatewayId, deviceId);
}
