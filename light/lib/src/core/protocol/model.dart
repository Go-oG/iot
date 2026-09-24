import '../connection_status.dart';
import 'protocol.dart';

/// 网关上缓存的单个特征值
class GatewayCharacteristicValue {
  const GatewayCharacteristicValue({required this.value, required this.ts});

  final String value;
  final int ts;
}

/// 网关状态 缓存中的一台设备
class GatewayDeviceState {
  const GatewayDeviceState({
    required this.deviceId,
    this.connection = ConnectionStatus.disconnected,
    this.mac,
    this.name,
    this.addrType,
    this.rssi,
    this.lastSeen,
    this.characteristics = const {},
  });

  final String deviceId;
  final ConnectionStatus connection;
  final String? mac;
  final String? name;
  final String? addrType;
  final int? rssi;
  final int? lastSeen;

  /// 以 service/char 为键的特征值缓存
  final Map<String, GatewayCharacteristicValue> characteristics;

  bool get connected => connection == ConnectionStatus.connected;

  GatewayCharacteristicValue? value(String service, String characteristic) {
    return characteristics['${GatewayUuid.normalize(service)}/${GatewayUuid.normalize(characteristic)}'];
  }

  GatewayDeviceState copyWith({
    String? deviceId,
    ConnectionStatus? connection,
    String? mac,
    String? name,
    String? addrType,
    int? rssi,
    int? lastSeen,
    Map<String, GatewayCharacteristicValue>? characteristics,
  }) {
    return GatewayDeviceState(
      deviceId: deviceId ?? this.deviceId,
      connection: connection ?? this.connection,
      mac: mac ?? this.mac,
      name: name ?? this.name,
      addrType: addrType ?? this.addrType,
      rssi: rssi ?? this.rssi,
      lastSeen: lastSeen ?? this.lastSeen,
      characteristics: characteristics ?? this.characteristics,
    );
  }
}

/// 网关客户端状态，供上层界面判断能否下发命令
class GatewayClientSnapshot {
  const GatewayClientSnapshot({
    this.connection = ConnectionStatus.disconnected,
    this.gatewayOnline = false,
    this.version,
    this.devices = const {},
    this.capabilities,
    this.lastSeen,
    this.message,
  });
  final ConnectionStatus connection;
  final bool gatewayOnline;
  final int? version;
  final Map<String, GatewayDeviceState> devices;
  final Map<String, Object?>? capabilities;
  final DateTime? lastSeen;
  final String? message;
  bool get connected => connection.isConnected;

  GatewayDeviceState? deviceOf(String deviceId) => devices[deviceId];

  GatewayClientSnapshot copyWith({
    ConnectionStatus? connection,
    bool? gatewayOnline,
    int? version,
    Map<String, GatewayDeviceState>? devices,
    Map<String, Object?>? capabilities,
    DateTime? lastSeen,
    String? message,
  }) {
    return GatewayClientSnapshot(
      connection: connection ?? this.connection,
      gatewayOnline: gatewayOnline ?? this.gatewayOnline,
      version: version ?? this.version,
      devices: devices ?? this.devices,
      capabilities: capabilities ?? this.capabilities,
      lastSeen: lastSeen ?? this.lastSeen,
      message: message ?? this.message,
    );
  }
}

/// 网关上行的状态、连接、Notify 等事件
class GatewayEvent {
  const GatewayEvent(this.message, {this.retained = false});

  final GatewayMessage message;
  final bool retained;

  GatewayOption get op => message.op;

  String? get deviceId => message.deviceId;

  String? get service => message.service;

  String? get characteristic => message.characteristic;

  String? get value => message.value;

  Map<String, Object?>? get data => message.data;
}

/// 来自主动快照的设备通知序号基线，不依赖网关时钟是否同步
class GatewayReportCursor {
  const GatewayReportCursor(this.bootId, this.sequence);
  final String bootId;
  final int sequence;
}