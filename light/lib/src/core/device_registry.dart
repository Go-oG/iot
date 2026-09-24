import 'dart:async';

import 'package:light/src/core/protocol/model.dart';
import 'protocol/protocol.dart';
import 'protocol/remote_status.dart';
import 'mqtt/mqtt_gateway.dart';

/// 网关设备管理：登记列表、扫描与附近设备、当前控制设备
///
/// 只通过 [MqttGateway] 收发，不参与任何设备协议的编解码；
/// 扫描结果与登记信息都缓存在这里，供界面和会话查询。
class DeviceRegistryService {

  DeviceRegistryService({required this._gateway}) {
    _events = _gateway.events.listen(_onEvent);
    _subscription = _gateway.client.changes.listen((_) => _publish());
  }

  final MqttGateway _gateway;
  late final StreamSubscription<GatewayEvent> _events;
  late final StreamSubscription<GatewayClientSnapshot> _subscription;
  final _changes = StreamController<RemoteStatus>.broadcast();

  /// 网关上登记的设备，键为设备标识
  final Map<String, Map<String, Object?>> registered = {};

  /// 最近一次扫描发现、但可能还未登记的设备，键为设备标识
  final Map<String, Map<String, Object?>> nearby = {};

  /// 登记设备的运行时状态，键为设备标识
  final Map<String, Map<String, Object?>> runtime = {};

  Map<String, Object?>? diagnostics;
  bool scanning = false;

  /// 当前控制设备
  String? selectedDeviceId;

  String? _scanId;
  int _scanGeneration = 0;
  Timer? _scanTimer;
  bool _disposed = false;

  ///远端状态快照
  RemoteStatus _statusSnapshot = const RemoteStatus();

  /// 连接与灯具状态的汇总，供界面判断能否下发
  RemoteStatus get snapshot => _statusSnapshot;

  Stream<RemoteStatus> get changes => _changes.stream;

  bool get connected =>
      _gateway.client.connected && _gateway.client.snapshot.gatewayOnline;

  /// 登记设备列表，供界面直接遍历
  List<Map<String, Object?>> get devices => registered.values.toList();

  /// 登记设备的运行时状态，供界面直接遍历
  List<Map<String, Object?>> get states => runtime.entries
      .map((entry) => {'device': entry.key, ...entry.value})
      .toList();

  /// 运行时状态里的暂停、协议接管等标记
  Map<String, Object?>? stateOf(String deviceId) => runtime[deviceId];

  /// 切换当前控制设备
  void select(String? deviceId) {
    selectedDeviceId = deviceId;
    _publish();
  }

  /// 建立远端连接时先清空上一次会话的缓存
  void reset() {
    registered.clear();
    nearby.clear();
    runtime.clear();
    diagnostics = null;
    _invalidateScan();
    selectedDeviceId = null;
    _publish();
  }

  /// 网关管理动作，结果按动作缓存，供界面读取
  Future<Map<String, Object?>> execute(
    GatewayManageAction action, [
    Map<GatewayField, Object?> parameters = const {},
  ]) async {
    final response = await _gateway.checked(
      GatewayOption.manage,
      data: {
        GatewayField.action.wire: action.wire,
        for (final entry in parameters.entries) entry.key.wire: entry.value,
      },
    );
    final data = response.data ?? const <String, Object?>{};
    switch (action) {
      case GatewayManageAction.status:
        _applyStatus(data);
      case GatewayManageAction.diagnostics:
        diagnostics = data;
      default:
        break;
    }
    _publish();
    return data;
  }

  void _applyStatus(Map<String, Object?> data) {
    registered.clear();
    for (final entry in data[GatewayField.devices.wire] as List? ?? []) {
      if (entry is! Map) continue;
      final id =
          (entry[GatewayField.deviceId.wire] ?? entry[GatewayField.device.wire])
              as String?;
      if (id == null || id.isEmpty) continue;
      registered[id] = Map<String, Object?>.from(entry);
    }
    runtime.clear();
    for (final entry in data[GatewayField.states.wire] as List? ?? []) {
      if (entry is! Map) continue;
      final id =
          (entry[GatewayField.device.wire] ?? entry[GatewayField.deviceId.wire])
              as String?;
      if (id == null || id.isEmpty) continue;
      runtime[id] = Map<String, Object?>.from(entry);
    }
  }

  /// 连接设备
  ///
  /// MAC 与地址类型优先使用扫描结果，其次使用登记值，
  /// 保证未重新扫描时也能连接已登记设备。
  Future<void> connectDevice(String id) async {
    if (scanning) await stopScan();
    final found = nearby[id] ?? registered[id];
    final mac = found?[GatewayField.mac.wire];
    final addrType = found?[GatewayField.addrType.wire];
    await _gateway.checked(
      GatewayOption.connect,
      deviceId: id,
      timeout: const Duration(seconds: 15),
      data: {
        GatewayField.policy.wire: GatewayConnectPolicy.queue.wire,
        GatewayField.mac.wire: ?mac,
        GatewayField.addrType.wire: ?addrType,
      },
    );
    await _gateway.requestState();
  }

  Future<void> disconnectDevice(String id) async {
    await _gateway.checked(GatewayOption.disconnect, deviceId: id);
    await _gateway.requestState();
  }

  Future<void> startScan({
    Duration duration = const Duration(seconds: 5),
  }) async {
    if (scanning) return;
    final generation = ++_scanGeneration;
    nearby.clear();
    scanning = true;
    _scanId = null;
    _publish();
    try {
      final response = await _gateway.checked(
        GatewayOption.scan,
        data: {
          GatewayField.action.wire: GatewayScanAction.start.wire,
          GatewayField.duration.wire: duration.inMilliseconds,
          GatewayField.active.wire: true,
        },
      );
      if (_disposed || generation != _scanGeneration) return;
      final scanId = response.data?[GatewayField.scanId.wire];
      if (scanId is! String || scanId.isEmpty) {
        throw const FormatException('扫描响应缺少 scanId');
      }
      _scanId = scanId;
      // 网关只在扫描结束后停止上报，这里按约定时长自行收尾
      _scanTimer?.cancel();
      _scanTimer = Timer(duration + const Duration(milliseconds: 500), () {
        if (_disposed || generation != _scanGeneration) return;
        _invalidateScan();
        _publish();
      });
    } catch (_) {
      if (!_disposed && generation == _scanGeneration) {
        _invalidateScan();
        _publish();
      }
      rethrow;
    }
  }

  Future<void> stopScan() async {
    final generation = ++_scanGeneration;
    _scanTimer?.cancel();
    _scanId = null;
    try {
      await _gateway.checked(
        GatewayOption.scan,
        data: {GatewayField.action.wire: GatewayScanAction.stop.wire},
      );
    } finally {
      if (!_disposed && generation == _scanGeneration) {
        _invalidateScan();
        _publish();
      }
    }
  }

  void _onEvent(GatewayEvent event) {
    if (event.op == GatewayOption.hello) {
      _invalidateScan();
      _publish();
      return;
    }
    if (event.op != GatewayOption.scan || !scanning || event.retained) return;
    if (_scanId == null || event.data?[GatewayField.scanId.wire] != _scanId) {
      return;
    }
    final devices = event.data?[GatewayField.devices.wire];
    if (devices is List) {
      for (final raw in devices.whereType<Map>()) {
        final id = raw[GatewayField.deviceId.wire];
        if (id is String) nearby[id] = Map<String, Object?>.from(raw);
      }
      _publish();
    }
  }

  void _invalidateScan() {
    _scanGeneration++;
    _scanTimer?.cancel();
    _scanTimer = null;
    scanning = false;
    _scanId = null;
  }

  void _publish() {
    if (_disposed) return;
    if (!connected && scanning) _invalidateScan();
    final state = _gateway.client.snapshot;
    _statusSnapshot = RemoteStatus(
      connection: state.connection,
      mqttIsOnline: state.gatewayOnline,
      hardwareConnected: state.connected && state.gatewayOnline &&
          (state.deviceOf(selectedDeviceId ?? '')?.connected ?? false),
      lastTime: state.lastSeen,
      message: state.message,
    );
    if (!_changes.isClosed) _changes.add(_statusSnapshot);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _invalidateScan();
    await _events.cancel();
    await _subscription.cancel();
    await _changes.close();
  }
}
