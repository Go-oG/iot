import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:light/src/app/scope.dart';

import '../app/theme.dart';
import '../core/protocol/protocol.dart';
import '../data/remote_settings.dart';
import '../shared/app_widgets.dart';

class MqttSettingsPage extends StatefulWidget {
  const MqttSettingsPage({super.key});

  @override
  State<MqttSettingsPage> createState() => _MqttSettingsPageState();
}

class _MqttSettingsPageState extends State<MqttSettingsPage> {
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _device;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late bool _tls;
  late bool _enabled;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final saved = AppScope.controller.remoteSettings;
    _host = TextEditingController(text: saved?.host ?? '');
    _port = TextEditingController(text: '${saved?.port ?? 8883}');
    _device = TextEditingController(text: saved?.gatewayId ?? '');
    _username = TextEditingController(text: saved?.username ?? '');
    _password = TextEditingController(text: saved?.password ?? '');
    _tls = saved?.tls ?? true;
    _enabled = saved?.enabled ?? true;
  }

  @override
  void dispose() {
    for (final field in [_host, _port, _device, _username, _password]) {
      field.dispose();
    }
    super.dispose();
  }

  /// 网关标识合法时展示推导出的主题，便于与固件里的配置逐字对照
  String? get _topicPreview {
    final id = _device.text.trim();
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,64}$').hasMatch(id)) return null;
    final topics = GatewayTopics(id);
    return '订阅 ${topics.up}\n订阅 ${topics.presence}\n发布 ${topics.down}';
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('MQTT 配置'),
          actions: [
            TextButton(
              onPressed: _saving || AppScope.controller.remoteSettings == null
                  ? null
                  : () => context.push('/mqtt-debug'),
              child: const Text('消息调试'),
            ),
          ],
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: SurfaceCard(
                  child: Material(
                    type: MaterialType.transparency,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('启用远程控制'),
                          value: _enabled,
                          onChanged: _saving ? null : (v) => setState(() => _enabled = v),
                        ),
                        TextField(
                          enabled: !_saving,
                          controller: _host,
                          decoration: const InputDecoration(labelText: '服务器地址', hintText: 'mqtt.example.com'),
                          autocorrect: false,
                          enableSuggestions: false,
                        ),
                        TextField(
                          enabled: !_saving,
                          controller: _port,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: '端口'),
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('TLS 加密连接'),
                          subtitle: Text(_tls ? '校验服务器证书' : '明文连接，仅用于本地测试'),
                          value: _tls,
                          onChanged: _saving
                              ? null
                              : (v) => setState(() {
                                  _tls = v;
                                  if (_port.text == '1883' || _port.text == '8883') {
                                    _port.text = v ? '8883' : '1883';
                                  }
                                }),
                        ),
                        TextField(
                          enabled: !_saving,
                          controller: _device,
                          onChanged: (_) => setState(() {}),
                          decoration: const InputDecoration(
                            labelText: '网关标识（Gateway ID）',
                            hintText: 'gw-001',
                            helperText: '决定 App 收发的 MQTT 主题，必须与网关固件里填写的完全一致',
                          ),
                          autocorrect: false,
                          enableSuggestions: false,
                        ),
                        if (_topicPreview != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              _topicPreview!,
                              style: const TextStyle(fontSize: 11, color: AppColors.muted, fontFamily: 'monospace'),
                            ),
                          ),
                        TextField(
                          enabled: !_saving,
                          controller: _username,
                          decoration: const InputDecoration(labelText: 'MQTT 用户名'),
                          autocorrect: false,
                        ),
                        TextField(
                          enabled: !_saving,
                          controller: _password,
                          decoration: const InputDecoration(labelText: 'MQTT 密码'),
                          obscureText: true,
                          autocorrect: false,
                          enableSuggestions: false,
                        ),
                        const SizedBox(height: 16),
                        const Text('所有设备管理和控制均经 MQTT 网关执行，请在设备页扫描并登记设备。'),
                        const Text('连接信息保存在本机安全存储中，不随配色备份导出。'),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        bottomNavigationBar: SafeArea(
          minimum: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: Text(_saving ? '保存中…' : (_enabled ? '保存并连接' : '保存配置')),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final settings = RemoteSettings(
        host: _host.text.trim(),
        port: int.tryParse(_port.text) ?? 0,
        tls: _tls,
        gatewayId: _device.text.trim(),
        username: _username.text.trim(),
        password: _password.text,
        enabled: _enabled,
        bluetoothDeviceId: AppScope.controller.remoteSettings?.gatewayId == _device.text.trim()
            ? AppScope.controller.remoteSettings!.bluetoothDeviceId
            : '',
      );
      settings.validate();
      await AppScope.controller.saveRemoteSettings(settings);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(settings.enabled ? '配置已保存，正在连接服务器' : '配置已保存，远程控制已停用')));
      }
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = '保存失败，请等待当前操作完成后重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
