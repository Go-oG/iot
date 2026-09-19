import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/controller.dart';
import '../../app/scope.dart';
import '../../app/theme.dart';
import '../../core/device/impl/generic_device.dart';
import '../../core/device_registry.dart';
import '../../core/functions/light.dart';
import '../../core/protocol/client.dart';
import '../../core/protocol/protocol.dart';
import '../../core/remote_gateway.dart';
import '../../data/device_configuration.dart';
import '../../data/models.dart';
import '../../widgets/app_widgets.dart';
import '../../widgets/remote_card.dart';

/// 首页：用两列卡片展示全部设备
/// 卡片上可以直接开关灯，其余操作在设备详情页完成
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  StreamSubscription<GatewayClientSnapshot>? _subscription;
  StreamSubscription<GatewayEvent>? _events;
  bool _online = false;
  bool _busy = false;

  RemoteGateway get gateway => AppScope.controller.mqttGateway;

  DeviceRegistryService get registry => AppScope.controller.deviceRegistry;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _subscription ??= gateway.client.changes.listen((state) {
      final online = state.connected && state.gatewayOnline;
      if (online && !_online) unawaited(_load());
      _online = online;
    });
    _events ??= gateway.client.events.listen((event) {
      if (event.op == GatewayOption.hello) unawaited(_load());
    });
    if (!_online && gateway.client.connected && gateway.client.gatewayOnline) {
      _online = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_load());
      });
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _events?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      await registry.execute(GatewayManageAction.status);
    } catch (_) {
      // 拉取失败时保留上一次的设备列表，卡片各自展示自己的在线状态
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy || !mounted) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted) AppScope.controller.showMessage('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggle(_HomeDevice item) async {
    final controller = AppScope.controller;
    await _run(() async {
      if (controller.selectedDeviceId != item.id) {
        await controller.selectDevice(item.id, item.name, model: item.model);
      }
      await controller.togglePower();
    });
  }

  /// 本机保存过的设备优先，网关新登记但本机没有的设备也一并展示
  List<_HomeDevice> _items(AppController controller, RemoteGateway remote) {
    final devices = controller.deviceRegistry;
    final items = <_HomeDevice>[];
    final listed = <String>{};
    String? selectedId;
    for (final saved in controller.savedDevices) {
      listed.add(saved.id);
      final item = _describe(controller, remote, id: saved.id, saved: saved);
      if (item.selected) selectedId = saved.id;
      items.add(item);
    }
    for (final id in devices.registered.keys) {
      if (!listed.add(id)) continue;
      final item = _describe(controller, remote, id: id);
      if (item.selected) selectedId = id;
      items.add(item);
    }
    // 当前控制的设备排在最前，与米家的默认设备一致
    if (selectedId != null) {
      final index = items.indexWhere((item) => item.id == selectedId);
      if (index > 0) items.insert(0, items.removeAt(index));
    }
    return items;
  }

  _HomeDevice _describe(AppController controller, RemoteGateway remote, {required String id, SavedDevice? saved}) {
    final registry = controller.deviceRegistry;
    final state = remote.client.device(id);
    final registration = registry.registered[id];
    final entry = registry.stateOf(id);
    final connected = state?.connected == true && registry.snapshot.deviceOnline;
    final mode = GatewayDeviceMode.valueOf(registration?[GatewayField.mode.wire]);
    final configuration = controller.deviceConfigurations.where((item) => item.id == id).firstOrNull;
    final savedDevice = saved ?? controller.savedDevices.where((item) => item.id == id).firstOrNull;
    final supportsLight = _supportsLight(savedDevice, configuration);
    final name = _nameOf(controller, id, savedDevice, configuration, registration);
    return _HomeDevice(
      id: id,
      name: name,
      selected: controller.selectedDeviceId == id,
      connected: connected,
      supportsLight: supportsLight,
      model: configuration != null
          ? DeviceModel.generic
          : savedDevice?.model ??
                (mode?.isGeneric == true ? DeviceModel.generic : DeviceModel.at5),
      powerOn: controller.powerEnabled,
      detail: _detail(
        controller,
        entry,
        selected: controller.selectedDeviceId == id,
        connected: connected,
        configuration: configuration,
      ),
      // 协议接管的设备由网关维护连接，广播设备没有单独通道
      canToggle:
          connected &&
          !controller.applying &&
          mode?.isBroadcast != true &&
          registration?[GatewayField.protocolOwned.wire] != true,
    );
  }

  String _nameOf(
    AppController controller,
    String id,
    SavedDevice? saved,
    DeviceConfiguration? configuration,
    Map<String, Object?>? registration,
  ) {
    if (saved != null && saved.name.trim().isNotEmpty) return saved.name.trim();
    final remote = controller.gatewayState.device(id)?.name;
    if (remote != null && remote.trim().isNotEmpty) return remote.trim();
    // 网关登记里的别名，用于展示本机还没保存过的设备
    final alias = registration?[GatewayField.alias.wire];
    if (alias is String && alias.trim().isNotEmpty) return alias.trim();
    if (configuration != null && configuration.name.trim().isNotEmpty) {
      return configuration.name.trim();
    }
    return id;
  }

  bool _supportsLight(SavedDevice? saved, DeviceConfiguration? configuration) {
    if (configuration == null) return saved?.model != DeviceModel.generic;
    final device = GenericDevice.fromJson(configuration.toJson());
    try {
      return device.supportFunctions.any((function) => function is LightFunction);
    } finally {
      device.dispose();
    }
  }

  /// 卡片副标题：当前控制的设备展示亮度，其它设备展示网关运行状态
  String _detail(
    AppController controller,
    Map<String, Object?>? entry, {
    required bool selected,
    required bool connected,
    required DeviceConfiguration? configuration,
  }) {
    if (!connected) {
      return GatewayStatus.valueOf(entry?[GatewayField.state.wire])?.label ?? '未连接';
    }
    if (selected) {
      if (!controller.powerEnabled) return '已关闭';
      return '亮度 ${controller.brightness}%';
    }
    if (configuration != null) return '${configuration.functions.length} 个功能模块';
    return '已连接';
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.watch(context);
    final remote = controller.mqttGateway;
    final items = _items(controller, remote);
    final online = controller.deviceRegistry.snapshot.deviceOnline;
    final ready = remote.client.connected && online && !_busy && !controller.applying;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          AppPageHeader(
            title: '首页',
            subtitle: online
                ? '网关在线 · 共 ${items.length} 台设备'
                : remote.client.connected
                ? '网关离线，正在等待上线'
                : 'MQTT 未连接',
            action: AppIconButton(icon: Icons.refresh_rounded, tooltip: '同步网关', onPressed: ready ? _load : null),
          ),
          const RemoteControlCard(),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: SectionTitle(
              '全部设备',
              trailing: TextButton(onPressed: () => context.go('/devices'), child: const Text('管理设备')),
            ),
          ),
          if (_busy) const LinearProgressIndicator(),
          if (items.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(18, 18, 18, 30),
              child: Text('还没有设备，到“设备”页扫描网关附近的 BLE 设备并登记', style: TextStyle(color: AppColors.muted)),
            )
          else
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 0.92,
              ),
              itemCount: items.length,
              itemBuilder: (context, index) => _DeviceCard(item: items[index], onToggle: () => _toggle(items[index])),
            ),
        ],
      ),
    );
  }
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({required this.item, required this.onToggle});

  final _HomeDevice item;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 10),
      borderColor: item.selected ? AppColors.blue : null,
      child: InkWell(
        onTap: () => context.push('/device/${Uri.encodeComponent(item.id)}'),
        borderRadius: BorderRadius.circular(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                StatusPill(
                  label: item.connected ? '在线' : '离线',
                  color: item.connected ? AppColors.green : AppColors.muted,
                  icon: item.connected ? Icons.link_rounded : Icons.link_off_rounded,
                ),
                const Spacer(),
                if (item.selected) const StatusPill(label: '控制中', color: AppColors.blue),
              ],
            ),
            const Spacer(),
            Row(
              children: [
                Expanded(
                  child: Icon(
                    item.supportsLight ? Icons.lightbulb_outline_rounded : Icons.devices_other_rounded,
                    size: 28,
                    color: item.connected ? AppColors.blue : AppColors.muted,
                  ),
                ),
                if (item.supportsLight)
                  IconButton(
                    onPressed: item.canToggle ? onToggle : null,
                    visualDensity: VisualDensity.compact,
                    tooltip: item.powerOn ? '关闭灯光' : '打开灯光',
                    icon: Icon(
                      Icons.power_settings_new_rounded,
                      size: 22,
                      color: item.canToggle
                          ? (item.powerOn ? AppColors.blue : AppColors.muted)
                          : AppColors.muted.withValues(alpha: 0.4),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, height: 1.2),
            ),
            const SizedBox(height: 3),
            Text(
              item.detail,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: AppColors.muted),
            ),
          ],
        ),
      ),
    );
  }
}

class _HomeDevice {
  const _HomeDevice({
    required this.id,
    required this.name,
    required this.selected,
    required this.connected,
    required this.supportsLight,
    required this.model,
    required this.powerOn,
    required this.detail,
    required this.canToggle,
  });

  final String id;
  final String name;
  final bool selected;
  final bool connected;
  final bool supportsLight;
  final DeviceModel model;
  final bool powerOn;
  final String detail;
  final bool canToggle;
}
