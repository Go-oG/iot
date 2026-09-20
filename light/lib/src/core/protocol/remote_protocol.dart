// 通道层面的取值：这里只描述连接与设备在线的汇总状态

enum ConnectionStatus {
  disconnected('未连接'),
  connecting('连接中'),
  connected('已连接');

  final String label;

  const ConnectionStatus(this.label);

  bool get isConnecting => this == connecting;

  bool get isConnected => this == connected;
}

/// 连接的汇总状态，供界面判断能否下发
///
/// 设备自己的属性状态属于设备模型会话，不在这里保存
class RemoteSnapshot {
  const RemoteSnapshot({
    this.connection = ConnectionStatus.disconnected,
    this.deviceOnline = false,
    this.lampConnected = false,
    this.lastSeen,
    this.message,
  });

  final ConnectionStatus connection;

  /// 网关是否在线
  final bool deviceOnline;

  /// 当前控制设备是否已被网关连接
  final bool lampConnected;
  final DateTime? lastSeen;
  final String? message;

  bool get canControl =>
      connection == ConnectionStatus.connected && deviceOnline && lampConnected;
}
