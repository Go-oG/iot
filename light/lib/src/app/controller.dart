import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:light/src/core/device/models.dart';
import 'package:light/src/core/protocol/model.dart';

import 'package:light/src/data/backup_service.dart';
import 'package:light/src/data/database.dart';
import 'package:light/src/data/models.dart';

import '../core/device/device.dart';
import '../core/device/devie_match.dart';
import '../core/device_registry.dart';
import '../core/protocol/protocol.dart';
import '../core/protocol/remote_status.dart';
import '../core/mqtt/mqtt_gateway.dart';
import '../data/device_key.dart';
import '../data/device_template.dart';
import '../core/mqtt/mqtt_config.dart';

/// 应用状态：本机数据、网关通道与每台设备
///
/// 控制器不保存任何灯光面板状态：配色与计划只保存属性值，开关与输出上限
/// 都经 [Device] 下发，界面显示一律以设备回报为准
class AppController extends ChangeNotifier {
  /// 支持输出上限的属性标识，没有该属性的设备按上限收敛数值属性
  static const String outputLimitProperty = 'outputLimit';

  AppController(this._database) {
    _registrySubscription = _registryService.changes.listen(_onRegistryChanged);
  }

  final AppDatabase _database;
  final MqttConfigStore _mqttConfigStore = SecureMqttConfigStore();
  final _backupService = BackupService();
  final _mqttGateway = MqttGateway();
  late final _registryService = DeviceRegistryService(gateway: _mqttGateway);
  late StreamSubscription<RemoteStatus>? _registrySubscription;

  final Map<DeviceKey, Device> _devices = {};

  bool _disposed = false;

  bool _remoteStarting = false;

  bool _changingContext = false;

  MqttConfig? remoteSettings;

  String? userMessage;

  int messageVersion = 0;

  DateTime? _lastMessageAt;

  List<ScenePreset> scenes = const [];

  List<SchedulePlan> schedules = const [];

  List<SavedDevice> savedDevices = const [];

  List<DeviceTemplate> deviceTemplates = const [];

  MqttGateway get mqttGateway => _mqttGateway;

  DeviceRegistryService get deviceRegistry => _registryService;

  GatewayClientSnapshot get gatewayState => _mqttGateway.client.snapshot;

  String? get selectedDeviceId => _registryService.selectedDeviceId;
  bool get remoteMatchesTarget => remoteSettings?.enabled == true;

  RemoteStatus get remote => _registryService.snapshot;
  ControlRoute get controlRoute =>
      remote.canControl ? ControlRoute.mqtt : ControlRoute.offline;

  bool get isConnected => remote.canControl;

  String get connectionLabel => isConnected ? 'MQTT 网关控制' : '设备离线';

  String get activeDeviceName =>
      _savedName(selectedDeviceId ?? '') ??
      gatewayState.device(selectedDeviceId ?? '')?.name ??
      selectedDeviceId ??
      '请选择设备';

  String get gatewayId => remoteSettings?.gatewayId ?? '';
  DeviceKey deviceKey(String id) => DeviceKey(gatewayId, id);

  /// 当前网关可用的协议模板，自定义模板优先覆盖同标识的内置模板
  List<DeviceTemplate> get availableDeviceTemplates {
    final customIds = deviceTemplates.map((item) => item.id).toSet();
    return [
      ...deviceTemplates,
      for (final device in Device.definitions.values)
        if (!customIds.contains(device.modelId))
          DeviceTemplate.fromDevice(
            device,
            gatewayId: gatewayId,
            builtIn: true,
          ),
    ];
  }

  DeviceTemplate? templateFor(String modelId) {
    for (final template in deviceTemplates) {
      if (template.id == modelId) return template;
    }
    final definition = Device.definitionFor(modelId);
    if (definition == null) return null;
    return DeviceTemplate.fromDevice(
      definition,
      gatewayId: gatewayId,
      builtIn: true,
    );
  }

  /// 真实设备绑定的协议模板；未手工绑定时按模板匹配规则或内置 AT5 解析
  DeviceTemplate? templateForDevice(String deviceId) {
    final modelId = resolvedModelIdFor(deviceId);
    return modelId == null ? null : templateFor(modelId);
  }

  String? resolvedModelIdFor(String deviceId) {
    final saved = savedDevices.where((item) => item.id == deviceId).firstOrNull;
    final boundModelId = saved?.modelId;
    if (boundModelId != null && templateFor(boundModelId) != null) {
      return boundModelId;
    }
    final matched = _matchModelId(deviceId);
    if (matched != null) return matched;
    if (templateFor(Device.defaultId) != null) return Device.defaultId;
    return null;
  }

  /// 按 service UUID 等扫描信息自动匹配协议模板
  String? _matchModelId(String deviceId) {
    final state = gatewayState.device(deviceId);
    final serviceUuids = <String>{
      for (final key in state?.characteristics.keys ?? const <String>{})
        if (key.contains('/')) key.split('/').first,
    };
    for (final template in availableDeviceTemplates) {
      for (final rule in template.definition.match) {
        if (rule.type != DeviceMatchType.serviceUuid) continue;
        for (final serviceUuid in serviceUuids) {
          try {
            if (GatewayUuid.normalize(rule.value) ==
                GatewayUuid.normalize(serviceUuid)) {
              return template.id;
            }
          } on FormatException {
            // 无效模板规则不参与自动匹配，后续仍可由用户手工绑定
          }
        }
      }
    }
    return null;
  }

  Device? deviceOf(String deviceId) {
    final template = templateForDevice(deviceId);
    if (template == null) return null;
    return Device.fromJson(template.toJson(), deviceId: deviceId);
  }

  /// 当前设备
  Device? get selectedDevice => deviceOf(selectedDeviceId ?? '');

  /// 绑定网关客户端后的在线设备对象
  Device? deviceFor(String deviceId) {
    final key = deviceKey(deviceId);
    final session = _devices[key];
    if (session != null) {
      return session;
    }
    final template = templateForDevice(deviceId);
    if (template == null) {
      return null;
    }
    final device = Device.fromJson(
      template.toJson(),
      deviceId: deviceId,
      client: _mqttGateway.client,
    );
    _devices[key] = device;
    return device;
  }

  void _removeDevice(String id) {
    final session = _devices[deviceKey(id)];
    if (session?.busy == true) throw StateError('设备正在执行命令，请完成后再修改配置');
    _devices.remove(deviceKey(id))?.dispose();
  }

  void _removeAllDevices() {
    for (final key in _devices.keys.toList()) {
      _removeDevice(key.deviceId);
    }
  }

  bool get devicesBusy => _devices.values.any((session) => session.busy);
  bool get changingDeviceContext => _changingContext || _remoteStarting;

  void _requireIdle() {
    if (changingDeviceContext || devicesBusy) {
      throw StateError('设备正在执行命令，请完成后再修改配置');
    }
  }

  Future<void> _disposeDevices() async {
    for (final session in _devices.values) {
      session.dispose();
    }
    _devices.clear();
  }

  /// 首页只展示真实回报，默认值与最近一次写入不代表开关的实际状态
  bool? reportedPowerFor(String id) {
    final session = _devices[deviceKey(id)];
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

  /// 当前设备可写属性的现值：新上报优先，其次是刚下发的期望值
  Map<String, Object?> currentPropertiesFor(String id) {
    final session = deviceFor(id);
    if (session == null) {
      return {};
    }
    final values = <String, Object?>{};
    for (final entry in session.properties.entries) {
      if (!entry.value.canWrite) continue;
      final value = _currentValue(session, entry.key);
      if (value != null) values[entry.key] = value;
    }
    return values;
  }

  static Object? _currentValue(Device session, String property) {
    final state = session.reported[property];
    if (state != null && session.isFresh(state)) return state.value;
    return session.desired[property] ??
        session.properties[property]?.value.defaultValue;
  }

  /// 首页快捷开关：按设备模型写入 power 属性，回报由设备侧通知更新
  Future<void> togglePowerFor(String id) async {
    if (_disposed) return;
    final session = deviceFor(id);
    if (session == null) {
      return;
    }
    if (!session.canWrite('power')) {
      _publishMessage('设备模型 ${session.modelId} 未定义可写的 power 属性');
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
      remoteSettings = await _mqttConfigStore.read();
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

  Future<void> saveRemoteSettings(MqttConfig settings) async {
    _requireIdle();
    settings.validate();
    _changingContext = true;
    try {
      await _mqttConfigStore.write(settings);
      if (_disposed) return;
      await _connectRemote(settings);
    } finally {
      _changingContext = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// 启动和重新配置共用恢复流程，避免清空登记缓存后丢失控制对象
  Future<void> _connectRemote(MqttConfig settings) async {
    await _disposeDevices();
    await _mqttGateway.disconnect();
    if (_disposed) return;
    remoteSettings = settings;
    _database.bindLegacyGateway(settings.gatewayId);
    _registryService.reset();
    final selected = settings.bluetoothDeviceId;
    _registryService.select(selected.isEmpty ? null : selected);
    _reloadData();
    if (_disposed) return;
    notifyListeners();
    if (_disposed) return;
    await _mqttGateway.connect(settings);
  }

  Future<void> clearRemoteSettings() async {
    _requireIdle();
    _changingContext = true;
    try {
      await _mqttConfigStore.clear();
      if (_disposed) return;
      await _disposeDevices();
      await _mqttGateway.disconnect();
      remoteSettings = null;
      _registryService.reset();
      _reloadData();
    } finally {
      _changingContext = false;
      if (!_disposed) notifyListeners();
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> reconnectRemote() async {
    final settings = remoteSettings;
    if (settings != null && settings.enabled) {
      await _mqttGateway.connect(settings);
    }
  }

  void setForeground(bool foreground) {
    if (foreground && !_disposed && _mqttGateway.client.connected) {
      unawaited(refreshDeviceState());
    }
  }

  Future<void> refreshDeviceState() async {
    try {
      await _mqttGateway.requestState();
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
    final session = deviceFor(id);
    if (session == null) {
      return;
    }
    final limit = value.clamp(1, 100);
    final writes = <DevicePropertyWrite>[];
    if (session.canWrite(outputLimitProperty)) {
      writes.add(DevicePropertyWrite(outputLimitProperty, limit));
    } else {
      for (final entry in session.properties.entries) {
        if (!session.canWrite(entry.key)) continue;
        final current = _currentValue(session, entry.key);
        if (current is! Map) continue;
        final clamped = _clampNumbers(current, limit);
        if (clamped != null) {
          writes.add(DevicePropertyWrite(entry.key, clamped));
        }
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
    final session = deviceFor(id);
    if (session == null) {
      return;
    }

    final writes = <DevicePropertyWrite>[
      for (final entry in scene.properties.entries)
        if (session.canWrite(entry.key))
          DevicePropertyWrite(entry.key, entry.value),
    ];
    if (writes.isEmpty) {
      _publishMessage('设备模型 ${session.modelId} 不支持该配色的属性');
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

  void saveDeviceTemplate(DeviceTemplate template, {String? previousId}) {
    _requireIdle();
    _database.saveDeviceTemplate(
      template.withGateway(gatewayId),
      previousId: previousId,
    );
    if (previousId != null && previousId != template.id) {
      for (final device
          in savedDevices
              .where((item) => item.modelId == previousId)
              .toList()) {
        _database.saveDevice(device.copyWith(modelId: template.id));
      }
      savedDevices = _database.loadDevices(gatewayId: gatewayId);
    }
    _removeAllDevices();
    deviceTemplates = _database.loadDeviceTemplates(gatewayId: gatewayId);
    notifyListeners();
  }

  void deleteDeviceTemplate(String modelId) {
    _requireIdle();
    final custom = deviceTemplates
        .where((item) => item.id == modelId)
        .firstOrNull;
    if (custom == null) {
      throw StateError('内置协议模板不能删除');
    }
    final bound = savedDevices.where((item) => item.modelId == modelId).length;
    if (bound > 0 && Device.definitionFor(modelId) == null) {
      throw StateError('仍有 $bound 台设备使用该模板，请先重新绑定');
    }
    _database.deleteDeviceTemplate(modelId, gatewayId: gatewayId);
    _removeAllDevices();
    deviceTemplates = _database.loadDeviceTemplates(gatewayId: gatewayId);
    notifyListeners();
  }

  /// 把一台真实设备绑定到指定协议模板
  Future<void> bindDeviceModel(
    String deviceId,
    String modelId, {
    String? name,
  }) async {
    _requireIdle();
    if (templateFor(modelId) == null) {
      throw StateError('协议模板不存在：$modelId');
    }
    final existing = savedDevices
        .where((item) => item.id == deviceId)
        .firstOrNull;
    final registration = deviceRegistry.registered[deviceId];
    final nextName = name?.trim().isNotEmpty == true
        ? name!.trim()
        : existing?.name.trim().isNotEmpty == true
        ? existing!.name
        : '${registration?[GatewayField.alias.wire] ?? deviceId}';
    _database.saveDevice(
      SavedDevice(
        id: deviceId,
        gatewayId: gatewayId,
        name: nextName,
        room: existing?.room ?? '网关设备',
        modelId: modelId,
        lastConnectedAt: DateTime.now(),
      ),
    );
    savedDevices = _database.loadDevices(gatewayId: gatewayId);
    _removeDevice(deviceId);
    if (selectedDeviceId == deviceId) deviceFor(deviceId);
    notifyListeners();
  }

  Future<void> exportData({Rect? sharePositionOrigin}) async {
    try {
      final data = const JsonEncoder.withIndent('  ')
          .convert(_database.exportData().toJson());
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
      await _disposeDevices();
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
      await _disposeDevices();
      _reloadData();
    } finally {
      _changingContext = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> startScan() => _registryService.startScan();

  Future<void> stopScan() => _registryService.stopScan();

  Future<void> connect(String deviceId) async {
    _requireIdle();
    await _registryService.connectDevice(deviceId);
  }

  Future<void> selectDevice(String deviceId, String name) async {
    _requireIdle();
    _changingContext = true;
    try {
      final settings = remoteSettings;
      if (settings == null) throw StateError('请先配置 MQTT');
      final updated = settings.withDevice(deviceId);
      await _mqttConfigStore.write(updated);
      remoteSettings = updated;
      final modelId = resolvedModelIdFor(deviceId);
      _database.saveDevice(
        SavedDevice(
          id: deviceId,
          gatewayId: gatewayId,
          name: name,
          room: '网关设备',
          modelId: modelId,
          lastConnectedAt: DateTime.now(),
        ),
      );
      savedDevices = _database.loadDevices(gatewayId: gatewayId);
      _registryService.select(deviceId);
      // 选中设备即绑定它自己的设备模型会话，命令与回报都从这里走
      deviceFor(deviceId);
      notifyListeners();
    } finally {
      _changingContext = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> disconnect() async {
    final id = selectedDeviceId;
    if (id != null) await _registryService.disconnectDevice(id);
  }

  Future<void> clearSelectedDevice() async {
    _requireIdle();
    final settings = remoteSettings;
    if (settings != null) {
      final updated = settings.withDevice('');
      await _mqttConfigStore.write(updated);
      remoteSettings = updated;
    }
    _registryService.select(null);
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
    final session = deviceFor(id);
    if (session == null) {
      return;
    }

    final writes = <DevicePropertyWrite>[
      if (session.canWrite('time')) _timeWrite(),
      for (final entry in updated.properties.entries)
        if (session.canWrite(entry.key))
          DevicePropertyWrite(entry.key, entry.value),
    ];
    final unsupported = updated.properties.keys.where(
      (property) => !session.canWrite(property),
    );
    if (unsupported.isNotEmpty) {
      _publishMessage(
        '设备模型 ${session.modelId} 不支持属性 ${unsupported.join('、')}，计划只保存在本机',
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
    unawaited(_disposeDevices());
    _registrySubscription?.cancel();
    _registryService.dispose();
    _mqttGateway.dispose();
    _database.close();
    super.dispose();
  }

  void _onRegistryChanged(RemoteStatus snapshot) {
    if (_disposed) return;
    // 远端状态变化只驱动界面刷新，设备属性由各设备的会话自己维护
    notifyListeners();
  }

  void _reloadData() {
    deviceTemplates = _database.loadDeviceTemplates(gatewayId: gatewayId);
    scenes = _database.loadScenes();
    schedules = _database.loadSchedules();
    savedDevices = _database.loadDevices(gatewayId: gatewayId);
    notifyListeners();
  }

  String? _savedName(String id) =>
      savedDevices.where((item) => item.id == id).firstOrNull?.name;

  /// 下发定时前先对时，设备按本机时间判断时段
  static DevicePropertyWrite _timeWrite() {
    final now = DateTime.now();
    return DevicePropertyWrite('time', {
      'hour': now.hour,
      'minute': now.minute,
      'second': now.second,
    });
  }

  static String _confirmationLabel(DeviceCommandRecord record) =>
      switch (record.state) {
        DeviceCommandState.deviceState => '设备已回报状态',
        DeviceCommandState.deviceAck => '设备已确认',
        DeviceCommandState.read => '已读取',
        DeviceCommandState.failed => '执行失败',
        DeviceCommandState.unknown => '结果未确认',
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
