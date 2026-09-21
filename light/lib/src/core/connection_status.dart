import 'package:light/src/core/wire_enum.dart';

enum ConnectionStatus implements WireEnum {
  disconnected('disconnected', '未连接'),
  connecting('connecting', '连接中'),
  connected('connected', '已连接'),
  disconnecting('disconnecting', '断开中');

  @override
  final String wire;

  final String label;

  const ConnectionStatus(this.wire, this.label);

  bool get isConnecting => this == connecting;

  bool get isConnected => this == connected;

  static ConnectionStatus? valueOf(Object? raw) => wireValueOf(values, raw);
}
