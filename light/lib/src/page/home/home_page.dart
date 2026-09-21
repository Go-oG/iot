import 'dart:async';

import 'package:flutter/material.dart';
import 'package:light/src/core/connection_status.dart';
import 'package:light/src/core/protocol/model.dart';

import '../../app/controller.dart';
import '../../app/router.dart';
import '../../app/scope.dart';
import '../../app/theme.dart';
import '../../core/device_registry.dart';
import '../../core/protocol/protocol.dart';
import '../../core/mqtt/mqtt_gateway.dart';
import '../../data/device_template.dart';
import '../../data/models.dart';
import '../../widgets/app_widgets.dart';
import '../../widgets/remote_card.dart';

/// 首页：用自适应网格展示全部设备
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

  MqttGateway get gateway => AppScope.controller.mqttGateway;

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
      await controller.togglePowerFor(item.id);
    });
  }

  /// 本机保存过的设备优先，网关新登记但本机没有的设备也一并展示
  List<_HomeDevice> _items(AppController controller, MqttGateway remote) {
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

  _HomeDevice _describe(
    AppController controller,
    MqttGateway remote, {
    required String id,
    SavedDevice? saved,
  }) {
    final registry = controller.deviceRegistry;
    final state = remote.client.device(id);
    final registration = registry.registered[id];
    final entry = registry.stateOf(id);
    final connected =
        state?.connected == true && registry.snapshot.mqttIsOnline;
    final mode = GatewayDeviceMode.valueOf(
      registration?[GatewayField.mode.wire],
    );
    final template = controller.templateForDevice(id);
    final savedDevice =
        saved ??
        controller.savedDevices.where((item) => item.id == id).firstOrNull;
    final supportsLight = _supportsLight(template);
    final name = _nameOf(
      controller,
      id,
      savedDevice,
      template,
      registration,
    );
    return _HomeDevice(
      id: id,
      name: name,
      selected: controller.selectedDeviceId == id,
      connected: connected,
      supportsLight: supportsLight,
      powerOn: controller.reportedPowerFor(id),
      detail: _detail(
        controller,
        entry,
        selected: controller.selectedDeviceId == id,
        connected: connected,
        template: template,
        deviceId: id,
      ),
      // 协议接管的设备由网关维护连接，广播设备没有单独通道
      canToggle:
          connected &&
          controller.reportedPowerFor(id) != null &&
          !controller.devicesBusy &&
          mode?.isBroadcast != true &&
          registration?[GatewayField.protocolOwned.wire] != true,
    );
  }

  String _nameOf(
    AppController controller,
    String id,
    SavedDevice? saved,
    DeviceTemplate? template,
    Map<String, Object?>? registration,
  ) {
    if (saved != null && saved.name.trim().isNotEmpty) return saved.name.trim();
    final remote = controller.gatewayState.device(id)?.name;
    if (remote != null && remote.trim().isNotEmpty) return remote.trim();
    // 网关登记里的别名，用于展示本机还没保存过的设备
    final alias = registration?[GatewayField.alias.wire];
    if (alias is String && alias.trim().isNotEmpty) return alias.trim();
    if (template != null && template.name.trim().isNotEmpty) {
      return template.name.trim();
    }
    return id;
  }

  bool _supportsLight(DeviceTemplate? template) {
    if (template == null) return false;
    final power = template.definition.properties['power'];
    return power != null && power.canWrite;
  }

  /// 卡片副标题：当前控制的设备展示亮度，其它设备展示网关运行状态
  String _detail(
    AppController controller,
    Map<String, Object?>? entry, {
    required bool selected,
    required bool connected,
    required DeviceTemplate? template,
    required String deviceId,
  }) {
    if (!connected) {
      return ConnectionStatus.valueOf(entry?[GatewayField.state.wire])?.label ??
          '未连接';
    }
    if (template != null) {
      return '${template.propertyCount} 个属性 · 模板 ${template.name}';
    }
    return '已连接 · 状态待回读';
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.watch(context);
    final remote = controller.mqttGateway;
    final items = _items(controller, remote);
    final online = controller.deviceRegistry.snapshot.mqttIsOnline;
    final ready =
        remote.client.connected && online && !_busy && !controller.devicesBusy;
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
            action: AppIconButton(
              icon: Icons.refresh_rounded,
              tooltip: '同步网关',
              onPressed: ready ? _load : null,
            ),
          ),
          const RemoteControlCard(),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: SectionTitle(
              '全部设备',
              trailing: TextButton(
                onPressed: context.goDevices,
                child: const Text('管理设备'),
              ),
            ),
          ),
          if (_busy) const LinearProgressIndicator(),
          if (items.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(18, 18, 18, 30),
              child: Text(
                '还没有设备，到“设备”页扫描网关附近的 BLE 设备并登记',
                style: TextStyle(color: AppColors.muted),
              ),
            )
          else
            LayoutBuilder(
              builder: (context, constraints) {
                final textScaler = MediaQuery.textScalerOf(context);
                final minWidth = 156 + (textScaler.scale(15) - 15) * 4;
                final columns = ((constraints.maxWidth - 20) / (minWidth + 12))
                    .floor()
                    .clamp(1, 6);
                return GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    mainAxisExtent:
                        146 +
                        textScaler.scale(15) * 2.6 +
                        textScaler.scale(12) * 2.8,
                  ),
                  itemCount: items.length,
                  itemBuilder: (context, index) => _DeviceCard(
                    item: items[index],
                    onToggle: () => _toggle(items[index]),
                  ),
                );
              },
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
    final accent = item.connected ? AppColors.blue : AppColors.muted;
    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color: item.selected ? AppColors.blue : AppColors.line,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.pushDevice(item.id),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(
                      item.supportsLight
                          ? Icons.lightbulb_outline_rounded
                          : Icons.devices_other_rounded,
                      size: 25,
                      color: accent,
                    ),
                  ),
                  if (item.supportsLight)
                    IconButton(
                      onPressed: item.canToggle ? onToggle : null,
                      tooltip: item.powerOn == null
                          ? '状态待回读'
                          : item.powerOn!
                          ? '关闭灯光'
                          : '打开灯光',
                      style: IconButton.styleFrom(
                        minimumSize: const Size(48, 48),
                        backgroundColor: item.canToggle && item.powerOn == true
                            ? AppColors.paleBlue
                            : AppColors.canvas,
                        foregroundColor: item.powerOn == true
                            ? AppColors.blue
                            : AppColors.muted,
                        disabledForegroundColor: AppColors.muted.withValues(
                          alpha: 0.4,
                        ),
                      ),
                      icon: const Icon(
                        Icons.power_settings_new_rounded,
                        size: 22,
                      ),
                    )
                  else
                    const SizedBox(height: 48),
                ],
              ),
              const SizedBox(height: 14),
              SizedBox(
                height: MediaQuery.textScalerOf(context).scale(15) * 2.6,
                child: Text(
                  item.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    height: 1.3,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: item.connected ? AppColors.green : AppColors.grey,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${item.connected ? '在线' : '离线'} · ${item.detail}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        height: 1.4,
                        color: AppColors.muted,
                      ),
                    ),
                  ),
                ],
              ),
              const Spacer(),
              const Divider(),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      item.selected ? '当前控制' : '查看设备',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.4,
                        fontWeight: item.selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                        color: item.selected ? AppColors.blue : AppColors.muted,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: item.selected ? AppColors.blue : AppColors.muted,
                  ),
                ],
              ),
            ],
          ),
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
    required this.powerOn,
    required this.detail,
    required this.canToggle,
  });

  final String id;
  final String name;
  final bool selected;
  final bool connected;
  final bool supportsLight;
  final bool? powerOn;
  final String detail;
  final bool canToggle;
}
