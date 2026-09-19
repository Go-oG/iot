import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../app/controller.dart';
import '../app/scope.dart';
import '../app/theme.dart';
import '../core/device/device.dart';
import '../core/device_registry.dart';
import '../core/functions/base.dart';
import '../core/functions/light.dart';
import '../core/functions/power.dart';
import '../core/functions/timer.dart';
import '../core/protocol/client.dart';
import '../core/protocol/protocol.dart';
import '../core/remote_gateway.dart';
import '../data/models.dart';
import '../dialog/scene.dart';
import '../widgets/app_widgets.dart';

/// 设备详情：只展示一台设备的控制面板，未选中时先把该设备设为控制对象
class DeviceDetailPage extends StatefulWidget {
  const DeviceDetailPage({required this.deviceId, super.key});

  final String deviceId;

  @override
  State<DeviceDetailPage> createState() => _DeviceDetailPageState();
}

class _DeviceDetailPageState extends State<DeviceDetailPage> {
  StreamSubscription<GatewayClientSnapshot>? _subscription;
  StreamSubscription<GatewayEvent>? _events;
  bool _online = false;
  bool _pending = false;
  String? _actionError;

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
      // 拉取失败时保留已有信息，卡片上的状态标记会提示离线
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_pending || !mounted) return;
    setState(() {
      _pending = true;
      _actionError = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _actionError = '$error');
    } finally {
      if (mounted) setState(() => _pending = false);
    }
  }

  SavedDevice? get _saved => AppScope.controller.savedDevices.where((item) => item.id == widget.deviceId).firstOrNull;

  Map<String, Object?>? get _runtime => registry.stateOf(widget.deviceId);

  String get _deviceName {
    final saved = _saved;
    if (saved != null && saved.name.trim().isNotEmpty) return saved.name.trim();
    final remote = gateway.client.device(widget.deviceId)?.name;
    if (remote != null && remote.trim().isNotEmpty) return remote.trim();
    final alias = _runtime?[GatewayField.alias.wire];
    if (alias is String && alias.trim().isNotEmpty) return alias.trim();
    return widget.deviceId;
  }

  bool get _selected => AppScope.controller.selectedDeviceId == widget.deviceId;

  bool get _connected => gateway.client.device(widget.deviceId)?.connected == true && registry.snapshot.deviceOnline;

  bool get _knownProtocol => _runtime?[GatewayField.protocolOwned.wire] == true;

  bool get _paused => _runtime?[GatewayField.paused.wire] == true;

  bool get _ready => gateway.client.connected && gateway.client.gatewayOnline && !_pending;

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.controller;
    final device = controller.deviceCardFor(widget.deviceId);
    final supportsLight = device.function<LightFunction>() != null;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_deviceName, overflow: TextOverflow.ellipsis),
            Row(
              children: [
                StatusPill(label: _connected ? '已连接' : '未连接', color: _connected ? AppColors.green : AppColors.muted),
                if (controller.selectedDeviceId == widget.deviceId) ...[
                  const SizedBox(width: 6),
                  const StatusPill(label: '当前控制', color: AppColors.blue),
                ],
              ],
            ),
          ],
        ),
        actions: [
          IconButton(onPressed: _ready ? () => _run(_load) : null, icon: const Icon(Icons.refresh), tooltip: '同步网关'),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(top: 12, bottom: 24),
        children: [
          if (_pending) const LinearProgressIndicator(),
          if (_actionError != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(_actionError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          if (!_selected) _switchCard(controller),
          if (_selected && !_connected) _connectCard(),
          // 未切换控制前，卡片只是预览，触碰不应改变任何设备的设置
          IgnorePointer(
            ignoring: !_selected,
            child: Opacity(
              opacity: _selected ? 1 : 0.55,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: DeviceControlScope(
                  bindings: controller.controlBindings,
                  child: Builder(builder: (context) => device.buildDeviceCart(context, CardSize.large)),
                ),
              ),
            ),
          ),
          if (_selected) ...[
            if (supportsLight) ...[
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: SectionTitle(
                  '快捷配色',
                  trailing: TextButton(onPressed: () => context.push('/profile'), child: const Text('管理配色')),
                ),
              ),
              if (controller.scenes.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                  child: Text('暂无配色，可保存当前调色或到配色页新增方案', style: TextStyle(color: AppColors.muted)),
                ),
              const SizedBox(height: 8),
              SizedBox(
                height: 104,
                child: ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  scrollDirection: Axis.horizontal,
                  itemCount: controller.scenes.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (context, index) {
                    final scene = controller.scenes[index];
                    return InkWell(
                      onTap: () => controller.applyScene(scene),
                      borderRadius: BorderRadius.circular(13),
                      child: Container(
                        width: 104,
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(13),
                          border: Border.all(color: AppColors.line),
                        ),
                        child: Column(
                          children: [
                            SceneArtwork(accent: Color(scene.accentValue), height: 66),
                            Expanded(
                              child: Center(
                                child: Text(
                                  scene.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  if (device.function<TimerFunction>() != null)
                    Expanded(
                      child: _QuickButton(
                        label: '定时设置',
                        icon: Icons.push_pin_outlined,
                        color: AppColors.blue,
                        onTap: () => context.go('/plans'),
                      ),
                    ),
                  if (device.function<TimerFunction>() != null && device.function<PowerFunction>() != null)
                    const SizedBox(width: 8),
                  if (device.function<PowerFunction>() != null)
                    Expanded(
                      child: _QuickButton(
                        label: '一键全关',
                        icon: Icons.power_settings_new_rounded,
                        color: AppColors.red,
                        onTap: controller.powerEnabled ? controller.togglePower : () {},
                      ),
                    ),
                  if (supportsLight && device.function<PowerFunction>() != null) const SizedBox(width: 8),
                  if (supportsLight)
                    Expanded(
                      child: _QuickButton(
                        label: '保存当前配色',
                        icon: Icons.add_to_photos_outlined,
                        color: AppColors.blue,
                        onTap: () async {
                          final result = await showSceneEditor(
                            context,
                            newId: controller.createSceneId(),
                            initialState: controller.lightState,
                          );
                          if (result != null) controller.saveScene(result);
                        },
                      ),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 18),
          _deviceActions(),
        ],
      ),
    );
  }

  Widget _switchCard(AppController controller) {
    final remote = controller.remoteSettings;
    final needsConfig = remote == null || !remote.enabled;
    final busy = controller.applying || _pending;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: SurfaceCard(
        color: AppColors.paleBlue,
        borderColor: AppColors.blue,
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('当前没有控制这台设备', style: TextStyle(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                  Text(
                    needsConfig ? '需要先在“我的 · 连接设置”里配置 MQTT 远程控制' : '切换后控制面板会指向这台设备，原来的设备仍然连接在网关上',
                    style: const TextStyle(fontSize: 12, color: AppColors.muted),
                  ),
                ],
              ),
            ),
            FilledButton(onPressed: busy || needsConfig ? null : () => _switch(controller), child: const Text('切换控制')),
          ],
        ),
      ),
    );
  }

  Widget _connectCard() {
    final runtime = _runtime;
    final offline = !registry.snapshot.deviceOnline;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: SurfaceCard(
        color: AppColors.paleBlue,
        borderColor: AppColors.blue,
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(offline ? '网关离线' : '灯具未连接', style: const TextStyle(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                  Text(
                    offline
                        ? '网关上线后可在这里建立 BLE 连接'
                        : '网关状态：${GatewayStatus.valueOf(runtime?[GatewayField.state.wire])?.label ?? '未知'}，'
                              '点击连接后由网关发起 BLE 连接',
                    style: const TextStyle(fontSize: 12, color: AppColors.muted),
                  ),
                ],
              ),
            ),
            FilledButton(onPressed: _ready && !offline ? _connect : null, child: const Text('连接')),
          ],
        ),
      ),
    );
  }

  Widget _deviceActions() {
    final runtime = _runtime;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: SurfaceCard(
        padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
        child: Column(
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.terminal_rounded, color: AppColors.blue),
              title: const Text('读写 / 通知'),
              subtitle: const Text('查看特征值，手动读写或订阅通知'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: _ready ? () => context.push('/device-debug/${Uri.encodeComponent(widget.deviceId)}') : null,
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.tune_rounded, color: AppColors.blue),
              title: const Text('设备功能配置'),
              subtitle: const Text('编辑读写命令与编码方式'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => context.push('/device-functions?deviceId=${Uri.encodeComponent(widget.deviceId)}'),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                runtime?[GatewayField.paused.wire] == true
                    ? Icons.play_circle_outline_rounded
                    : Icons.pause_circle_outline_rounded,
                color: AppColors.blue,
              ),
              title: Text(runtime?[GatewayField.paused.wire] == true ? '恢复自动连接' : '暂停自动连接'),
              subtitle: Text(_knownProtocol ? '协议已接管该设备，请使用上方的连接按钮' : '暂停后网关不再自动重连这台设备'),
              onTap: _ready && !_knownProtocol ? _togglePause : null,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: Icon(Icons.link_rounded, color: _connected ? AppColors.blue : AppColors.muted),
              title: Text(_connected ? '断开 BLE 连接' : '建立 BLE 连接'),
              value: _connected,
              onChanged: _ready && registry.snapshot.deviceOnline ? (value) => _toggleConnection(value) : null,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _switch(AppController controller) async {
    await _run(() async {
      await controller.selectDevice(widget.deviceId, _deviceName, model: _saved?.model ?? DeviceModel.at5);
      if (!_connected) await _connect();
    });
  }

  Future<void> _connect() async {
    if (!_connected) await registry.connectDevice(widget.deviceId);
    await _load();
  }

  Future<void> _toggleConnection(bool connect) {
    return _run(() async {
      if (connect) {
        await _connect();
        return;
      }
      await registry.disconnectDevice(widget.deviceId);
      await _load();
    });
  }

  Future<void> _togglePause() {
    return _run(() async {
      await registry.execute(_paused ? GatewayManageAction.resume : GatewayManageAction.pause, {
        GatewayField.device: widget.deviceId,
      });
      await _load();
    });
  }
}

class _QuickButton extends StatelessWidget {
  const _QuickButton({required this.label, required this.icon, required this.color, required this.onTap});

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        backgroundColor: Colors.white,
        foregroundColor: color,
        side: const BorderSide(color: AppColors.line),
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 10),
        textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
      ),
      icon: Icon(icon, size: 16),
      label: Text(label),
    );
  }
}
