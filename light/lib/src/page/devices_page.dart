import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../app/scope.dart';
import '../app/theme.dart';
import '../core/device_registry.dart';
import '../core/protocol/client.dart';
import '../core/protocol/protocol.dart';
import '../core/remote_gateway.dart';
import '../data/models.dart';
import '../dialog/gateway_device.dart';
import '../shared/remote_control_card.dart';

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
  String? _error;

  RemoteGateway get gateway => AppScope.controller.mqttGateway;

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

  Future<void> _run(Future<void> Function() action) async {
    if (_busy || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit([Map<String, Object?>? device, Map<String, Object?>? seen]) async {
    final result = await showGatewayDeviceEditor(context, device: device, seen: seen);
    if (result == null || !mounted) return;
    await _run(() async {
      await registry.execute(
        GatewayManageAction.upsert,
        {GatewayField.device: result},
      );
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
              const Text('这台设备当前正在控制中，删除后本机也会取消选择。', style: TextStyle(fontWeight: FontWeight.w700)),
            ],
            const SizedBox(height: 8),
            const Text('此操作需要再次确认。', style: TextStyle(color: AppColors.muted)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
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
        content: Text(
          '${device[GatewayField.alias.wire]} 的登记将无法恢复，确定要删除吗？',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
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
      await registry.execute(
        GatewayManageAction.remove,
        {GatewayField.device: device[GatewayField.device.wire]},
      );
      if (registry.selectedDeviceId == id) {
        await controller.clearSelectedDevice();
      }
      if (mounted) controller.showMessage('登记已删除，ESP32 正在重启');
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.controller;
    final remote = controller.mqttGateway;
    final registry = controller.deviceRegistry;
    final ready = remote.client.connected && remote.client.gatewayOnline && !_busy && !controller.applying;
    final devices = registry.devices;
    final states = registry.runtime.values;
    final known = devices
        .map((d) => d[GatewayField.device.wire])
        .toSet();
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const Expanded(
                child: Text('设备', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              ),
              IconButton(
                onPressed: () => context.push('/gateway-management'),
                icon: const Icon(Icons.memory),
                tooltip: 'ESP32 管理',
              ),
              IconButton(
                onPressed: ready ? () => _run(_refresh) : null,
                icon: const Icon(Icons.refresh),
                tooltip: '同步网关',
              ),
            ],
          ),
        ),
        const RemoteControlCard(),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const Expanded(
                child: Text('ESP32 已登记设备', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              TextButton.icon(
                onPressed: ready ? () => _edit() : null,
                icon: const Icon(Icons.add),
                label: const Text('手动登记'),
              ),
            ],
          ),
        ),
        if (devices.isEmpty) const ListTile(title: Text('暂无登记设备'), subtitle: Text('连接 MQTT 后扫描网关附近设备，或手动填写 BLE 地址')),
        for (final device in devices)
          Builder(
            builder: (context) {
              final id =
                  (device[GatewayField.deviceId.wire] ??
                          device[GatewayField.device.wire])
                      as String;
              final state = remote.client.device(id);
              final runtime = states
                  .where((s) => s[GatewayField.device.wire] == device[GatewayField.device.wire])
                  .firstOrNull;
              final connected = state?.connected == true && registry.snapshot.deviceOnline;
              final selected = registry.selectedDeviceId == id;
              final mode = GatewayDeviceMode.valueOf(device[GatewayField.mode.wire]);
              final generic =
                  controller.deviceConfigurations.any((item) => item.id == id);
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${device[GatewayField.alias.wire]} ${selected ? '· 当前灯具' : ''}',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      Text(
                        '$id · ${connected ? '已连接' : GatewayStatus.valueOf(runtime?[GatewayField.state.wire])?.label ?? '未连接'}${state?.rssi == null ? '' : ' · ${state!.rssi} dBm'}',
                      ),
                      Divider(height: 18, color: AppColors.line),
                      Wrap(
                        spacing: 2,
                        children: [
                          _DeviceCardAction(
                            icon: connected ? Icons.link_off_rounded : Icons.link_rounded,
                            tooltip: connected ? '断开连接' : '建立连接',
                            onPressed: ready
                                ? () =>
                                      _run(() => connected ? registry.disconnectDevice(id) : registry.connectDevice(id))
                                : null,
                          ),
                          _DeviceCardAction(
                            icon: mode?.isBroadcast == true
                                ? Icons.campaign_outlined
                                : generic
                                ? Icons.memory_rounded
                                : Icons.lightbulb_outline_rounded,
                            tooltip: mode?.isBroadcast == true
                                ? '广播设备不支持单独控制'
                                : generic
                                ? '作为通用设备控制'
                                : '作为 AT5 灯控制',
                            onPressed: ready && mode?.isBroadcast != true
                                ? () => _run(() async {
                                    if (!connected) {
                                      await registry.connectDevice(id);
                                    }
                                    await controller.selectDevice(
                                      id,
                                      '${device[GatewayField.alias.wire]}',
                                      model: mode?.isGeneric == true
                                          ? DeviceModel.generic
                                          : DeviceModel.at5,
                                    );
                                    if (context.mounted) {
                                      context.push('/device/${Uri.encodeComponent(id)}');
                                    }
                                  })
                                : null,
                          ),
                          _DeviceCardAction(
                            icon: Icons.terminal_rounded,
                            tooltip: '读写 / 通知',
                            onPressed: ready ? () => context.push('/device-debug/${Uri.encodeComponent(id)}') : null,
                          ),
                          _DeviceCardAction(
                            icon: Icons.tune_rounded,
                            tooltip: '设备功能配置',
                            onPressed: () => context.push('/device-functions?deviceId=${Uri.encodeComponent(id)}'),
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
                            onPressed: ready && runtime?[GatewayField.protocolOwned.wire] != true
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
              );
            },
          ),
        const Divider(height: 32),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              const Expanded(
                child: Text('网关附近的 BLE 设备', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              TextButton.icon(
                onPressed: ready ? () => _run(registry.scanning ? registry.stopScan : registry.startScan) : null,
                icon: Icon(registry.scanning ? Icons.stop : Icons.search),
                label: Text(registry.scanning ? '停止' : '扫描 5 秒'),
              ),
            ],
          ),
        ),
        if (registry.scanning) const LinearProgressIndicator(),
        if (registry.nearby.isEmpty) const ListTile(subtitle: Text('扫描由 ESP32 执行，结果通过 MQTT 返回')),
        for (final seen in registry.nearby.values)
          ListTile(
            title: Text(
              '${seen[GatewayField.name.wire] ?? '未命名设备'}',
            ),
            subtitle: Text(
              '${seen[GatewayField.mac.wire] ?? seen[GatewayField.deviceId.wire]} · '
              '${seen[GatewayField.addrType.wire]} · '
              '${seen[GatewayField.rssi.wire]} dBm',
            ),
            trailing: TextButton(
              onPressed: ready &&
                      !known.contains(seen[GatewayField.mac.wire])
                  ? () => _edit(null, seen)
                  : null,
              child: Text(
                known.contains(seen[GatewayField.mac.wire]) ? '已登记' : '登记',
              ),
            ),
          ),
      ],
    );
  }
}

/// 登记卡片底部的单个操作，图标表示动作，长按或悬停显示说明
class _DeviceCardAction extends StatelessWidget {
  const _DeviceCardAction({required this.icon, required this.tooltip, required this.onPressed, this.color});

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
          color: onPressed == null ? AppColors.muted.withValues(alpha: 0.4) : color ?? AppColors.blue,
        ),
      ),
    );
  }
}
