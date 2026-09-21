import 'dart:convert';

import 'package:flutter/material.dart';

import '../app/router.dart';
import '../app/scope.dart';
import '../app/theme.dart';
import '../core/device/device.dart';
import '../data/device_template.dart';
import '../widgets/app_widgets.dart';

/// 协议模板编辑页：直接编辑 [Device] 的 JSON
///
/// 保存前的校验完全由模型解析完成，界面不重复实现一套规则
class DeviceConfigPage extends StatefulWidget {
  const DeviceConfigPage({this.modelId, super.key});

  /// 为空表示新建协议模板
  final String? modelId;

  @override
  State<DeviceConfigPage> createState() => _DeviceConfigPageState();
}

class _DeviceConfigPageState extends State<DeviceConfigPage> {
  late final _source = TextEditingController(text: _initialSource());
  String? _error;
  String? _message;

  String _initialSource() {
    final id = widget.modelId;
    if (id != null) {
      final template = AppScope.controller.templateFor(id);
      if (template != null) return template.toJsonString();
    }
    return const JsonEncoder.withIndent(' ')
        .convert(Device.defaultDefinition.toJson());
  }

  @override
  void dispose() {
    _source.dispose();
    super.dispose();
  }

  void _save() {
    final controller = AppScope.controller;
    setState(() {
      _error = null;
      _message = null;
    });
    try {
      final decoded = jsonDecode(_source.text);
      if (decoded is! Map) {
        throw const FormatException('设备模型必须是 JSON 对象');
      }
      final template = DeviceTemplate.fromJson(
        decoded.map((key, value) => MapEntry(key.toString(), value)),
      );
      controller.saveDeviceTemplate(template, previousId: widget.modelId);
      setState(() => _message = '已保存 ${template.name}');
    } catch (error) {
      setState(() => _error = '$error');
      return;
    }
    if (mounted && widget.modelId == null) {
      // 新建后回到设备列表，避免同一页面被重复保存成两台设备
      context.goDevices();
    }
  }

  void _delete() {
    final id = widget.modelId;
    if (id == null) return;
    try {
      AppScope.controller.deleteDeviceTemplate(id);
      context.goDevices();
    } catch (error) {
      setState(() => _error = '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.modelId == null ? '新建协议模板' : '编辑协议模板'),
        actions: [
          if (widget.modelId != null &&
              AppScope.controller.deviceTemplates.any(
                (item) => item.id == widget.modelId,
              ))
            IconButton(
              tooltip: '删除模板',
              onPressed: _delete,
              icon: const Icon(Icons.delete_outline_rounded),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const SurfaceCard(
            child: Text(
              '协议模板描述属性、读写通知操作、请求帧字段、长度与校验，以及响应匹配；'
              '同一模板可以绑定多台真实设备。',
              style: TextStyle(fontSize: 12, color: AppColors.muted),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _source,
            minLines: 16,
            maxLines: 30,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            decoration: const InputDecoration(
              labelText: '协议模板 JSON',
              border: OutlineInputBorder(),
            ),
          ),
          if (_error case final String error)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(error, style: const TextStyle(color: AppColors.red)),
            ),
          if (_message case final String message)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                message,
                style: const TextStyle(color: AppColors.green),
              ),
            ),
          const SizedBox(height: 16),
          Row(
            children: [
              FilledButton(onPressed: _save, child: const Text('校验并保存')),
              const SizedBox(width: 12),
              OutlinedButton(
                onPressed: () => setState(() {
                  _source.text = const JsonEncoder.withIndent(' ')
                      .convert(Device.defaultDefinition.toJson());
                  _error = null;
                  _message = null;
                }),
                child: const Text('载入AT5 模板'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
