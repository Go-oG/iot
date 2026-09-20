import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/foundation.dart';

import 'package:light/src/data/backup_service.dart';
import 'package:light/src/data/database.dart';
import 'package:light/src/data/models.dart';

import '../core/device/device_model_catalog.dart';
import '../core/device/device_model_session.dart';
import '../core/device_model.dart';
import '../core/device_registry.dart';
import '../core/keep_alive.dart';
import '../core/protocol/client.dart';
import '../core/protocol/remote_protocol.dart';
import '../core/remote_gateway.dart';
import '../data/device_configuration.dart';
import '../data/device_key.dart';
import '../data/remote_settings.dart';

/// 应用状态：本机数据、网关通道与每台设备的模型会话
///
/// 控制器不保存任何灯光面板状态：配色与计划只保存属性值，开关与输出上限
/// 都经 [DeviceModelSession] 下发，界面显示一律以设备回报为准
class AppController extends ChangeNotifier {
  AppController(
    this._database, {
    BackupService? backupService,
    RemoteGateway? remoteGateway,
    RemoteSettingsStore? remoteStore,
  }) : _backupService = backupService ?? BackupService(),
       _remote = remoteGateway ?? RemoteGateway(),
       _remoteStore = remoteStore ?? MemoryRemoteSettingsStore() {
    _registry = DeviceRegistryService(gateway: _remote);
    _registrySubscription = _registry.changes.listen(_onRegistryChanged);
  }

  /// 支持输出上限的属性标识，没有该属性的设备按上限收敛数值属性
  static const String outputLimitProperty = 'outputLimit';

  final AppDatabase _database;
  final BackupService _backupService;
  final RemoteGateway _remote;
  final RemoteSettingsStore _remoteStore;
  late final DeviceRegistryService _registry;
  StreamSubscription<RemoteSnapshot>? _registrySubscription;
  bool _disposed = false;
  bool _remoteStarting = false;
  bool _changingContext = false;

  RemoteSettings? remoteSettings;
  String? userMessage;
  int messageVersion = 0;
  DateTime? _lastMessageAt;

  List<ScenePreset> scenes = const [];
  List<SchedulePlan> schedules = const [];
  List<SavedDevice> savedDevices = const [];
  List<DeviceConfiguration> deviceConfigurations = const [];
  final Map<DeviceKey, DeviceModelSession> _modelSessions = {};

  RemoteGateway get mqttGateway => _remote;

  /// 网关设备管理：登记、扫描与附近设备
  DeviceRegistryService get deviceRegistry => _registry;
  GatewayClientSnapshot get gatewayState => _remote.client.snapshot;
  String? get selectedDeviceId => _registry.selectedDeviceId;
  bool get remoteMatchesTarget => remoteSettings?.enabled == true;
  RemoteSnapshot get remote => _registry.snapshot;
  ControlRoute get controlRoute =>
      remote.canControl ? ControlRoute.mqtt : ControlRoute.offline;
  bool get isConnected => remote.canControl;
  String get connectionLabel => isConnected ? 'MQTT 网关控制' : '设备离线';
  String get activeDeviceName =>
      _savedName(selectedDeviceId ?? '') ??
      gatewayState.device(selectedDeviceId ?? '')?.name ??
      selectedDeviceId ??
      '请选择灯具';

  String get gatewayId => remoteSettings?.gatewayId ?? '';
  DeviceKey deviceKey(String id) => DeviceKey(gatewayId, id);

  /// 本地保存的设备模型，没有配置的设备按内置的 AT5 定义处理
  DeviceModel deviceModelFor(String id) =>
      deviceConfigurations
          .where((item) => item.id == id)
          .firstOrNull
          ?.model ??
      DeviceModelCatalog.instance.defaultModel;

  /// 当前控制设备的模型定义
  DeviceModel get selectedModel => deviceModelFor(selectedDeviceId ?? '');

  /// 由设备模型驱动的会话：界面用它下发命令、解析上报
  DeviceModelSession deviceSessionFor(String id) =>
      _modelSessions.putIfAbsent(deviceKey(id), () {
        return DeviceModelSession(
          model: deviceModelFor(id),
          client: _remote.client,
        );
      });

  void _removeModelSession(String id) {
    final session = _modelSessions[deviceKey(id)];
    if (session?.busy == true) throw StateError('设备正在执行命令，请完成后再修改配置');
    _modelSessions.remove(deviceKey(id))?.dispose();
  }

  bool get devicesBusy => _modelSessions.values.any((session) => session.busy);
  bool get changingDeviceContext => _changingContext || _remoteStarting;

  void _requireIdle() {
    if (changingDeviceContext || devicesBusy) {
      throw StateError('设备正在执行命令，请完成后再修改配置');
    }
  }

  Future<void> _disposeSessions() async {
    for (final session in _modelSessions.values) {
      session.dispose();
    }
    _modelSessions.clear();
  }

  /// 首页只展示真实回报，默认值与最近一次写入不代表开关的实际状态
  bool? reportedPowerFor(String id) {
    final session = _modelSessions[deviceKey(id)];
    final state = session?.reported['power'];
    if (session == null || state == null) return null;
    if (!session.isFresh(state) || state.value is! bool) return null;
    return state.value as bool;
  }

  /// 当前控制设备的属性现值，用于“用当前灯光更新配色”
  Map<String, Object?> get currentProperties {
    final id = selectedDeviceId;
    if (id == null) return const {};
    return currentPropertiesFor(id);
  }

  /// 当前设备可写属性的现值：新鲜上报优先，其次是刚下发的期望值
  Map<String, Object?> currentPropertiesFor(String id) {
    final session = deviceSessionFor(id);
    final values = <String, Object?>{};
    for (final entry in session.model.properties.entries) {
      if (!entry.value.canWrite) continue;
      final value = _currentValue(session, entry.key);
      if (value != null) values[entry.key] = value;
    }
    return values;
  }

  static Object? _currentValue(DeviceModelSession session, String property) {
    final state = session.reported[property];
    if (state != null && session.isFresh(state)) return state.value;
    return session.desired[property] ??
        session.model.properties[property]?.value.defaultValue;
  }

  /// 首页快捷开关：按设备模型写入 power 属性，回报由设备侧通知更新
  Future<void> togglePowerFor(String id) async {
    if (_disposed) return;
    final session = deviceSessionFor(id);
    if (!session.canWrite('power')) {
      _publishMessage('设备模型 ${session.model.id} 未定义可写的 power 属性');
      return;
    }
    try {
      final current = _currentValue(session, 'power');
      final record = await session.writeProperty('power', current != true);
      _publishMessage('开关已下发 · ${_confirmationLabel(record)}');
    } catch (error) {
      _publishMessage('执行结果未确认：$error');
    }
  }

  int get nextScheduleId => schedules.isEmpty
      ? 1
      : schedules.map((item) => item.id).reduce((a, b) => a > b ? a : b) + 1;

  String createSceneId() => 'scene_${DateTime.now().microsecondsSinceEpoch}';

  void showMessage(String message) => _publishMessage(message);

  void initialize() {
    _reloadData();
  }

  Future<void> startConnections() async {
    if (_remoteStarting || _disposed) return;
    _remoteStarting = true;
    try {
      remoteSettings = await _remoteStore.read();
      if (_disposed) return;
      notifyListeners();
      final settings = remoteSettings;
      if (settings != null) await _connectRemote(settings);
    } catch (_) {
      if (!_disposed) _publishMessage('远程配置读取失败，请在设备页重新配置');
    } finally {
      _remoteStarting = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> saveRemoteSettings(RemoteSettings settings) async {
    _requireIdle();
    settings.validate();
    _changingContext = true;
    try {
      await _remoteStore.write(settings);
      if (_disposed) return;
      await _connectRemote(settings);
    } finally {
      _changingContext = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// 启动和重新配置共用恢复流程，避免清空登记缓存后丢失控制对象
  Future<void> _connectRemote(RemoteSettings settings) async {
    await _disposeSessions();
    await _remote.disconnect();
    if (_disposed) return;
    remoteSettings = settings;
    _database.bindLegacyGateway(settings.gatewayId);
    _registry.reset();
    final selected = settings.bluetoothDeviceId;
    _registry.select(selected.isEmpty ? null : selected);
    _reloadData();
    if (_disposed) return;
    notifyListeners();
    if (settings.enabled) {
      await KeepAliveService.start(
        title: '设备控制已连接',
        text: '正在保持与网关的连接，避免息屏后断开',
      );
    } else {
      await KeepAliveService.stop();
    }
    if (_disposed) return;
    await _remote.connect(settings);
  }

  Future<void> clearRemoteSettings() async {
    _requireIdle();
    _changingContext = true;
    try {
      await _remoteStore.clear();
      if (_disposed) return;
      await _disposeSessions();
      await _remote.disconnect();
      remoteSettings = null;
      _registry.reset();
      _reloadData();
      await KeepAliveService.stop();
    } finally {
      _changingContext = false;
      if (!_disposed) notifyListeners();
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> reconnectRemote() async {
    final settings = remoteSettings;
    if (settings != null && settings.enabled) await _remote.connect(settings);
  }

  void setForeground(bool foreground) {
    if (foreground && !_disposed && _remote.client.connected) {
      unawaited(refreshDeviceState());
    }
  }

  Future<void> refreshDeviceState() async {
    try {
      await _remote.requestState();
    } catch (error) {
      _publishMessage('刷新失败：$error');
    }
    if (!_disposed) notifyListeners();
  }

  /// 输出上限不再是本机面板状态
  ///
  /// 设备模型声明了可写的输出上限属性时直接写属性，否则把当前数值属性
  /// 按上限收敛后写回设备，界面显示一律以设备回报为准
  Future<void> setOutputLimit(int value) async {
    final id = selectedDeviceId;
    if (id == null) {
      _publishMessage('请先选择要控制的设备');
      return;
    }
    final limit = value.clamp(1, 100);
    final session = deviceSessionFor(id);
    final writes = <ModelPropertyWrite>[];
    if (session.canWrite(outputLimitProperty)) {
      writes.add(ModelPropertyWrite(outputLimitProperty, limit));
    } else {
      for (final entry in session.model.properties.entries) {
        if (!session.canWrite(entry.key)) continue;
        final current = _currentValue(session, entry.key);
        if (current is! Map) continue;
        final clamped = _clampNumbers(current, limit);
        if (clamped != null) writes.add(ModelPropertyWrite(entry.key, clamped));
      }
    }
    if (writes.isEmpty) {
      _publishMessage('当前设备数值未超过输出上限，无需下发');
      return;
    }
    try {
      final record = await session.writeProperties(writes);
      _publishMessage('输出上限已下发 · ${_confirmationLabel(record)}');
    } catch (error) {
      _publishMessage('输出上限下发未确认：$error');
    }
  }

  /// 把对象属性里超过上限的数值字段收敛到上限，没有变化时返回 null
  static Map<String, Object?>? _clampNumbers(
    Map<Object?, Object?> value,
    int limit,
  ) {
    final result = <String, Object?>{};
    var changed = false;
    for (final entry in value.entries) {
      final item = entry.value;
      if (item is! num) {
        result['${entry.key}'] = item;
        continue;
      }
      final next = item.round().clamp(0, limit);
      if (next != item.round()) changed = true;
      result['${entry.key}'] = next;
    }
    return changed ? result : null;
  }

  /// 应用配色：把配色保存的属性值经设备模型写进当前设备
  Future<void> applyScene(ScenePreset scene) async {
    final id = selectedDeviceId;
    if (id == null) {
      _publishMessage('请先选择要控制的设备');
      return;
    }
    final session = deviceSessionFor(id);
    final writes = <ModelPropertyWrite>[
      for (final entry in scene.properties.entries)
        if (session.canWrite(entry.key))
          ModelPropertyWrite(entry.key, entry.value),
    ];
    if (writes.isEmpty) {
      _publishMessage('设备模型 ${session.model.id} 不支持该配色的属性');
      return;
    }
    try {
      final record = await session.writeProperties(writes);
      _publishMessage('配色已下发 · ${_confirmationLabel(record)}');
    } catch (error) {
      _publishMessage('配色下发未确认：$error');
    }
  }

  void saveScene(ScenePreset scene) {
    _database.saveScene(scene);
    scenes = _database.loadScenes();
    notifyListeners();
  }

  void deleteScene(ScenePreset scene) {
    _database.deleteScene(scene.id);
    scenes = _database.loadScenes();
    schedules = _database.loadSchedules();
    notifyListeners();
  }

  void saveSchedule(SchedulePlan plan) {
    _database.saveSchedule(plan);
    schedules = _database.loadSchedules();
    notifyListeners();
  }

  void deleteSchedule(SchedulePlan plan) {
    _database.deleteSchedule(plan.id);
    schedules = _database.loadSchedules();
    notifyListeners();
  }

  void saveDeviceConfiguration(
    DeviceConfiguration configuration, {
    String? previousId,
  }) {
    _requireIdle();
    _database.saveDeviceConfiguration(
      configuration.withGateway(gatewayId),
      previousId: previousId,
    );
    for (final id in {configuration.id, ?previousId}) {
      _removeModelSession(id);
    }
    deviceConfigurations = _database.loadDeviceConfigurations(
      gatewayId: gatewayId,
    );
    notifyListeners();
  }

  void deleteDeviceConfiguration(String id) {
    _requireIdle();
    _database.deleteDeviceConfiguration(id, gatewayId: gatewayId);
    _removeModelSession(id);
    deviceConfigurations = _database.loadDeviceConfigurations(
      gatewayId: gatewayId,
    );
    notifyListeners();
  }

  Future<void> exportData({Rect? sharePositionOrigin}) async {
    try {
      final data = const JsonEncoder.withIndent(
        '  ',
      ).convert(_database.exportData().toJson());
      final now = DateTime.now();
      final fileName =
          'light_backup_${now.year}${_two(now.month)}${_two(now.day)}_${_two(now.hour)}${_two(now.minute)}.json';
      final result = await _backupService.exportJson(
        data,
        fileName: fileName,
        sharePositionOrigin: sharePositionOrigin,
      );
      _publishMessage(result);
    } catch (error) {
      _publishMessage('导出失败：$error');
    }
  }

  Future<void> exportScene(
    ScenePreset scene, {
    Rect? sharePositionOrigin,
  }) async {
    try {
      final data = const JsonEncoder.withIndent('  ').convert({
        'schemaVersion': 2,
        'kind': 'scene',
        'exportedAt': DateTime.now().toIso8601String(),
        'scene': scene.toJson(),
      });
      final result = await _backupService.exportJson(
        data,
        fileName: 'light_scene_${scene.id}.json',
        sharePositionOrigin: sharePositionOrigin,
      );
      _publishMessage(result);
    } catch (error) {
      _publishMessage('配色导出失败：$error');
    }
  }

  Future<void> importData() async {
    try {
      final source = await _backupService.pickJson();
      if (source == null) {
        return;
      }
      final decoded = jsonDecode(source);
      if (decoded is! Map) {
        throw const FormatException('文件内容不是有效的 JSON 对象');
      }
      final json = decoded.map((key, value) => MapEntry(key.toString(), value));
      if (json['kind'] == 'scene') {
        final rawScene = json['scene'];
        if (rawScene is! Map) {
          throw const FormatException('配色数据不存在');
        }
        var scene = ScenePreset.fromJson(
          rawScene.map((key, value) => MapEntry(key.toString(), value)),
        );
        if (scene.id.isEmpty || scene.name.trim().isEmpty) {
          throw const FormatException('配色标识或名称为空');
        }
        if (scenes.any((item) => item.id == scene.id)) {
          scene = ScenePreset(
            id: createSceneId(),
            name: '${scene.name}（导入）',
            subtitle: scene.subtitle,
            accentValue: scene.accentValue,
            properties: scene.properties,
          );
        }
        _database.saveScene(scene);
        scenes = _database.loadScenes();
      } else {
        await replaceData(AppDataBundle.fromJson(json));
      }
      _publishMessage('导入完成');
    } catch (error) {
      _publishMessage('导入失败：$error');
    }
  }

  Future<void> resetAllData() async {
    _requireIdle();
    _changingContext = true;
    try {
      _database.resetData();
      await _disposeSessions();
      _reloadData();
      _publishMessage('本地数据已恢复为默认状态');
    } finally {
      _changingContext = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> replaceData(AppDataBundle data) async {
    _requireIdle();
    _changingContext = true;
    try {
      _database.replaceData(data, legacyGatewayId: gatewayId);
      await _disposeSessions();
      _reloadData();
    } finally {
      _changingContext = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> startScan() => _registry.startScan();
  Future<void> stopScan() => _registry.stopScan();

  Future<void> connect(String deviceId) async {
    _requireIdle();
    await _registry.connectDevice(deviceId);
  }

  Future<void> selectDevice(String deviceId, String name) async {
    _requireIdle();
    _changingContext = true;
    try {
      final settings = remoteSettings;
      if (settings == null) throw StateError('请先配置 MQTT');
      final updated = settings.withDevice(deviceId);
      await _remoteStore.write(updated);
      remoteSettings = updated;
      _database.saveDevice(
        SavedDevice(
          id: deviceId,
          gatewayId: gatewayId,
          name: name,
          room: '网关设备',
          lastConnectedAt: DateTime.now(),
        ),
      );
      savedDevices = _database.loadDevices(gatewayId: gatewayId);
      _registry.select(deviceId);
      // 选中设备即绑定它自己的设备模型会话，命令与回报都从这里走
      deviceSessionFor(deviceId);
      notifyListeners();
    } finally {
      _changingContext = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> disconnect() async {
    final id = selectedDeviceId;
    if (id != null) await _registry.disconnectDevice(id);
  }

  Future<void> clearSelectedDevice() async {
    _requireIdle();
    final settings = remoteSettings;
    if (settings != null) {
      final updated = settings.withDevice('');
      await _remoteStore.write(updated);
      remoteSettings = updated;
    }
    _registry.select(null);
    _reloadData();
    if (!_disposed) notifyListeners();
  }

  /// 开关计划：先保存本机计划，再把定时槽位属性值下发给当前设备
  Future<void> toggleSchedule(SchedulePlan plan) async {
    final updated = plan.copyWith(enabled: !plan.enabled);
    _database.saveSchedule(updated);
    schedules = _database.loadSchedules();
    notifyListeners();

    final id = selectedDeviceId;
    if (id == null || !isConnected) {
      _publishMessage('计划已保存在本机，连接设备后再下发');
      return;
    }
    final session = deviceSessionFor(id);
    final writes = <ModelPropertyWrite>[
      if (session.canWrite('time')) _timeWrite(),
      for (final entry in updated.properties.entries)
        if (session.canWrite(entry.key))
          ModelPropertyWrite(entry.key, entry.value),
    ];
    final unsupported = updated.properties.keys.where(
      (property) => !session.canWrite(property),
    );
    if (unsupported.isNotEmpty) {
      _publishMessage(
        '设备模型 ${session.model.id} 不支持属性 ${unsupported.join('、')}，计划只保存在本机',
      );
      return;
    }
    try {
      await session.writeProperties(writes);
      _publishMessage('设备定时槽位已更新');
    } catch (error) {
      _publishMessage('计划下发未确认：$error');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_disposeSessions());
    _registrySubscription?.cancel();
    _registry.dispose();
    _remote.dispose();
    _database.close();
    super.dispose();
  }

  void _onRegistryChanged(RemoteSnapshot snapshot) {
    if (_disposed) return;
    // 远端状态变化只驱动界面刷新，设备属性由各设备的会话自己维护
    notifyListeners();
  }

  void _reloadData() {
    deviceConfigurations = _database.loadDeviceConfigurations(
      gatewayId: gatewayId,
    );
    scenes = _database.loadScenes();
    schedules = _database.loadSchedules();
    savedDevices = _database.loadDevices(gatewayId: gatewayId);
    notifyListeners();
  }

  String? _savedName(String id) =>
      savedDevices.where((item) => item.id == id).firstOrNull?.name;

  /// 下发定时前先对时，设备按本机时间判断时段
  static ModelPropertyWrite _timeWrite() {
    final now = DateTime.now();
    return ModelPropertyWrite('time', {
      'hour': now.hour,
      'minute': now.minute,
      'second': now.second,
    });
  }

  static String _confirmationLabel(ModelCommandRecord record) =>
      switch (record.state) {
        ModelCommandState.deviceState => '设备已回报状态',
        ModelCommandState.deviceAck => '设备已确认',
        ModelCommandState.read => '已读取',
        ModelCommandState.failed => '执行失败',
        ModelCommandState.unknown => '结果未确认',
        _ => '网关已写入，尚无状态回读',
      };

  void _publishMessage(String message) {
    if (_disposed) return;
    final now = DateTime.now();
    // 合并短时间内由网关事件和异常处理重复上报的同一条提示
    if (message == userMessage &&
        _lastMessageAt != null &&
        now.difference(_lastMessageAt!) < const Duration(seconds: 3)) {
      notifyListeners();
      return;
    }
    userMessage = message;
    _lastMessageAt = now;
    messageVersion++;
    notifyListeners();
  }

  static String _two(int value) => value.toString().padLeft(2, '0');
}

enum ControlRoute { offline, mqtt }
