import 'dart:convert';

import 'package:flutter/material.dart';

import '../app/theme.dart';
import '../core/device/function_type.dart';
import '../core/functions/light.dart';
import '../core/functions/timer.dart';
import '../data/device_configuration.dart';

Future<Map<String, Object?>?> showDeviceFunctionEditor(
  BuildContext context, {
  required Set<ConfigurableFunction> usedTypes,
  Map<String, Object?>? initial,
}) => showDialog<Map<String, Object?>>(
  context: context,
  builder: (_) => _DeviceFunctionEditor(usedTypes: usedTypes, initial: initial),
);

class _DeviceFunctionEditor extends StatefulWidget {
  const _DeviceFunctionEditor({required this.usedTypes, this.initial});

  final Set<ConfigurableFunction> usedTypes;
  final Map<String, Object?>? initial;

  @override
  State<_DeviceFunctionEditor> createState() => _DeviceFunctionEditorState();
}

class _DeviceFunctionEditorState extends State<_DeviceFunctionEditor> {
  late final List<ConfigurableFunction> _types = ConfigurableFunction.values
      .where(
        (type) =>
            !widget.usedTypes.contains(type) ||
            widget.initial?['type'] == type.wire,
      )
      .toList();
  late ConfigurableFunction _type = _types.firstWhere(
    (type) => type.wire == widget.initial?['type'],
    orElse: () => _types.first,
  );
  late Object _value = jsonDecode(
    jsonEncode(widget.initial?['status'] ?? _type.defaultStatus),
  ) as Object;

  Map<String, Object?> get _values => _value as Map<String, Object?>;

  void _setField(String key, Object value) =>
      setState(() => _value = {..._values, key: value});

  Widget _slider(
    String title,
    num value,
    int min,
    int max,
    ValueChanged<int> onChanged, {
    String unit = '%',
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            Text(
              '${value.round()}$unit',
              style: const TextStyle(
                color: AppColors.blue,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        Slider(
          value: value.toDouble(),
          min: min.toDouble(),
          max: max.toDouble(),
          divisions: max - min,
          onChanged: (value) => onChanged(value.round()),
        ),
      ],
    );
  }

  Future<void> _pickTime(TimerField hour, TimerField minute) async {
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: _values[hour.wire] as int,
        minute: _values[minute.wire] as int,
      ),
    );
    if (time != null && mounted) {
      setState(
        () => _value = {
          ..._values,
          hour.wire: time.hour,
          minute.wire: time.minute,
        },
      );
    }
  }

  Widget _timeButton(TimerField hour, TimerField minute, String label) =>
      OutlinedButton.icon(
        onPressed: () => _pickTime(hour, minute),
        icon: const Icon(Icons.schedule_rounded, size: 18),
        label: Text(
          '$label ${(_values[hour.wire] as int).toString().padLeft(2, '0')}:${(_values[minute.wire] as int).toString().padLeft(2, '0')}',
        ),
      );

  List<Widget> _fields() => switch (_type) {
    ConfigurableFunction.power => [
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('默认开启'),
        value: _value as bool,
        onChanged: (value) => setState(() => _value = value),
      ),
    ],
    ConfigurableFunction.light => [
      for (final entry in const {
        LightChannel.red: '红光 Red',
        LightChannel.green: '绿光 Green',
        LightChannel.blue: '蓝光 Blue',
        LightChannel.white: '白光 White',
        LightChannel.uv: 'UV',
      }.entries)
        _slider(
          entry.value,
          _values[entry.key.wire] as num,
          0,
          100,
          (value) => _setField(entry.key.wire, value),
        ),
    ],
    ConfigurableFunction.temperature => [
      _slider(
        '目标温度',
        _value as num,
        20,
        80,
        (value) => setState(() => _value = value),
        unit: '℃',
      ),
    ],
    ConfigurableFunction.fanSpeed => [
      SegmentedButton<String>(
        segments: const [
          ButtonSegment(value: 'low', label: Text('低速')),
          ButtonSegment(value: 'high', label: Text('高速')),
        ],
        selected: {_value as String},
        onSelectionChanged: (value) => setState(() => _value = value.single),
      ),
    ],
    ConfigurableFunction.fanSpeedPercent => [
      _slider(
        '默认风速',
        _value as num,
        0,
        100,
        (value) => setState(() => _value = value),
      ),
    ],
    ConfigurableFunction.timer => [
      DropdownButtonFormField<int>(
        initialValue: _values[TimerField.slot.wire] as int,
        decoration: const InputDecoration(labelText: '定时槽位'),
        items: const [
          DropdownMenuItem(value: 1, child: Text('第一组')),
          DropdownMenuItem(value: 2, child: Text('第二组')),
        ],
        onChanged: (value) {
          if (value != null) _setField(TimerField.slot.wire, value);
        },
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('启用定时'),
        value: _values[TimerField.enabled.wire] as bool,
        onChanged: (value) => _setField(TimerField.enabled.wire, value),
      ),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _timeButton(TimerField.startHour, TimerField.startMinute, '开始'),
          _timeButton(TimerField.endHour, TimerField.endMinute, '结束'),
        ],
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('日出日落渐变'),
        value: _values[TimerField.sunriseSunsetEnabled.wire] as bool,
        onChanged: (value) =>
            _setField(TimerField.sunriseSunsetEnabled.wire, value),
      ),
      if (_values[TimerField.sunriseSunsetEnabled.wire] == true) ...[
        _slider(
          '日出时长',
          _values[TimerField.sunriseMinutes.wire] as num,
          0,
          255,
          (value) => _setField(TimerField.sunriseMinutes.wire, value),
          unit: ' 分钟',
        ),
        _slider(
          '日落时长',
          _values[TimerField.sunsetMinutes.wire] as num,
          0,
          255,
          (value) => _setField(TimerField.sunsetMinutes.wire, value),
          unit: ' 分钟',
        ),
      ],
    ],
  };

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.initial == null ? '添加功能' : '修改功能'),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<ConfigurableFunction>(
              key: const ValueKey('function-type'),
              initialValue: _type,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '功能类型'),
              items: [
                for (final type in _types)
                  DropdownMenuItem(value: type, child: Text(type.label)),
              ],
              onChanged: (type) {
                if (type != null) {
                  setState(() {
                    _type = type;
                    _value =
                        jsonDecode(jsonEncode(type.defaultStatus)) as Object;
                  });
                }
              },
            ),
            const SizedBox(height: 20),
            ..._fields(),
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
        onPressed: () => Navigator.pop(context, <String, Object?>{
          'type': _type.wire,
          'status': _value,
        }),
        child: const Text('确定'),
      ),
    ],
  );
}
