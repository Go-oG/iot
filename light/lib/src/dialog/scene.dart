import 'package:flutter/material.dart';
import 'package:light/src/core/functions/light.dart';

import '../app/theme.dart';
import '../data/color_presets.dart';
import '../data/models.dart';

Future<ScenePreset?> showSceneEditor(
  BuildContext context, {
  required String newId,
  ScenePreset? scene,
  LightState? initialState,
}) {
  return showDialog<ScenePreset>(
    context: context,
    builder: (context) => _SceneEditorDialog(
      newId: newId,
      scene: scene,
      initialState: initialState,
    ),
  );
}

class _SceneEditorDialog extends StatefulWidget {
  const _SceneEditorDialog({
    required this.newId,
    this.scene,
    this.initialState,
  });

  final String newId;
  final ScenePreset? scene;
  final LightState? initialState;

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
  String? _nameError;
  late int _accentValue;
  late LightState _state;

  @override
  void initState() {
    super.initState();
    final scene = widget.scene;
    _nameController = TextEditingController(text: scene?.name ?? '新配色');
    _subtitleController = TextEditingController(
      text: scene?.subtitle ?? '自定义鱼缸灯配色',
    );
    _accentValue = scene?.accentValue ?? _accentColors.first;
    _state =
        widget.initialState ?? scene?.state ?? aquariumColorPresets.first.state;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _subtitleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
                        _state = preset.state;
                        _accentValue = preset.accentValue;
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                '选择模板后可继续微调各通道，保存后点击配色即可应用',
                style: TextStyle(color: AppColors.muted, fontSize: 12),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '通道平均亮度 ${_state.powerPercent}%',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              _LabeledSlider(
                label: '红光',
                value: _state.red,
                color: const Color(0xFFFF3131),
                onChanged: (value) =>
                    setState(() => _state = _state.copyWith(red: value)),
              ),
              _LabeledSlider(
                label: '绿光',
                value: _state.green,
                color: const Color(0xFF00C765),
                onChanged: (value) =>
                    setState(() => _state = _state.copyWith(green: value)),
              ),
              _LabeledSlider(
                label: '蓝光',
                value: _state.blue,
                color: const Color(0xFF2585FF),
                onChanged: (value) =>
                    setState(() => _state = _state.copyWith(blue: value)),
              ),
              _LabeledSlider(
                label: '白光',
                value: _state.white,
                color: const Color(0xFF9BA9C4),
                onChanged: (value) =>
                    setState(() => _state = _state.copyWith(white: value)),
              ),
              _LabeledSlider(
                label: 'UV',
                value: _state.uv,
                color: const Color(0xFFAD50EE),
                onChanged: (value) =>
                    setState(() => _state = _state.copyWith(uv: value)),
              ),
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

  void _save() {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = '请输入配色名称');
      return;
    }
    Navigator.pop(
      context,
      ScenePreset(
        id: widget.scene?.id ?? widget.newId,
        name: name,
        subtitle: _subtitleController.text.trim(),
        temperature: widget.scene?.temperature ?? 4000,
        brightness: _state.powerPercent,
        accentValue: _accentValue,
        state: _state,
      ),
    );
  }
}

class _LabeledSlider extends StatelessWidget {
  const _LabeledSlider({
    required this.label,
    required this.value,
    required this.color,
    required this.onChanged,
  });

  final String label;
  final int value;
  final Color color;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 48,
          child: Text(label, style: const TextStyle(fontSize: 12)),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context)
                .copyWith(activeTrackColor: color, thumbColor: color),
            child: Slider(
              value: value.toDouble().clamp(0, 100),
              min: 0,
              max: 100,
              divisions: 100,
              onChanged: (newValue) => onChanged(newValue.round()),
            ),
          ),
        ),
        SizedBox(
          width: 48,
          child: Text(
            '$value%',
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 11),
          ),
        ),
      ],
    );
  }
}
