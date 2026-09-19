import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:light/src/core/device/device.dart';
import 'package:light/src/core/device/function_type.dart';
import 'package:light/src/core/device/generic_session.dart';
import 'package:light/src/core/functions/fan_speed.dart';
import 'package:light/src/core/functions/light.dart';
import 'package:light/src/core/functions/timer.dart';
import 'package:light/src/core/keep_alive.dart';
import 'package:light/src/data/backup_service.dart';
import 'package:light/src/data/database.dart';
import 'package:light/src/data/models.dart';

import '../core/device/impl/at5_device.dart';
import '../core/functions/base.dart';
import '../core/functions/power.dart';
import '../core/functions/temperature.dart';
import '../core/device_registry.dart';
import '../core/protocol/remote_protocol.dart';
import '../core/remote/device_session.dart';
import '../core/remote_gateway.dart';
import '../core/protocol/client.dart';
import '../data/device_configuration.dart';
import '../data/remote_settings.dart';

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

  final AppDatabase _database;
  final BackupService _backupService;
  final RemoteGateway _remote;
  final RemoteSettingsStore _remoteStore;
  late final DeviceRegistryService _registry;
  StreamSubscription<RemoteSnapshot>? _registrySubscription;
  bool _disposed = false;
  bool _remoteStarting = false;

  /// 用户是否正在本机调光：拖动期间不让预览被其它状态覆盖
  bool _editingLight = false;
  RemoteSettings? remoteSettings;
  bool applying = false;
  String? commandStatus;
  int outputLimit = ControlSettings.defaults.outputLimit;
  LightState? _masterBrightnessSource;

  List<ScenePreset> scenes = const [];
  List<SchedulePlan> schedules = const [];
  List<SavedDevice> savedDevices = const [];
  List<DeviceConfiguration> deviceConfigurations = const [];
  LightState lightState = ControlSettings.defaults.lightState;
  bool powerEnabled = ControlSettings.defaults.powerEnabled;
  int temperature = ControlSettings.defaults.temperature;
  FanSpeed fanSpeed = ControlSettings.defaults.fanSpeed;
  bool reconnecting = false;
  String? userMessage;
  int messageVersion = 0;
  DateTime? _lastMessageAt;

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

  /// 默认的控制对象就是 AT5：它同时是远端通道上的编解码器
  final At5Client _defaultControlDevice = At5Client();
  GenericDeviceSession? _genericSession;
  DeviceRemoteSession? _at5Session;

  /// 当前控制对象：选中通用设备配置时使用它自己的设备实例，否则使用 AT5 描述符
  Device get controlDevice => _genericSession?.device ?? _defaultControlDevice;

  /// 当前是否在控制由配置驱动的通用设备
  bool get controllingGenericDevice => _genericSession != null;

  /// 指定设备的功能卡片，用于设备详情页
  ///
  /// 设备不是当前控制对象时返回占位卡片，避免把选中的设备状态画到别的设备上。
  Device deviceCardFor(String deviceId) {
    if (selectedDeviceId != deviceId) return _emptyDevice;
    return controlDevice;
  }

  static final Device _emptyDevice = At5Client(id: '', name: '未选择设备');

  Map<Type, DeviceFunctionBinding> get controlBindings {
    final session = _genericSession;
    return session == null ? _at5Bindings : _genericBindings(session);
  }

  /// 通用设备的绑定直接读写它自己的功能状态，命令按配置编码后经 MQTT 下发
  Map<Type, DeviceFunctionBinding> _genericBindings(
    GenericDeviceSession session,
  ) {
    final device = session.device;
    final bindings = <Type, DeviceFunctionBinding>{};
    for (final function in device.supportFunctions) {
      switch (function) {
        case PowerFunction():
          bindings[PowerFunction] = DeviceFunctionBinding<bool>(
            read: () =>
                device.status[ConfigurableFunction.power] as bool? ?? false,
            preview: (_) {},
            commit: (value) =>
                _commitGeneric(session, ConfigurableFunction.power, value),
          );
        case LightFunction():
          bindings[LightFunction] = LightControlBinding(
            read: () => _genericLight(),
            preview: (value) {
              if (applying) return;
              _editingLight = true;
              session.applyPreview(ConfigurableFunction.light, value.toJson());
              notifyListeners();
            },
            commit: (value) => _commitGeneric(
              session,
              ConfigurableFunction.light,
              value.toJson(),
            ),
            outputLimit: outputLimit,
            beginBrightness: () {
              _editingLight = true;
              _masterBrightnessSource = _genericLight();
            },
            changeBrightness: (value) {
              if (applying) return;
              _editingLight = true;
              final next = (_masterBrightnessSource ?? _genericLight())
                  .withPowerPercent(value.round(), limit: outputLimit);
              session.applyPreview(ConfigurableFunction.light, next.toJson());
              notifyListeners();
            },
            commitBrightness: () {
              _masterBrightnessSource = null;
              return _commitGeneric(
                session,
                ConfigurableFunction.light,
                _genericLight(),
              );
            },
          );
        case TemperatureFunction():
          bindings[TemperatureFunction] = DeviceFunctionBinding<double>(
            read: () =>
                (device.status[ConfigurableFunction.temperature] as num?)
                    ?.toDouble() ??
                0,
            preview: (value) => session.applyPreview(
              ConfigurableFunction.temperature,
              value,
            ),
            commit: (value) => _commitGeneric(
              session,
              ConfigurableFunction.temperature,
              value,
            ),
          );
        case FanSpeedFunction():
          bindings[FanSpeedFunction] = DeviceFunctionBinding<FanSpeed>(
            read: () =>
                FanSpeed.valueOf(
                  device.status[ConfigurableFunction.fanSpeed],
                ) ??
                FanSpeed.low,
            preview: (_) {},
            commit: (value) => _commitGeneric(
              session,
              ConfigurableFunction.fanSpeed,
              value.wire,
            ),
          );
        case FanSpeedFunction2():
          bindings[FanSpeedFunction2] = DeviceFunctionBinding<int>(
            read: () =>
                (device.status[ConfigurableFunction.fanSpeedPercent] as num?)
                    ?.toInt() ??
                0,
            preview: (_) {},
            commit: (value) => _commitGeneric(
              session,
              ConfigurableFunction.fanSpeedPercent,
              value,
            ),
          );
      }
    }
    return bindings;
  }

  LightState _genericLight() {
    final raw = _genericSession?.device.status[ConfigurableFunction.light];
    if (raw is! Map) return lightState;
    int channel(LightChannel key) => (raw[key.wire] as num?)?.toInt() ?? 0;
    return LightState(
      red: channel(LightChannel.red),
      green: channel(LightChannel.green),
      blue: channel(LightChannel.blue),
      white: channel(LightChannel.white),
      uv: channel(LightChannel.uv),
    );
  }

  Future<void> _commitGeneric(
    GenericDeviceSession session,
    ConfigurableFunction type,
    Object value,
  ) async {
    if (applying || _disposed) return;
    if (!session.ready) {
      commandStatus = '网关未连接，设置尚未下发';
      notifyListeners();
      return;
    }
    applying = true;
    commandStatus = '正在等待网关执行确认…';
    notifyListeners();
    try {
      final ok = await session.executeFunction(type, value);
      if (_disposed) return;
      commandStatus = ok ? '网关已下发，设备回报后更新状态' : '设备拒绝了本次设置';
      _editingLight = false;
    } catch (error) {
      commandStatus = error is RemoteCommandRejected
          ? error.message
          : '执行结果未确认：$error';
      _publishMessage(commandStatus!);
    } finally {
      applying = false;
      if (!_disposed) notifyListeners();
    }
  }

  Map<Type, DeviceFunctionBinding> get _at5Bindings => {
    PowerFunction: DeviceFunctionBinding<bool>(
      read: () => powerEnabled,
      preview: (_) {},
      commit: (value) async {
        if (value != powerEnabled) await togglePower();
      },
    ),
    LightFunction: LightControlBinding(
      read: () => lightState,
      preview: (value) {
        if (applying) return;
        _editingLight = true;
        lightState = value.limitedTo(outputLimit);
        notifyListeners();
      },
      commit: (_) => commitLightState(),
      outputLimit: outputLimit,
      beginBrightness: beginMasterBrightnessChange,
      changeBrightness: setMasterBrightness,
      commitBrightness: commitMasterBrightness,
    ),
    TemperatureFunction: DeviceFunctionBinding<double>(
      read: () => temperature.toDouble(),
      preview: setTemperature,
      commit: (_) => commitTemperatureAndFan(),
    ),
    FanSpeedFunction: DeviceFunctionBinding<FanSpeed>(
      read: () => fanSpeed,
      preview: (_) {},
      commit: (value) => setFanHighSpeed(value == FanSpeed.high),
    ),
  };

  int get brightness => lightState.powerPercent;

  bool get fanHighSpeed => fanSpeed == FanSpeed.high;

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
      if (remoteSettings?.enabled == true) {
        // 主控制链路同样需要息屏保持，否则系统挂起后 MQTT 心跳停止、控制全部失效
        await KeepAliveService.start(
          title: '设备控制已连接',
          text: '正在保持与网关的连接，避免息屏后断开',
        );
        _registry.reset();
        // 上次退出时选中的设备保存在远端配置里，连接前先恢复
        final selected = remoteSettings!.bluetoothDeviceId;
        _registry.select(selected.isEmpty ? null : selected);
        await _remote.connect(remoteSettings!);
        if (_disposed) return;
        // 选中的设备可能需要重新建立会话
        await _syncDeviceSession(_registry.selectedDeviceId);
      }
    } catch (_) {
      if (!_disposed) _publishMessage('远程配置读取失败，请在设备页重新配置');
    } finally {
      _remoteStarting = false;
    }
  }

  Future<void> saveRemoteSettings(RemoteSettings settings) async {
    if (applying) throw StateError('请等待当前命令完成');
    settings.validate();
    await _remoteStore.write(settings);
    if (_disposed) return;
    remoteSettings = settings;
    _editingLight = false;
    notifyListeners();
    if (settings.enabled) {
      await KeepAliveService.start(
        title: '设备控制已连接',
        text: '正在保持与网关的连接，避免息屏后断开',
      );
    } else {
      await KeepAliveService.stop();
    }
    _registry.reset();
    await _remote.connect(settings);
  }

  Future<void> clearRemoteSettings() async {
    if (applying) throw StateError('请等待当前命令完成');
    await _remoteStore.clear();
    remoteSettings = null;
    await KeepAliveService.stop();
    await _remote.disconnect();
    if (!_disposed) notifyListeners();
  }

  Future<void> reconnectRemote() async {
    if (applying) return;
    final settings = remoteSettings;
    if (settings != null && settings.enabled) await _remote.connect(settings);
  }

  void setForeground(bool foreground) {
    if (foreground && !_disposed && _remote.client.connected) {
      unawaited(refreshDeviceState());
    }
  }

  Future<void> refreshDeviceState() async {
    if (applying) return;
    _editingLight = false;
    try {
      await _remote.requestState();
      commandStatus = '网关状态已刷新；灯光参数显示最后设置值';
    } catch (error) {
      _publishMessage('刷新失败：$error');
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> setOutputLimit(int value) async {
    if (applying) return;
    outputLimit = value.clamp(1, 100);
    lightState = lightState.limitedTo(outputLimit);
    _saveControlSettings();
    notifyListeners();
    if (isConnected) {
      await _runDeviceAction(DeviceCommand.setLimit, _lightPayload());
    }
  }

  void beginMasterBrightnessChange() {
    _editingLight = true;
    _masterBrightnessSource = lightState;
  }

  void setMasterBrightness(double value) {
    if (applying) return;
    _editingLight = true;
    lightState = (_masterBrightnessSource ?? lightState).withPowerPercent(
      value.round(),
      limit: outputLimit,
    );
    notifyListeners();
  }

  Future<void> commitMasterBrightness() {
    _masterBrightnessSource = null;
    return commitLightState();
  }

  void setChannel(LightChannel channel, double value) {
    if (applying) return;
    _editingLight = true;
    final level = value.round().clamp(0, outputLimit);
    lightState = lightState.withChannel(channel, level);
    notifyListeners();
  }

  Map<String, Object?> _lightPayload() => DeviceStatePayload(
    channels: lightState.limitedTo(outputLimit),
    power: powerEnabled,
    temperature: temperature,
    fanSpeed: fanSpeed,
    outputLimit: outputLimit,
  ).toJson();

  Future<void> commitLightState() async {
    if (applying) return;
    lightState = lightState.limitedTo(outputLimit);
    _saveControlSettings();
    await _runDeviceAction(DeviceCommand.setState, _lightPayload());
  }

  void setTemperature(double value) {
    if (applying) return;
    _editingLight = true;
    temperature = value.round();
    notifyListeners();
  }

  Future<void> commitTemperatureAndFan() async {
    _saveControlSettings();
    await _runDeviceAction(DeviceCommand.setState, _lightPayload());
  }

  Future<void> setFanHighSpeed(bool highSpeed) async {
    if (applying) return;
    _editingLight = true;
    fanSpeed = highSpeed ? FanSpeed.high : FanSpeed.low;
    notifyListeners();
    await commitTemperatureAndFan();
  }

  Future<void> restoreControlDefaults() async {
    if (applying) return;
    final defaults = ControlSettings.defaults;
    lightState = defaults.lightState.limitedTo(outputLimit);
    powerEnabled = defaults.powerEnabled;
    temperature = defaults.temperature;
    fanSpeed = defaults.fanSpeed;
    _saveControlSettings();
    notifyListeners();
    if (isConnected) {
      await _runDeviceAction(
        DeviceCommand.setState,
        _lightPayload(),
        successMessage: '控制参数已恢复默认值',
      );
    } else {
      _publishMessage('控制参数已恢复默认值');
    }
  }

  Future<void> togglePower() async {
    if (applying) return;
    _editingLight = true;
    powerEnabled = !powerEnabled;
    notifyListeners();
    await commitLightState();
  }

  Future<void> applyScene(ScenePreset scene) async {
    if (applying) return;
    _editingLight = true;
    lightState = scene.state.limitedTo(outputLimit);
    powerEnabled = true;
    _saveControlSettings();
    notifyListeners();
    if (!isConnected) {
      commandStatus = '配色已载入本机，连接鱼缸灯后点击配色应用';
      notifyListeners();
      return;
    }
    await commitLightState();
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

  DeviceConfiguration configurationForDevice(String? id) {
    final existing = deviceConfigurations
        .where((item) => item.id == id)
        .firstOrNull;
    if (existing != null) return existing;
    final saved = savedDevices.where((item) => item.id == id).firstOrNull;
    final at5 = saved?.model != DeviceModel.generic;
    final types = <ConfigurableFunction>[
      if (at5) ConfigurableFunction.power,
      if (at5) ConfigurableFunction.light,
      if (at5) ConfigurableFunction.temperature,
      if (at5) ConfigurableFunction.fanSpeed,
      if (at5) ConfigurableFunction.timer,
    ];
    return DeviceConfiguration.fromJson({
      'id': id ?? 'device_${DateTime.now().microsecondsSinceEpoch}',
      'name': saved?.name ?? '新设备',
      'functions': [
        for (final type in types) {'type': type.wire},
      ],
    });
  }

  void saveDeviceConfiguration(
    DeviceConfiguration configuration, {
    String? previousId,
  }) {
    _database.saveDeviceConfiguration(configuration, previousId: previousId);
    deviceConfigurations = _database.loadDeviceConfigurations();
    notifyListeners();
  }

  void deleteDeviceConfiguration(String id) {
    _database.deleteDeviceConfiguration(id);
    deviceConfigurations = _database.loadDeviceConfigurations();
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
            temperature: scene.temperature,
            brightness: scene.brightness,
            accentValue: scene.accentValue,
            state: scene.state,
          );
        }
        _database.saveScene(scene);
        scenes = _database.loadScenes();
      } else {
        _database.replaceData(AppDataBundle.fromJson(json));
        _reloadData();
      }
      _publishMessage('导入完成');
    } catch (error) {
      _publishMessage('导入失败：$error');
    }
  }

  Future<void> resetAllData() async {
    _database.resetData();
    _reloadData();
    _publishMessage('本地数据已恢复为默认状态');
  }

  Future<void> startScan() => _registry.startScan();
  Future<void> stopScan() => _registry.stopScan();

  Future<void> connect(String deviceId) async {
    if (applying) throw StateError('请等待当前命令完成');
    await _registry.connectDevice(deviceId);
  }

  Future<void> selectDevice(
    String deviceId,
    String name, {
    DeviceModel model = DeviceModel.at5,
  }) async {
    if (applying) throw StateError('请等待当前命令完成');
    final settings = remoteSettings;
    if (settings == null) throw StateError('请先配置 MQTT');
    final updated = settings.withDevice(deviceId);
    await _remoteStore.write(updated);
    remoteSettings = updated;
    _editingLight = false;
    _database.saveDevice(
      SavedDevice(
        id: deviceId,
        name: name,
        model: model,
        room: '网关设备',
        lastConnectedAt: DateTime.now(),
      ),
    );
    savedDevices = _database.loadDevices();
    _registry.select(deviceId);
    await _syncDeviceSession(deviceId);
    // 通用设备的初始值来自它自己的配置，切换后要重新载入本机控制参数
    _reloadData();
    notifyListeners();
  }

  /// 为选中的设备建立会话：有通用配置时用配置驱动，否则按 AT5 处理
  ///
  /// 配置没有声明命令时不建立会话，设备保持只读预览。
  Future<void> _syncDeviceSession(String? deviceId) async {
    await _genericSession?.dispose();
    await _at5Session?.dispose();
    _genericSession = null;
    _at5Session = null;
    if (deviceId == null) return;
    final matches = deviceConfigurations.where((item) => item.id == deviceId);
    if (matches.isEmpty) {
      _at5Session = DeviceRemoteSession(
        gateway: _remote,
        codec: _defaultControlDevice,
        deviceId: deviceId,
      );
      return;
    }
    final session = GenericDeviceSession(
      client: _remote.client,
      config: matches.first.toJson(),
      deviceId: deviceId,
    );
    if (!session.device.supportsRemoteControl) {
      await session.dispose();
      return;
    }
    _genericSession = session;
  }

  Future<void> disconnect() async {
    if (applying) return;
    final id = selectedDeviceId;
    if (id != null) await _registry.disconnectDevice(id);
  }

  Future<void> clearSelectedDevice() async {
    final settings = remoteSettings;
    if (settings != null) {
      final updated = settings.withDevice('');
      await _remoteStore.write(updated);
      remoteSettings = updated;
    }
    _registry.select(null);
    await _syncDeviceSession(null);
    if (!_disposed) notifyListeners();
  }

  Future<void> toggleSchedule(SchedulePlan plan) async {
    final updated = plan.copyWith(enabled: !plan.enabled);
    _database.saveSchedule(updated);
    schedules = _database.loadSchedules();
    notifyListeners();

    if (isConnected && updated.id <= 2) {
      final config = TimerConfig(
        index: updated.id,
        enabled: updated.enabled,
        startHour: updated.startHour,
        startMinute: updated.startMinute,
        endHour: updated.endHour,
        endMinute: updated.endMinute,
        sunriseSunsetEnabled: true,
        sunriseMinutes: 30,
        sunsetMinutes: 30,
      );
      await _runDeviceAction(
        DeviceCommand.setTimer,
        config.toJson(),
        successMessage: '设备定时槽位已更新',
      );
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _registrySubscription?.cancel();
    _genericSession?.dispose();
    _at5Session?.dispose();
    _registry.dispose();
    _remote.dispose();
    _database.close();
    _defaultControlDevice.dispose();
    super.dispose();
  }

  /// 把一次控制参数下发到当前设备
  ///
  /// 通用设备的会话自己编码并回报结果，其它设备交给会话自己的下发方法。
  Future<void> _runDeviceAction(
    DeviceCommand command,
    Map<String, Object?> payload, {
    String? successMessage,
  }) async {
    if (applying || _disposed) return;
    if (controlRoute == ControlRoute.offline) {
      commandStatus = '设备离线，设置尚未下发';
      notifyListeners();
      return;
    }
    final generic = _genericSession;
    final at5 = _at5Session;
    if (generic == null && at5 == null) {
      commandStatus = '请先选择要控制的设备';
      notifyListeners();
      return;
    }
    applying = true;
    commandStatus = '正在等待网关执行确认…';
    notifyListeners();
    try {
      final result = generic == null
          ? await at5!.execute(command, payload)
          : await generic.execute(command, payload);
      if (_disposed) return;
      commandStatus = result.confirmation == RemoteConfirmation.written
          ? '网关已写入灯具，尚无状态回读'
          : '网关已收到灯具确认';
      if (!_disposed && successMessage != null) {
        _publishMessage('$successMessage · $commandStatus');
      }
    } catch (error) {
      commandStatus = error is RemoteCommandRejected
          ? error.message
          : '执行结果未确认，请刷新状态后再操作';
      if (!_disposed && successMessage != null) _publishMessage(commandStatus!);
    } finally {
      applying = false;
      if (!_disposed) notifyListeners();
    }
  }

  void _onRegistryChanged(RemoteSnapshot snapshot) {
    if (_disposed) return;
    // 远端状态变化只驱动界面刷新，设备状态由各设备的会话自己维护
    notifyListeners();
  }

  void _saveControlSettings() {
    _database.saveSettings(
      ControlSettings(
        lightState: lightState,
        powerEnabled: powerEnabled,
        temperature: temperature,
        fanSpeed: fanSpeed,
        outputLimit: outputLimit,
      ),
    );
  }

  void _reloadData() {
    deviceConfigurations = _database.loadDeviceConfigurations();
    scenes = _database.loadScenes();
    schedules = _database.loadSchedules();
    savedDevices = _database.loadDevices();
    final settings = _database.loadSettings();
    outputLimit = settings.outputLimit;
    lightState = settings.lightState.limitedTo(outputLimit);
    powerEnabled = settings.powerEnabled;
    temperature = settings.temperature;
    fanSpeed = settings.fanSpeed;
    notifyListeners();
  }

  String? _savedName(String id) =>
      savedDevices.where((item) => item.id == id).firstOrNull?.name;

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
