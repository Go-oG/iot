import 'dart:async';

import 'package:flutter/material.dart';
import 'package:light/src/core/connection_status.dart';
import 'package:light/src/core/protocol/model.dart';
import 'package:light/src/data/device_template.dart';

import '../../app/controller.dart';
import '../../app/router.dart';
import '../../app/scope.dart';
import '../../app/theme.dart';
import '../../core/device_registry.dart';
import '../../core/protocol/protocol.dart';
import '../../core/mqtt/mqtt_gateway.dart';
import '../../dialog/gateway_device.dart';
import '../../widgets/remote_card.dart';

class DevicesPage extends StatefulWidget {
  const DevicesPage({super.key});

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
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
      if (online && !_online) unawaited(_run(_refresh));
      _online = online;
    });
    _events ??= gateway.client.events.listen((event) {
      if (event.op == GatewayOption.hello) unawaited(_run(_refresh));
    });
    if (!_online && gateway.client.connected && gateway.client.gatewayOnline) {
      _online = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _run(_refresh);
      });
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _events?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    await gateway.requestState();
    await registry.execute(GatewayManageAction.status);
  }

  Future<void> _run(FutureOr<void> Function() action) async {
    if (_busy || !mounted) return;
    setState(() {
      _busy = true;
    });
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit([
    Map<String, Object?>? device,
    Map<String, Object?>? seen,
  ]) async {
    final result = await showGatewayDeviceEditor(
      context,
      device: device,
      seen: seen,
    );
    if (result == null || !mounted) return;
    await _run(() async {
      await registry.execute(GatewayManageAction.upsert, {
        GatewayField.device: result,
      });
      if (mounted) AppScope.controller.showMessage('登记已保存，ESP32 正在重启，重新上线后刷新');
    });
  }

  Future<void> _delete(Map<String, Object?> device) async {
    final id =
        device[GatewayField.deviceId.wire] ?? device[GatewayField.device.wire];
    final selected = registry.selectedDeviceId == id;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除网关登记'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '将删除 ${device[GatewayField.alias.wire]} 在网关上的登记，删除后 ESP32 会重启。',
            ),
            if (selected) ...[
              const SizedBox(height: 8),
              const Text(
                '这台设备当前正在控制中，删除后本机也会取消选择。',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ],
            const SizedBox(height: 8),
            const Text('此操作需要再次确认。', style: TextStyle(color: AppColors.muted)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.red),
            child: const Text('继续'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    // 删除会让 ESP32 重启，二次确认避免误触
    final again = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除并重启网关？'),
        content: Text('${device[GatewayField.alias.wire]} 的登记将无法恢复，确定要删除吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.red),
            child: const Text('删除并重启'),
          ),
        ],
      ),
    );
    if (again != true || !mounted) return;
    final controller = AppScope.controller;
    await _run(() async {
      await registry.execute(GatewayManageAction.remove, {
        GatewayField.device: device[GatewayField.device.wire],
      });
      if (registry.selectedDeviceId == id) {
        await controller.clearSelectedDevice();
      }
      if (mounted) controller.showMessage('登记已删除，ESP32 正在重启');
    });
  }

  Future<void> _chooseDeviceModel(String deviceId, String name) async {
    final controller = AppScope.controller;
    final currentModelId = controller.resolvedModelIdFor(deviceId);
    final modelId = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text(
                '选择协议模板',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            for (final template in controller.availableDeviceTemplates)
              ListTile(
                leading: Icon(
                  template.builtIn
                      ? Icons.inventory_2_outlined
                      : Icons.description_outlined,
                ),
                title: Text(template.name),
                subtitle: Text(
                  '${template.id} · ${template.propertyCount} 个属性'
                  '${template.builtIn ? ' · 内置' : ''}',
                ),
                trailing: template.id == currentModelId
                    ? const Icon(Icons.check_rounded, color: AppColors.blue)
                    : null,
                onTap: () => Navigator.pop(sheetContext, template.id),
              ),
          ],
        ),
      ),
    );
    if (modelId == null || !mounted) return;
    await _run(() => controller.bindDeviceModel(deviceId, modelId, name: name));
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.watch(context);
    return ListView(
      padding: const EdgeInsets.only(bottom: 24, left: 16, right: 16),
      children: [
        _buildToolbar(controller),
        const RemoteControlCard(margin: EdgeInsets.zero),
        const SizedBox(height: 16),
        Row(
          children: [
            const Expanded(
              child: Text(
                '协议模板',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            TextButton.icon(
              onPressed: context.pushDeviceModel,
              icon: const Icon(Icons.add),
              label: const Text('新建 / 导入模板'),
            ),
          ],
        ),
        ..._buildDeviceConfigCard(controller),
        const SizedBox(height: 16),
        ..._buildRecordCard(context, controller),
        const SizedBox(height: 32),
        ..._buildNearCard(controller),
      ],
    );
  }

  Widget _buildToolbar(AppController controller) {
    final remote = controller.mqttGateway;
    final ready =
        remote.client.connected &&
        remote.client.gatewayOnline &&
        !_busy &&
        !controller.devicesBusy;
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 16),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              '设备',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
          ),
          IconButton(
            onPressed: context.pushGatewayManagement,
            icon: const Icon(Icons.memory),
          ),
          IconButton(
            onPressed: ready ? () => _run(_refresh) : null,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildRecordCard(
    BuildContext context,
    AppController controller,
  ) {
    final remote = controller.mqttGateway;
    final registry = controller.deviceRegistry;
    final client = remote.client;

    final ready = client.isReady && !_busy && !controller.devicesBusy;

    final devices = registry.devices;
    final states = registry.runtime.values;

    List<Widget> wList = [];

    wList.add(
      Row(
        children: [
          const Expanded(
            child: Text('已登记设备', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          GestureDetector(
            onTap: () {
              if (ready) {
                _edit();
              }
            },
            child: Icon(Icons.add, color: AppColors.blue, size: 24),
          ),
        ],
      ),
    );

    if (devices.isEmpty) {
      wList.add(
        const ListTile(
          title: Text('暂无登记设备'),
          subtitle: Text('连接 MQTT 后扫描网关附近设备，或手动填写 BLE 地址'),
        ),
      );
    }

    for (var device in devices) {
      final id =
          (device[GatewayField.deviceId.wire] ??
                  device[GatewayField.device.wire])
              as String;
      final state = remote.client.device(id);
      final runtime = states
          .where(
            (s) =>
                s[GatewayField.device.wire] == device[GatewayField.device.wire],
          )
          .firstOrNull;
      final connected =
          state?.connected == true && registry.snapshot.mqttIsOnline;
      final selected = registry.selectedDeviceId == id;
      final mode = GatewayDeviceMode.valueOf(device[GatewayField.mode.wire]);
      final modelId = controller.resolvedModelIdFor(id);
      final template = modelId == null ? null : controller.templateFor(modelId);
      final deviceName = '${device[GatewayField.alias.wire]}';
      final bound = controller.savedDevices.any(
        (item) => item.id == id && item.modelId != null,
      );

      wList.add(
        Card(
          margin: const EdgeInsets.symmetric(vertical: 5),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${device[GatewayField.alias.wire]} ${selected ? '· 当前设备' : ''}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                Text(
                  '$id · ${template?.name ?? '未匹配模板'}'
                  '${bound ? '' : ' · 自动匹配'} · '
                  '${connected ? '已连接' : ConnectionStatus.valueOf(runtime?[GatewayField.state.wire])?.label ?? '未连接'}'
                  '${state?.rssi == null ? '' : ' · ${state!.rssi} dBm'}',
                ),
                Divider(height: 18, color: AppColors.line),
                Wrap(
                  spacing: 2,
                  children: [
                    _DeviceCardAction(
                      icon: connected
                          ? Icons.link_off_rounded
                          : Icons.link_rounded,
                      tooltip: connected ? '断开连接' : '建立连接',
                      onPressed: () {
                        if (!ready) {
                          return;
                        }
                        _run(() {
                          if (connected) {
                            registry.disconnectDevice(id);
                          } else {
                            registry.connectDevice(id);
                          }
                        });
                      },
                    ),
                    _DeviceCardAction(
                      icon: mode?.isBroadcast == true
                          ? Icons.campaign_outlined
                          : Icons.lightbulb_outline_rounded,
                      tooltip: mode?.isBroadcast == true
                          ? '广播设备不支持单独控制'
                          : '使用${template?.name ?? '自动匹配模板'}控制',
                      onPressed: ready && mode?.isBroadcast != true
                          ? () => _run(() async {
                              if (!connected) {
                                await registry.connectDevice(id);
                              }
                              await controller.selectDevice(id, deviceName);
                              if (context.mounted) {
                                context.pushDevice(id);
                              }
                            })
                          : null,
                    ),
                    _DeviceCardAction(
                      icon: Icons.terminal_rounded,
                      tooltip: '读写 / 通知',
                      onPressed: ready
                          ? () => context.pushDeviceDebug(id)
                          : null,
                    ),
                    _DeviceCardAction(
                      icon: Icons.category_outlined,
                      tooltip: '绑定协议模板',
                      onPressed: () => _chooseDeviceModel(id, deviceName),
                    ),
                    _DeviceCardAction(
                      icon: Icons.description_outlined,
                      tooltip: '编辑当前协议模板',
                      onPressed: modelId == null
                          ? null
                          : () => context.pushDeviceModel(modelId: modelId),
                    ),
                    _DeviceCardAction(
                      icon: Icons.edit_outlined,
                      tooltip: '编辑登记',
                      onPressed: ready ? () => _edit(device) : null,
                    ),
                    _DeviceCardAction(
                      icon: runtime?[GatewayField.paused.wire] == true
                          ? Icons.play_circle_outline_rounded
                          : Icons.pause_circle_outline_rounded,
                      tooltip: runtime?[GatewayField.protocolOwned.wire] == true
                          ? '协议接管中，请使用连接 / 断开'
                          : runtime?[GatewayField.paused.wire] == true
                          ? '恢复自动连接'
                          : '暂停自动连接',
                      onPressed:
                          ready &&
                              runtime?[GatewayField.protocolOwned.wire] != true
                          ? () => _run(() async {
                              await registry.execute(
                                runtime?[GatewayField.paused.wire] == true
                                    ? GatewayManageAction.resume
                                    : GatewayManageAction.pause,
                                {
                                  GatewayField.device:
                                      device[GatewayField.device.wire],
                                },
                              );
                              await _refresh();
                            })
                          : null,
                    ),
                    _DeviceCardAction(
                      icon: Icons.delete_outline_rounded,
                      tooltip: '删除登记',
                      color: AppColors.red,
                      onPressed: ready ? () => _delete(device) : null,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }
    return wList;
  }

  List<Widget> _buildDeviceConfigCard(AppController controller) {
    List<Widget> wList = [];
    final deviceIds = {
      ...controller.savedDevices.map((item) => item.id),
      ...controller.deviceRegistry.registered.keys,
    };
    for (final template in controller.availableDeviceTemplates) {
      final boundCount = deviceIds
          .where((id) => controller.resolvedModelIdFor(id) == template.id)
          .length;
      wList.add(
        Card(
          child: ListTile(
            leading: Icon(
              template.builtIn
                  ? Icons.inventory_2_outlined
                  : Icons.description_outlined,
            ),
            title: Text('${template.name}${template.builtIn ? ' · 内置' : ''}'),
            subtitle: Text(
              '${template.id} · ${template.propertyCount} 个属性 · '
              '已绑定 $boundCount 台设备',
            ),
            onTap: () => context.pushDeviceModel(modelId: template.id),
            trailing: template.builtIn
                ? null
                : PopupMenuButton<String>(
                    onSelected: (value) async {
                      if (value == 'edit') {
                        context.pushDeviceModel(modelId: template.id);
                        return;
                      }
                      _deleteTemplate(template, controller);
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'edit', child: Text('编辑协议模板')),
                      PopupMenuItem(value: 'delete', child: Text('删除协议模板')),
                    ],
                  ),
          ),
        ),
      );
    }
    return wList;
  }

  List<Widget> _buildNearCard(AppController controller) {
    final remote = controller.mqttGateway;
    final ready =
        remote.client.connected &&
        remote.client.gatewayOnline &&
        !_busy &&
        !controller.devicesBusy;
    final devices = registry.devices;
    final known = devices.map((d) => d[GatewayField.device.wire]).toSet();

    List<Widget> wList = [];

    wList.add(
      Row(
        children: [
          const Expanded(
            child: Text(
              '网关附近设备',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          GestureDetector(
            onTap: () {
              if (ready) {
                _run(
                  registry.scanning ? registry.stopScan : registry.startScan,
                );
              }
            },
            child: Icon(
              registry.scanning ? Icons.stop : Icons.search,
              color: AppColors.blue,
              size: 24,
            ),
          ),
        ],
      ),
    );

    if (registry.scanning) {
      wList.add(const LinearProgressIndicator());
    }

    if (registry.nearby.isEmpty) {
      wList.add(const ListTile(subtitle: Text('扫描由 ESP32 执行，结果通过 MQTT 返回')));
    }
    for (var seen in registry.nearby.values) {
      wList.add(
        ListTile(
          title: Text('${seen[GatewayField.name.wire] ?? '未命名设备'}'),
          subtitle: Text(
            '${seen[GatewayField.mac.wire] ?? seen[GatewayField.deviceId.wire]} · '
            '${seen[GatewayField.addrType.wire]} · '
            '${seen[GatewayField.rssi.wire]} dBm',
          ),
          trailing: TextButton(
            onPressed: ready && !known.contains(seen[GatewayField.mac.wire])
                ? () => _edit(null, seen)
                : null,
            child: Text(
              known.contains(seen[GatewayField.mac.wire]) ? '已登记' : '登记',
            ),
          ),
        ),
      );
    }

    return wList;
  }

  void _deleteTemplate(
    DeviceTemplate template,
    AppController controller,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除协议模板？'),
        content: Text('将删除 ${template.name}，未绑定设备的模板可以安全移除'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      try {
        controller.deleteDeviceTemplate(template.id);
      } catch (error) {
        controller.showMessage('$error');
      }
    }
  }
}

/// 登记卡片底部的单个操作，图标表示动作，长按或悬停显示说明
class _DeviceCardAction extends StatelessWidget {
  const _DeviceCardAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.color,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        onPressed: onPressed,
        visualDensity: VisualDensity.compact,
        icon: Icon(
          icon,
          size: 20,
          color: onPressed == null
              ? AppColors.muted.withValues(alpha: 0.4)
              : color ?? AppColors.blue,
        ),
      ),
    );
  }
}
