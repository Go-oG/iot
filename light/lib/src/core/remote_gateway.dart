import 'dart:async';

import '../data/remote_settings.dart';
import 'protocol/client.dart';
import 'protocol/protocol.dart';

/// 远端 MQTT 通道：只负责连接、收发与事件转发
///
/// 这里不认识任何具体设备协议，也不持有任何设备状态：
/// 报文由设备客户端自己生成与解析，扫描与登记由 [DeviceRegistryService] 管理。
class RemoteGateway {
  RemoteGateway({GatewayClient? client}) : client = client ?? GatewayClient() {
    _events = this.client.events.listen(_forward);
  }

  final GatewayClient client;
  final _forwarded = StreamController<GatewayEvent>.broadcast();
  late final StreamSubscription<GatewayEvent> _events;
  bool _disposed = false;

  /// 网关上行事件流，设备会话与设备管理服务按 deviceId 认领
  Stream<GatewayEvent> get events => _forwarded.stream;

  Future<void> connect(RemoteSettings settings) => client.connect(settings);

  Future<void> disconnect() => client.disconnect();

  /// 请求-响应式收发，失败响应直接抛出
  Future<GatewayMessage> checked(
    GatewayOption op, {
    String? deviceId,
    String? service,
    String? characteristic,
    String? value,
    ValueFormat? format,
    Map<String, Object?>? data,
    Duration? timeout,
  }) async {
    if (!client.connected) throw StateError('请先连接 MQTT 服务器');
    final response = await client.request(
      op,
      deviceId: deviceId,
      service: service,
      characteristic: characteristic,
      value: value,
      format: format,
      data: data,
      timeout: timeout,
    );
    if (response.error != null) throw response.error!;
    return response;
  }

  /// 拉取一次网关快照
  Future<void> requestState() => client.refreshSnapshot();

  void _forward(GatewayEvent event) {
    if (!_forwarded.isClosed) _forwarded.add(event);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _events.cancel();
    await client.dispose();
    await _forwarded.close();
  }
}
