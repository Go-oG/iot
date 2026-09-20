import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../app/scope.dart';
import '../app/theme.dart';
import '../core/device/device_model_catalog.dart';
import '../core/device_model.dart';
import '../data/device_configuration.dart';
import '../widgets/app_widgets.dart';

/// 设备模型编辑页：直接编辑 [DeviceModel] 的 JSON
///
/// 保存前的校验完全由模型解析完成，界面不重复实现一套规则。
class DeviceModelConfigPage extends StatefulWidget {
  const DeviceModelConfigPage({this.deviceId, super.key});

  /// 为空表示新建
  final String? deviceId;

  @override
  State<DeviceModelConfigPage> createState() => _DeviceModelConfigPageState();
}

class _DeviceModelConfigPageState extends State<DeviceModelConfigPage> {
  late final TextEditingController _source = TextEditingController(
    text: _initialSource(),
  );
  String? _error;
  String? _message;

  String _initialSource() {
    final id = widget.deviceId;
    if (id != null) {
      final config = AppScope.controller.deviceConfigurations
          .where((item) => item.id == id)
          .firstOrNull;
      if (config != null) return config.toJsonString();
    }
    return const JsonEncoder.withIndent(
      '  ',
    ).convert(DeviceModelCatalog.instance.defaultModel.toJson());
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
      final configuration = DeviceConfiguration.fromJson(
        decoded.map((key, value) => MapEntry(key.toString(), value)),
      );
      controller.saveDeviceConfiguration(
        configuration,
        previousId: widget.deviceId,
      );
      setState(() => _message = '已保存 ${configuration.name}');
    } catch (error) {
      setState(() => _error = '$error');
      return;
    }
    if (mounted && widget.deviceId == null) {
      // 新建后回到设备列表，避免同一页面被重复保存成两台设备
      context.go('/devices');
    }
  }

  void _delete() {
    final id = widget.deviceId;
    if (id == null) return;
    AppScope.controller.deleteDeviceConfiguration(id);
    context.go('/devices');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.deviceId == null ? '新建设备模型' : '编辑设备模型'),
        actions: [
          if (widget.deviceId != null)
            IconButton(
              tooltip: '删除模型',
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
              '设备模型描述属性、读写通知操作、请求帧字段、长度与校验，以及响应匹配；'
              '保存后立即用于通用控制页。',
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
              labelText: '设备模型 JSON',
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
              child: Text(message, style: const TextStyle(color: AppColors.green)),
            ),
          const SizedBox(height: 16),
          Row(
            children: [
              FilledButton(onPressed: _save, child: const Text('校验并保存')),
              const SizedBox(width: 12),
              OutlinedButton(
                onPressed: () => setState(() {
                  _source.text = const JsonEncoder.withIndent(
                    '  ',
                  ).convert(DeviceModelCatalog.instance.defaultModel.toJson());
                  _error = null;
                  _message = null;
                }),
                child: const Text('载入 AT5 模板'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
