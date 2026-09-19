import 'dart:convert';

import 'package:flutter/material.dart';

import '../app/scope.dart';
import '../core/protocol/protocol.dart';
import '../data/backup_service.dart';

class GatewayManagementPage extends StatefulWidget {
  const GatewayManagementPage({super.key});

  @override
  State<GatewayManagementPage> createState() => _GatewayManagementPageState();
}

class _GatewayManagementPageState extends State<GatewayManagementPage> {
  bool _busy = false;
  String? _message;
  Map<String, Object?>? _config;
  final _fields = <GatewayField, TextEditingController>{
    for (final key in const [
      GatewayField.wifiSsid,
      GatewayField.wifiPassword,
      GatewayField.mqttUri,
      GatewayField.mqttUsername,
      GatewayField.mqttPassword,
      GatewayField.gatewayId,
    ])
      key: TextEditingController(),
  };
  bool _clearWifi = false;
  bool _clearMqtt = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run(_load));
  }

  @override
  void dispose() {
    for (final f in _fields.values) {
      f.dispose();
    }
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy || !mounted) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _message = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load() async {
    final registry = AppScope.controller.deviceRegistry;
    await registry.execute(GatewayManageAction.diagnostics);
    final config = await registry.execute(GatewayManageAction.configGet);
    if (!mounted) return;
    _config = config;
    for (final entry in _fields.entries) {
      entry.value.text = '${config[entry.key.wire] ?? ''}';
    }
  }

  Future<bool> _confirm(String title, String text) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(text),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('确认')),
          ],
        ),
      ) ==
      true;

  Future<void> _saveNetwork() async {
    if (!await _confirm('保存网关网络配置并重启', 'ESP32 将使用下方的新网络配置。修改服务器或网关标识后，需要同步修改 App 的 MQTT 配置才能重新连接。') || !mounted) {
      return;
    }
    await _run(() async {
      await AppScope.controller.deviceRegistry.execute(
        GatewayManageAction.configSet,
        {
          GatewayField.config: {
            for (final entry in _fields.entries) entry.key.wire: entry.value.text,
            GatewayField.keepWifiPassword.wire:
                _fields[GatewayField.wifiPassword]!.text.isEmpty && !_clearWifi,
            GatewayField.keepMqttPassword.wire:
                _fields[GatewayField.mqttPassword]!.text.isEmpty && !_clearMqtt,
            GatewayField.clearWifiPassword.wire: _clearWifi,
            GatewayField.clearMqttPassword.wire: _clearMqtt,
          },
        },
      );
      _fields[GatewayField.wifiPassword]!.clear();
      _fields[GatewayField.mqttPassword]!.clear();
      _message = '网络配置已保存，ESP32 正在重启';
    });
  }

  Future<void> _import() async {
    final source = await BackupService().pickJson();
    if (source == null || !mounted) return;
    final value = jsonDecode(source);
    if (value is! Map<String, dynamic> ||
        value[GatewayField.version.wire] != 1 ||
        value[GatewayField.devices.wire] is! List) {
      throw const FormatException('不是有效的网关设备备份');
    }
    if (!await _confirm('替换全部登记', '将使用备份中的 ${(value[GatewayField.devices.wire] as List).length} 台设备替换 ESP32 的全部登记，然后重启。') || !mounted) {
      return;
    }
    await AppScope.controller.deviceRegistry.execute(
      GatewayManageAction.save,
      {GatewayField.registry: value},
    );
    _message = '设备登记已导入，ESP32 正在重启';
  }

  @override
  Widget build(BuildContext context) {
    final registry = AppScope.controller.deviceRegistry;
    final gateway = AppScope.controller.mqttGateway;
    final ready = gateway.client.connected && gateway.client.gatewayOnline && !_busy;
    return Scaffold(
      appBar: AppBar(
        title: const Text('ESP32 管理'),
        actions: [IconButton(onPressed: ready ? () => _run(_load) : null, icon: const Icon(Icons.refresh))],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '网关 ${AppScope.controller.remoteSettings?.gatewayId ?? '未配置'}',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          Text(registry.snapshot.deviceOnline ? 'MQTT 在线' : 'MQTT 离线'),
          if (_busy) const LinearProgressIndicator(),
          if (_message != null)
            Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: SelectableText(_message!)),
          const SizedBox(height: 16),
          const Text('运行诊断', style: TextStyle(fontWeight: FontWeight.bold)),
          SelectableText(
            const JsonEncoder.withIndent('  ')
                .convert(registry.diagnostics ?? gateway.client.snapshot.capabilities ?? {}),
          ),
          const Divider(),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton(
                onPressed: ready
                    ? () => _run(() async {
                        final data = await registry.execute(
                          GatewayManageAction.backup,
                        );
                        if (!context.mounted) return;
                        final box = context.findRenderObject() as RenderBox?;
                        _message = await BackupService().exportJson(
                          const JsonEncoder.withIndent('  ').convert(data),
                          fileName: 'esp32-devices.json',
                          sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
                        );
                      })
                    : null,
                child: const Text('导出设备登记'),
              ),
              OutlinedButton(onPressed: ready ? () => _run(_import) : null, child: const Text('导入设备登记')),
              OutlinedButton(
                onPressed: ready
                    ? () async {
                        if (await _confirm('重启 ESP32', '所有 BLE 连接将暂时断开，网关上线后自动同步状态') && mounted) {
                          await _run(() async {
                            await registry.execute(GatewayManageAction.restart);
                            _message = 'ESP32 已接受重启请求';
                          });
                        }
                      }
                    : null,
                child: const Text('重启网关'),
              ),
            ],
          ),
          const Divider(),
          const Text('网关 Wi-Fi / MQTT 配置', style: TextStyle(fontWeight: FontWeight.bold)),
          const Text('密码留空表示保留已有密码'),
          if (_config != null) ...[
            for (final entry in _fields.entries)
              TextField(
                controller: entry.value,
                enabled: !_busy,
                obscureText: entry.key.wire.endsWith('Password'),
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: const {
                    GatewayField.wifiSsid: 'Wi-Fi 名称',
                    GatewayField.wifiPassword: 'Wi-Fi 新密码',
                    GatewayField.mqttUri: 'MQTT 地址（mqtt:// 或 mqtts://）',
                    GatewayField.mqttUsername: 'MQTT 用户名',
                    GatewayField.mqttPassword: 'MQTT 新密码',
                    GatewayField.gatewayId: '网关标识',
                  }[entry.key],
                ),
              ),
            CheckboxListTile(
              title: const Text('清空 Wi-Fi 密码'),
              value: _clearWifi,
              onChanged: _busy ? null : (v) => setState(() => _clearWifi = v!),
            ),
            CheckboxListTile(
              title: const Text('清空 MQTT 密码'),
              value: _clearMqtt,
              onChanged: _busy ? null : (v) => setState(() => _clearMqtt = v!),
            ),
            FilledButton(onPressed: ready ? _saveNetwork : null, child: const Text('保存网关配置并重启')),
          ],
        ],
      ),
    );
  }
}
