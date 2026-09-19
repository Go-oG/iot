import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:light/src/core/device/generic_codec.dart';
import 'package:light/src/core/device/impl/generic_device.dart';

import '../app/theme.dart';
import '../core/device/device.dart';
import '../core/device/function_type.dart';
import '../core/functions/fan_speed.dart';
import '../core/functions/timer.dart';
import '../data/backup_service.dart';
import '../data/device_configuration.dart';
import '../dialog/device_function.dart';
import '../widgets/app_widgets.dart';

class DeviceFunctionsPage extends StatefulWidget {
  const DeviceFunctionsPage({
    required this.initialConfiguration,
    required this.onSave,
    this.existingConfigurationId,
    this.backupService,
    super.key,
  });

  final DeviceConfiguration initialConfiguration;
  final String? existingConfigurationId;
  final FutureOr<void> Function(
    DeviceConfiguration configuration,
    String? previousId,
  )
  onSave;
  final BackupService? backupService;

  @override
  State<DeviceFunctionsPage> createState() => _DeviceFunctionsPageState();
}

class _DeviceFunctionsPageState extends State<DeviceFunctionsPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _id = TextEditingController(
    text: widget.initialConfiguration.id,
  );
  late final TextEditingController _name = TextEditingController(
    text: widget.initialConfiguration.name,
  );
  late final TextEditingController _macd = TextEditingController(
    text: widget.initialConfiguration.macd,
  );
  late final BackupService _files = widget.backupService ?? BackupService();
  late List<Map<String, Object?>> _functions =
      widget.initialConfiguration.functions;
  late List<Object?> _services =
      widget.initialConfiguration.toJson()['bleServices'] as List<Object?>;
  late String? _savedId = widget.existingConfigurationId;
  late Device _preview = GenericDevice.fromJson(
    widget.initialConfiguration.toJson(),
  );
  bool _dirty = false;
  bool _busy = false;
  bool _allowPop = false;
  int _tab = 0;

  @override
  void dispose() {
    _id.dispose();
    _name.dispose();
    _macd.dispose();
    _preview.dispose();
    super.dispose();
  }

  Map<String, Object?> get _json => {
    'id': _id.text.trim(),
    'name': _name.text.trim(),
    'macd': _macd.text.trim().isEmpty ? _id.text.trim() : _macd.text.trim(),
    'bleServices': _services,
    'functions': _functions,
  };

  DeviceConfiguration _configuration() => DeviceConfiguration.fromJson(_json);

  void _changed() {
    setState(() => _dirty = true);
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  void _selectTab(int tab) {
    if (tab == 1) {
      try {
        final next = GenericDevice.fromJson(_configuration().toJson());
        _preview.dispose();
        _preview = next;
      } catch (error) {
        _message('请先完善设备信息：$error');
        return;
      }
    }
    setState(() => _tab = tab);
  }

  void _applyImport(DeviceConfiguration configuration) {
    _id.text = configuration.id;
    _name.text = configuration.name;
    _macd.text = configuration.macd;
    setState(() {
      _functions = configuration.functions;
      _services = configuration.toJson()['bleServices'] as List<Object?>;
      _tab = 0;
      _dirty = true;
    });
    _message('配置已载入草稿，点击保存保留到本机');
  }

  Future<void> _importFile() async {
    setState(() => _busy = true);
    try {
      final source = await _files.pickJson();
      if (source != null && mounted)
        _applyImport(DeviceConfiguration.fromJsonString(source));
    } catch (error) {
      _message('导入失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editJson({bool paste = false}) async {
    String source = '';
    if (!paste) {
      try {
        source = _configuration().toJsonString();
      } catch (error) {
        _message('请先完善设备信息：$error');
        return;
      }
    }
    final result = await showDialog<DeviceConfiguration>(
      context: context,
      builder: (_) =>
          _ConfigurationJsonDialog(initialSource: source, paste: paste),
    );
    if (result != null && mounted) _applyImport(result);
  }

  Future<void> _export(BuildContext buttonContext) async {
    if (!_formKey.currentState!.validate()) return;
    final box = buttonContext.findRenderObject() as RenderBox?;
    final origin = box == null
        ? null
        : box.localToGlobal(Offset.zero) & box.size;
    setState(() => _busy = true);
    try {
      final configuration = _configuration();
      final safeId = configuration.id.replaceAll(
        RegExp(r'[^a-zA-Z0-9_-]'),
        '_',
      );
      final result = await _files.exportJson(
        configuration.toJsonString(),
        fileName: 'device_$safeId.json',
        sharePositionOrigin: origin,
      );
      _message(result);
    } catch (error) {
      _message('导出失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) {
      _selectTab(0);
      return;
    }
    setState(() => _busy = true);
    try {
      final configuration = _configuration();
      await widget.onSave(configuration, _savedId);
      if (!mounted) return;
      setState(() {
        _savedId = configuration.id;
        _dirty = false;
      });
      _message('设备功能配置已保存');
    } catch (error) {
      _message('保存失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _leave() async {
    if (_busy) return;
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('放弃未保存的修改？'),
        content: const Text('当前修改尚未保存，返回后将丢失。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('继续编辑'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('放弃修改'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) {
      setState(() => _allowPop = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context);
      });
    }
  }

  Future<void> _editFunction([int? index]) async {
    final result = await showDeviceFunctionEditor(
      context,
      usedTypes: _functions
          .map((function) => readFunctionType(function['type'], 'type'))
          .toSet(),
      initial: index == null ? null : _functions[index],
    );
    if (result == null || !mounted) return;
    setState(() {
      if (index == null) {
        _functions.add(result);
      } else {
        _functions[index] = result;
      }
      _dirty = true;
    });
  }

  void _removeFunction(int index) {
    final removed = _functions[index];
    setState(() {
      _functions.removeAt(index);
      _dirty = true;
    });
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text('功能已移除'),
          action: SnackBarAction(
            label: '撤销',
            onPressed: () {
              if (!mounted ||
                  _functions.any((f) => f['type'] == removed['type']))
                return;
              setState(() {
                _functions.insert(index.clamp(0, _functions.length), removed);
                _dirty = true;
              });
            },
          ),
        ),
      );
  }

  IconData _icon(ConfigurableFunction type) => switch (type) {
    ConfigurableFunction.power => Icons.power_settings_new_rounded,
    ConfigurableFunction.light => Icons.palette_outlined,
    ConfigurableFunction.temperature => Icons.thermostat_rounded,
    ConfigurableFunction.fanSpeed ||
    ConfigurableFunction.fanSpeedPercent => Icons.air_rounded,
    ConfigurableFunction.timer => Icons.schedule_rounded,
  };

  String _summary(Map<String, Object?> function) {
    final value = function['status'];
    return switch (readFunctionType(function['type'], 'type')) {
      ConfigurableFunction.power =>
        value == true ? '初始状态 · 开启' : '初始状态 · 关闭',
      ConfigurableFunction.temperature =>
        '目标温度 · ${value is num && value == value.round() ? value.round() : value}℃',
      ConfigurableFunction.fanSpeed =>
        FanSpeed.valueOf(value) == FanSpeed.high
            ? '初始档位 · 高速'
            : '初始档位 · 低速',
      ConfigurableFunction.fanSpeedPercent => '默认风速 · $value%',
      ConfigurableFunction.light =>
        (value as Map).entries
            .map(
              (entry) => '${entry.key.toString().toUpperCase()} ${entry.value}',
            )
            .join(' · '),
      ConfigurableFunction.timer => _timerSummary(value as Map),
    };
  }

  String _timerSummary(Map value) {
    String time(TimerField hour, TimerField minute) =>
        '${value[hour.wire].toString().padLeft(2, '0')}:${value[minute.wire].toString().padLeft(2, '0')}';
    return '${time(TimerField.startHour, TimerField.startMinute)}–'
        '${time(TimerField.endHour, TimerField.endMinute)} · '
        '${value[TimerField.enabled.wire] == true ? '启用' : '关闭'}';
  }

  Widget _functionList() => Column(
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              '功能模块（${_functions.length}）',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
            ),
          ),
          FilledButton.icon(
            onPressed: _functions.length < ConfigurableFunction.values.length
                ? () => _editFunction()
                : null,
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('添加功能'),
          ),
        ],
      ),
      const SizedBox(height: 12),
      if (_functions.isEmpty)
        SurfaceCard(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 28),
            child: Column(
              children: [
                const Icon(
                  Icons.widgets_outlined,
                  size: 36,
                  color: AppColors.blue,
                ),
                const SizedBox(height: 12),
                const Text(
                  '从一个功能开始',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                const Text(
                  '添加需要的模块，或导入已有 JSON 配置',
                  style: TextStyle(fontSize: 12, color: AppColors.muted),
                ),
              ],
            ),
          ),
        ),
      for (var index = 0; index < _functions.length; index++) ...[
        Builder(
          builder: (context) {
            final type = readFunctionType(
              _functions[index]['type'],
              'functions[$index].type',
            );
            return SurfaceCard(
              padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
              child: Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: AppColors.paleBlue,
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: Icon(_icon(type), color: AppColors.blue, size: 21),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: InkWell(
                      onTap: () => _editFunction(index),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            type.label,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _summary(_functions[index]),
                            style: const TextStyle(
                              fontSize: 11,
                              color: AppColors.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '修改${type.label}',
                    onPressed: () => _editFunction(index),
                    icon: const Icon(Icons.edit_outlined, size: 19),
                  ),
                  IconButton(
                    tooltip: '删除${type.label}',
                    onPressed: () => _removeFunction(index),
                    icon: const Icon(
                      Icons.delete_outline_rounded,
                      size: 19,
                      color: AppColors.red,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        if (index < _functions.length - 1) const SizedBox(height: 10),
      ],
    ],
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy && (!_dirty || _allowPop),
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _leave();
    },
    child: Scaffold(
      appBar: AppBar(
        title: const Text('编辑设备功能'),
        actions: [
          TextButton(onPressed: _busy ? null : _save, child: const Text('保存')),
          const SizedBox(width: 8),
        ],
      ),
      body: AbsorbPointer(
        absorbing: _busy,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Form(
                key: _formKey,
                onChanged: _changed,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_busy) const LinearProgressIndicator(),
                    Text(
                      _dirty ? '有未保存的修改' : '配置保存在本机，可导出后复用',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.muted,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: _importFile,
                          icon: const Icon(Icons.file_open_outlined, size: 17),
                          label: const Text('导入 JSON'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => _editJson(paste: true),
                          icon: const Icon(
                            Icons.content_paste_rounded,
                            size: 17,
                          ),
                          label: const Text('粘贴 JSON'),
                        ),
                        Builder(
                          builder: (context) => OutlinedButton.icon(
                            onPressed: () => _export(context),
                            icon: const Icon(Icons.ios_share_rounded, size: 17),
                            label: const Text('导出 JSON'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    SurfaceCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SectionTitle('设备信息'),
                          const SizedBox(height: 12),
                          TextFormField(
                            key: const ValueKey('device-name'),
                            controller: _name,
                            decoration: const InputDecoration(
                              labelText: '设备名称',
                            ),
                            validator: (value) =>
                                value == null || value.trim().isEmpty
                                ? '请输入设备名称'
                                : null,
                          ),
                          TextFormField(
                            key: const ValueKey('device-id'),
                            controller: _id,
                            decoration: const InputDecoration(
                              labelText: '设备标识',
                            ),
                            validator: (value) =>
                                value == null || value.trim().isEmpty
                                ? '请输入设备标识'
                                : null,
                          ),
                          TextFormField(
                            controller: _macd,
                            decoration: const InputDecoration(
                              labelText: '地址 / MAC',
                              hintText: '留空时使用设备标识',
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            '已配置 ${_services.length} 个 BLE 服务。读写命令、封包规则和编码方式在 JSON 中编辑'
                            '（chars / frame / response / commands），未声明时设备仅支持本机预览',
                            style: const TextStyle(
                              fontSize: 11,
                              color: AppColors.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    SegmentedButton<int>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: 0, label: Text('功能配置')),
                        ButtonSegment(value: 1, label: Text('效果预览')),
                        ButtonSegment(value: 2, label: Text('JSON')),
                      ],
                      selected: {_tab},
                      onSelectionChanged: (value) => _selectTab(value.single),
                    ),
                    const SizedBox(height: 18),
                    if (_tab == 0) _functionList(),
                    if (_tab == 1) ...[
                      const Text(
                        '预览展示模块初始值',
                        style: TextStyle(fontSize: 12, color: AppColors.muted),
                      ),
                      const SizedBox(height: 12),
                      if (_functions.isEmpty)
                        const SurfaceCard(child: Text('添加功能后即可预览控制面板')),
                      ExcludeFocus(
                        child: IgnorePointer(
                          child: Builder(
                            builder: (context) => _preview.buildDeviceCart(
                              context,
                              CardSize.large,
                            ),
                          ),
                        ),
                      ),
                    ],
                    if (_tab == 2) ...[
                      Wrap(
                        spacing: 8,
                        children: [
                          TextButton.icon(
                            onPressed: _editJson,
                            icon: const Icon(Icons.edit_note_rounded),
                            label: const Text('编辑 JSON'),
                          ),
                          TextButton.icon(
                            onPressed: () async {
                              try {
                                await Clipboard.setData(
                                  ClipboardData(
                                    text: _configuration().toJsonString(),
                                  ),
                                );
                                _message('JSON 已复制');
                              } catch (error) {
                                _message('复制失败：$error');
                              }
                            },
                            icon: const Icon(Icons.copy_rounded, size: 18),
                            label: const Text('复制 JSON'),
                          ),
                        ],
                      ),
                      SurfaceCard(
                        child: SelectableText(
                          _jsonPreview(),
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            height: 1.6,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  String _jsonPreview() {
    try {
      return _configuration().toJsonString();
    } catch (error) {
      return '请完善设备信息：$error';
    }
  }
}

class _ConfigurationJsonDialog extends StatefulWidget {
  const _ConfigurationJsonDialog({
    required this.initialSource,
    required this.paste,
  });
  final String initialSource;
  final bool paste;
  @override
  State<_ConfigurationJsonDialog> createState() =>
      _ConfigurationJsonDialogState();
}

class _ConfigurationJsonDialogState extends State<_ConfigurationJsonDialog> {
  late final TextEditingController _text = TextEditingController(
    text: widget.initialSource,
  );
  String? _error;
  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.paste ? '粘贴 JSON 配置' : '编辑 JSON 配置'),
    content: SizedBox(
      width: 560,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _text,
              minLines: 8,
              maxLines: 16,
              keyboardType: TextInputType.multiline,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: const InputDecoration(
                hintText: '粘贴完整设备配置',
                border: OutlineInputBorder(),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  style: const TextStyle(color: AppColors.red),
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
            Navigator.pop(
              context,
              DeviceConfiguration.fromJsonString(_text.text),
            );
          } catch (error) {
            setState(() => _error = '配置无效：$error');
          }
        },
        child: const Text('载入配置'),
      ),
    ],
  );
}
