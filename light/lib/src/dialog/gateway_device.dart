import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/protocol/protocol.dart';

Future<Map<String, Object?>?> showGatewayDeviceEditor(
  BuildContext context, {
  Map<String, Object?>? device,
  Map<String, Object?>? seen,
}) async {
  final name = TextEditingController(
    text: '${device?[GatewayField.alias.wire] ?? seen?[GatewayField.name.wire] ?? 'BLE 设备'}',
  );
  final mac = TextEditingController(
    text: '${device?[GatewayField.device.wire] ?? seen?[GatewayField.mac.wire] ?? ''}',
  );
  final min = TextEditingController(
    text: '${device?[GatewayField.intervalMinMs.wire] ?? 100}',
  );
  final max = TextEditingController(
    text: '${device?[GatewayField.intervalMaxMs.wire] ?? 200}',
  );
  final subscriptions = TextEditingController(
    text: const JsonEncoder.withIndent('  ')
        .convert(device?[GatewayField.subscriptions.wire] ?? []),
  );
  var enabled = device?[GatewayField.enabled.wire] != false;
  var random =
      GatewayAddressType.fromJson(device?[GatewayField.addressType.wire]) ==
          GatewayAddressType.random ||
      (device == null &&
          GatewayAddressType.valueOf(seen?[GatewayField.addrType.wire]) ==
              GatewayAddressType.random);
  var broadcast =
      GatewayDeviceMode.valueOf(device?[GatewayField.mode.wire]) ==
      GatewayDeviceMode.broadcast;
  var stream =
      GatewayDelivery.valueOf(device?[GatewayField.reportMode.wire]) ==
      GatewayDelivery.stream;
  String? error;
  final result = await showDialog<Map<String, Object?>>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(device == null ? '登记 BLE 设备' : '编辑登记'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: '名称（最多 48 字节）'),
                ),
                TextField(
                  controller: mac,
                  enabled: device == null,
                  decoration: const InputDecoration(labelText: 'BLE MAC 地址'),
                ),
                SwitchListTile(
                  title: const Text('随机地址'),
                  value: random,
                  onChanged: (v) => setState(() => random = v),
                ),
                SwitchListTile(
                  title: const Text('启用'),
                  value: enabled,
                  onChanged: (v) => setState(() => enabled = v),
                ),
                SwitchListTile(
                  title: const Text('仅监听广播'),
                  value: broadcast,
                  onChanged: (v) => setState(() => broadcast = v),
                ),
                SwitchListTile(
                  title: const Text('逐条转发通知（stream）'),
                  value: stream,
                  onChanged: (v) => setState(() => stream = v),
                ),
                if (!broadcast) ...[
                  TextField(
                    controller: min,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '最小连接间隔 ms'),
                  ),
                  TextField(
                    controller: max,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '最大连接间隔 ms'),
                  ),
                  TextField(
                    controller: subscriptions,
                    maxLines: 5,
                    decoration: const InputDecoration(
                      labelText: '自动订阅 JSON（最多四条）',
                      helperMaxLines: 3,
                      helperText: '[{"service":"180f","characteristic":"2a19","indicate":false}]',
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                const Text('保存后 ESP32 将重启，现有设备会短暂断线'),
                if (error != null)
                  Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              try {
                if (!RegExp(r'^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$')
                    .hasMatch(mac.text.trim())) {
                  throw const FormatException('MAC 地址格式不正确');
                }
                if (name.text.trim().isEmpty ||
                    utf8.encode(name.text.trim()).length > 48) {
                  throw const FormatException('名称须为 1–48 字节');
                }
                final low = int.tryParse(min.text),
                    high = int.tryParse(max.text);
                if (low == null ||
                    high == null ||
                    low < 15 ||
                    high > 4000 ||
                    low > high ||
                    low % 5 != 0 ||
                    high % 5 != 0) {
                  throw const FormatException(
                    '连接间隔为 15–4000 ms 的 5 ms 倍数，最小值不能大于最大值',
                  );
                }
                final subs = broadcast ? [] : jsonDecode(subscriptions.text);
                if (subs is! List ||
                    subs.length > 4 ||
                    subs.any((v) => v is! Map)) {
                  throw const FormatException('订阅必须是最多四个对象的数组');
                }
                final addressType = random
                    ? GatewayAddressType.random
                    : GatewayAddressType.public;
                Navigator.pop(context, <String, Object?>{
                  if (device?[GatewayField.deviceId.wire] != null ||
                      seen?[GatewayField.deviceId.wire] != null)
                    GatewayField.deviceId.wire: device?[GatewayField.deviceId.wire] ??
                        seen?[GatewayField.deviceId.wire],
                  if (device?[GatewayField.deviceUuid.wire] != null ||
                      seen?[GatewayField.deviceUuid.wire] != null)
                    GatewayField.deviceUuid.wire:
                        device?[GatewayField.deviceUuid.wire] ??
                            seen?[GatewayField.deviceUuid.wire],
                  GatewayField.device.wire: mac.text.trim().toUpperCase(),
                  GatewayField.alias.wire: name.text.trim(),
                  GatewayField.addressType.wire: addressType.code,
                  GatewayField.enabled.wire: enabled,
                  GatewayField.mode.wire: broadcast
                      ? GatewayDeviceMode.broadcast.wire
                      : GatewayDeviceMode.connection.wire,
                  GatewayField.intervalMinMs.wire: low,
                  GatewayField.intervalMaxMs.wire: high,
                  GatewayField.reportMode.wire: stream
                      ? GatewayDelivery.stream.wire
                      : GatewayDelivery.latest.wire,
                  GatewayField.subscriptions.wire: subs,
                });
              } catch (e) {
                setState(() => error = '$e');
              }
            },
            child: const Text('保存并重启'),
          ),
        ],
      ),
    ),
  );
  // 等待关闭动画结束后释放输入控制器
  await Future<void>.delayed(const Duration(milliseconds: 300));
  for (final field in [name, mac, min, max, subscriptions]) {
    field.dispose();
  }
  return result;
}
