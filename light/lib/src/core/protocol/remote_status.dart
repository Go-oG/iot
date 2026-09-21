import '../connection_status.dart';

/// 远端连接状态
class RemoteStatus {
  const RemoteStatus({
    this.connection = ConnectionStatus.disconnected,
    this.mqttIsOnline = false,
    this.hardwareConnected = false,
    this.lastTime,
    this.message,
  });

  final ConnectionStatus connection;

  //MQTT 是否在线
  final bool mqttIsOnline;

  /// 当前控制设备(esp32)是否已被网关连接
  final bool hardwareConnected;

  final DateTime? lastTime;

  final String? message;

  bool get canControl => connection == ConnectionStatus.connected && mqttIsOnline && hardwareConnected;
}
