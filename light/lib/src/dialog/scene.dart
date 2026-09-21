import 'package:flutter/material.dart';
import 'package:light/src/core/device/spec/value_spec.dart';

import '../app/theme.dart';
import '../core/device/device.dart';
import '../core/device/spec/ui_spec.dart';
import '../core/device/types.dart';
import '../data/color_presets.dart';
import '../data/models.dart';

/// 编辑一组配色：控件按设备模型的颜色属性生成，保存的是属性值
Future<ScenePreset?> showSceneEditor(
  BuildContext context, {
  required String newId,
  ScenePreset? scene,
      required Device device,
  Map<String, Object?>? initialProperties,
}) {
  return showDialog<ScenePreset>(
    context: context,
    builder: (context) => _SceneEditorDialog(
      newId: newId,
      scene: scene,
      device: device,
      initialProperties: initialProperties,
    ),
  );
}

class _SceneEditorDialog extends StatefulWidget {
  const _SceneEditorDialog({
    required this.newId,
    this.scene,
    required this.device,
    this.initialProperties,
  });

  final String newId;
  final ScenePreset? scene;

  final Device device;

  /// 用当前灯光数值新建配色时传入的属性值
  final Map<String, Object?>? initialProperties;

  @override
  State<_SceneEditorDialog> createState() => _SceneEditorDialogState();
}

class _SceneEditorDialogState extends State<_SceneEditorDialog> {
  static const _accentColors = [
    0xFF38A7FF,
    0xFF62D3B4,
    0xFFFFB449,
    0xFF7C6BFF,
    0xFF465FCF,
    0xFFFF6559,
  ];

  late final TextEditingController _nameController;
  late final TextEditingController _subtitleController;
  late final Device _model;
  late final String? _colorProperty;
  late final String? _powerProperty;
  late final Map<String, Object?> _baseProperties;
  final Map<String, int> _channels = {};
  String? _nameError;
  late int _accentValue;

  @override
  void initState() {
    super.initState();
    _model = widget.device;
    _colorProperty = _findColorProperty();
    _powerProperty = _findPowerProperty();
    final scene = widget.scene;
    _nameController = TextEditingController(text: scene?.name ?? '新配色');
    _subtitleController = TextEditingController(
      text: scene?.subtitle ?? '自定义鱼缸灯配色',
    );
    _accentValue = scene?.accentValue ?? _accentColors.first;
    final source = scene?.properties ?? widget.initialProperties ?? const {};
    _baseProperties = {
      for (final entry in source.entries)
        if (_model.properties[entry.key]?.canWrite ?? false)
          entry.key: entry.value,
    };
    _channels.addAll(_initialChannels(source));
  }

  @override
  void dispose() {
    _nameController.dispose();
    _subtitleController.dispose();
    super.dispose();
  }

  /// 颜色属性：优先取声明了 color 渲染器的对象属性
  String? _findColorProperty() {
    for (final entry in _model.properties.entries) {
      if (entry.value.ui?.renderer == UiRenderer.color &&
          entry.value.canWrite) {
        return entry.key;
      }
    }
    for (final entry in _model.properties.entries) {
      if (entry.value.value.type == ValueType.object && entry.value.canWrite) {
        return entry.key;
      }
    }
    return null;
  }

  /// 电源属性：声明了 toggle 渲染器的布尔属性
  String? _findPowerProperty() {
    for (final entry in _model.properties.entries) {
      if (entry.value.ui?.renderer == UiRenderer.toggle &&
          entry.value.value.type == ValueType.boolean &&
          entry.value.canWrite) {
        return entry.key;
      }
    }
    return null;
  }

  Map<String, int> _initialChannels(Map<String, Object?> source) {
    final color = _colorProperty;
    if (color == null) return {};
    final spec = _model.properties[color]!.value;
    final value = source[color];
    final channels = value is Map ? value : const <Object?, Object?>{};
    final template = aquariumColorPresets.first.channels;
    return {
      for (final entry in spec.properties.entries)
        entry.key: _clamp(
          channels[entry.key] is num
              ? (channels[entry.key] as num).round()
              : template[entry.key] ?? _min(entry.value),
          entry.value,
        ),
    };
  }

  static int _min(ValueSpec spec) => (spec.constraints?.min ?? 0).round();

  static int _max(ValueSpec spec) => (spec.constraints?.max ?? 100).round();

  static int _clamp(int value, ValueSpec spec) =>
      value.clamp(_min(spec), _max(spec));

  @override
  Widget build(BuildContext context) {
    final color = _colorProperty;
    final spec = color == null ? null : _model.properties[color]!.value;
    return AlertDialog(
      title: Text(widget.scene == null ? '新建配色' : '编辑配色'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _nameController,
                autofocus: widget.scene == null,
                maxLength: 16,
                decoration: InputDecoration(
                  labelText: '配色名称',
                  errorText: _nameError,
                  prefixIcon: const Icon(Icons.label_outline_rounded),
                ),
                onChanged: (_) {
                  if (_nameError != null) setState(() => _nameError = null);
                },
              ),
              TextField(
                controller: _subtitleController,
                maxLength: 24,
                decoration: const InputDecoration(
                  labelText: '配色说明',
                  prefixIcon: Icon(Icons.notes_rounded),
                ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '快捷调色模板',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              Wrap(
                spacing: 6,
                children: [
                  for (final preset in aquariumColorPresets)
                    ActionChip(
                      label: Text(preset.name),
                      onPressed: () => setState(() {
                        _channels.addAll({
                          for (final entry in preset.channels.entries)
                            if (spec?.properties.containsKey(entry.key) ??
                                false)
                              entry.key: entry.value,
                        });
                        _accentValue = preset.accentValue;
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                color == null
                    ? '设备模型 ${_model.id} 没有可写的颜色属性，只能保存名称与标识颜色'
                    : '调整${_model.properties[color]!.name}各通道，保存后点击配色即可下发',
                style: const TextStyle(color: AppColors.muted, fontSize: 12),
              ),
              if (spec != null) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '通道平均值 ${_average()}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                for (final entry in spec.properties.entries)
                  _LabeledSlider(
                    label: entry.key,
                    value: _channels[entry.key] ?? _min(entry.value),
                    minimum: _min(entry.value),
                    maximum: _max(entry.value),
                    onChanged: (value) =>
                        setState(() => _channels[entry.key] = value),
                  ),
              ],
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '卡片标识颜色',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 10,
                children: [
                  for (final value in _accentColors)
                    InkWell(
                      onTap: () => setState(() => _accentValue = value),
                      customBorder: const CircleBorder(),
                      child: Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: Color(value),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: _accentValue == value
                                ? AppColors.navy
                                : Colors.transparent,
                            width: 3,
                          ),
                        ),
                      ),
                    ),
                ],
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
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }

  int _average() {
    if (_channels.isEmpty) return 0;
    final total = _channels.values.reduce((left, right) => left + right);
    return (total / _channels.length).round();
  }

  void _save() {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = '请输入配色名称');
      return;
    }
    final properties = <String, Object?>{..._baseProperties};
    if (_colorProperty != null) {
      properties[_colorProperty] = Map<String, Object?>.from(_channels);
    }
    if (_powerProperty != null) {
      properties[_powerProperty] = true;
    }
    Navigator.pop(
      context,
      ScenePreset(
        id: widget.scene?.id ?? widget.newId,
        name: name,
        subtitle: _subtitleController.text.trim(),
        accentValue: _accentValue,
        properties: properties,
      ),
    );
  }
}

class _LabeledSlider extends StatelessWidget {
  const _LabeledSlider({
    required this.label,
    required this.value,
    required this.minimum,
    required this.maximum,
    required this.onChanged,
  });

  final String label;
  final int value;
  final int minimum;
  final int maximum;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final divisions = maximum - minimum;
    return Row(
      children: [
        SizedBox(
          width: 64,
          child: Text(label, style: const TextStyle(fontSize: 12)),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(minimum, maximum).toDouble(),
            min: minimum.toDouble(),
            max: maximum.toDouble(),
            divisions: divisions > 0 ? divisions : null,
            onChanged: (newValue) => onChanged(newValue.round()),
          ),
        ),
        SizedBox(
          width: 48,
          child: Text(
            '$value',
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 11),
          ),
        ),
      ],
    );
  }
}
