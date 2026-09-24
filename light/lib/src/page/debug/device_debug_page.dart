import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:light/src/core/protocol/model.dart';

import '../../app/scope.dart';
import '../../core/protocol/protocol.dart';

class DeviceDebugPage extends StatefulWidget {
  const DeviceDebugPage({required this.deviceId, super.key});

  final String deviceId;

  @override
  State<DeviceDebugPage> createState() => _DeviceDebugPageState();
}

class _DeviceDebugPageState extends State<DeviceDebugPage> {
  final _service = TextEditingController();
  final _characteristic = TextEditingController();
  final _value = TextEditingController();
  final List<String> _log = [];
  StreamSubscription<GatewayEvent>? _events;
  ValueFormat _format = ValueFormat.hex;
  bool _busy = false;
  bool _withoutResponse = false;
  GatewayNotifyMode _mode = GatewayNotifyMode.auto;
  GatewayDelivery _delivery = GatewayDelivery.stream;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _events ??= AppScope.controller.mqttGateway.events.listen((event) {
      if (event.deviceId == widget.deviceId && mounted) {
        _add(jsonEncode(event.message.toJson()));
      }
    });
  }

  void _add(String text) {
    setState(() {
      _log.insert(0, text);
      if (_log.length > 100) _log.removeLast();
    });
  }

  Future<void> _request(GatewayOption op, {bool enabled = true}) async {
    setState(() => _busy = true);
    try {
      final gateway = AppScope.controller.mqttGateway;
      GatewayUuid.normalize(_service.text);
      GatewayUuid.normalize(_characteristic.text);
      if (op == GatewayOption.write) ValueFormat.decode(_value.text, _format);
      final response = await gateway.checked(
        op,
        deviceId: widget.deviceId,
        service: _service.text.trim(),
        characteristic: _characteristic.text.trim(),
        value: op == GatewayOption.write ? _value.text : null,
        format: op == GatewayOption.write ? _format : null,
        data: op == GatewayOption.subscribe
            ? {
                GatewayField.enabled.wire: enabled,
                GatewayField.mode.wire: _mode.wire,
                GatewayField.delivery.wire: _delivery.wire,
              }
            : op == GatewayOption.write
            ? {
                GatewayField.writeType.wire: _withoutResponse
                    ? GatewayWriteType.withoutResponse.wire
                    : GatewayWriteType.withResponse.wire,
              }
            : null,
      );
      if (mounted) _add(jsonEncode(response.toJson()));
    } catch (error) {
      if (mounted) _add('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _events?.cancel();
    _service.dispose();
    _characteristic.dispose();
    _value.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.controller.gatewayState;
    final ready = state.connected && state.gatewayOnline && !_busy;
    final cached = state.deviceOf(widget.deviceId)?.characteristics ?? {};
    return Scaffold(
      appBar: AppBar(title: const Text('MQTT 设备读写')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SelectableText(widget.deviceId),
          const Text('填写设备实际支持的服务和特征 UUID；下方可选择已缓存特征'),
          for (final entry in cached.entries)
            ListTile(
              title: Text(entry.key),
              subtitle: Text(entry.value.value),
              onTap: () {
                final pair = entry.key.split('/');
                _service.text = pair[0];
                _characteristic.text = pair[1];
              },
            ),
          TextField(
            controller: _service,
            decoration: const InputDecoration(labelText: 'Service UUID'),
          ),
          TextField(
            controller: _characteristic,
            decoration: const InputDecoration(labelText: 'Characteristic UUID'),
          ),
          DropdownButtonFormField<ValueFormat>(
            initialValue: _format,
            items: [for (final f in ValueFormat.values) DropdownMenuItem(value: f, child: Text(f.wire))],
            onChanged: (v) => setState(() => _format = v!),
            decoration: const InputDecoration(labelText: '编码'),
          ),
          TextField(
            controller: _value,
            decoration: const InputDecoration(labelText: '写入值'),
          ),
          SwitchListTile(
            title: const Text('无响应写入'),
            value: _withoutResponse,
            onChanged: (v) => setState(() => _withoutResponse = v),
          ),
          DropdownButtonFormField<GatewayNotifyMode>(
            initialValue: _mode,
            items: [
              for (final mode in GatewayNotifyMode.values)
                DropdownMenuItem(value: mode, child: Text(mode.wire)),
            ],
            onChanged: (v) => setState(() => _mode = v!),
            decoration: const InputDecoration(labelText: '通知模式'),
          ),
          DropdownButtonFormField<GatewayDelivery>(
            initialValue: _delivery,
            items: [
              for (final delivery in GatewayDelivery.values)
                DropdownMenuItem(value: delivery, child: Text(delivery.wire)),
            ],
            onChanged: (v) => setState(() => _delivery = v!),
            decoration: const InputDecoration(labelText: '传递模式'),
          ),
          Wrap(
            spacing: 8,
            children: [
              FilledButton(onPressed: ready ? () => _request(GatewayOption.read) : null, child: const Text('读取')),
              FilledButton(onPressed: ready ? () => _request(GatewayOption.write) : null, child: const Text('写入')),
              OutlinedButton(
                onPressed: ready ? () => _request(GatewayOption.subscribe) : null,
                child: const Text('订阅'),
              ),
              OutlinedButton(
                onPressed: ready ? () => _request(GatewayOption.subscribe, enabled: false) : null,
                child: const Text('取消订阅'),
              ),
            ],
          ),
          if (_busy) const LinearProgressIndicator(),
          const Divider(),
          for (final line in _log)
            Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: SelectableText(line)),
        ],
      ),
    );
  }
}
