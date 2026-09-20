import 'package:flutter/material.dart';

import '../data/models.dart';

Future<SchedulePlan?> showScheduleEditor(
  BuildContext context, {
  required int newId,
  required List<ScenePreset> scenes,
  SchedulePlan? plan,
}) async {
  if (scenes.isEmpty) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('请先新增一组配色，再创建计划')));
    return null;
  }
  return showDialog<SchedulePlan>(
    context: context,
    builder: (context) =>
        _ScheduleEditorDialog(newId: newId, scenes: scenes, plan: plan),
  );
}

class _ScheduleEditorDialog extends StatefulWidget {
  const _ScheduleEditorDialog({
    required this.newId,
    required this.scenes,
    this.plan,
  });

  final int newId;
  final List<ScenePreset> scenes;
  final SchedulePlan? plan;

  @override
  State<_ScheduleEditorDialog> createState() => _ScheduleEditorDialogState();
}

class _ScheduleEditorDialogState extends State<_ScheduleEditorDialog> {
  late final TextEditingController _repeatController;
  late TimeOfDay _start;
  late TimeOfDay _end;
  late bool _enabled;
  late String _sceneId;

  @override
  void initState() {
    super.initState();
    final plan = widget.plan;
    _repeatController = TextEditingController(text: plan?.repeatLabel ?? '每天');
    _start = TimeOfDay(
      hour: plan?.startHour ?? 7,
      minute: plan?.startMinute ?? 0,
    );
    _end = TimeOfDay(hour: plan?.endHour ?? 8, minute: plan?.endMinute ?? 0);
    _enabled = plan?.enabled ?? true;
    _sceneId = plan?.sceneId ?? widget.scenes.first.id;
  }

  @override
  void dispose() {
    _repeatController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.plan == null ? '新建计划' : '编辑计划'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('启用计划'),
              value: _enabled,
              onChanged: (value) => setState(() => _enabled = value),
            ),
            Row(
              children: [
                Expanded(
                  child: _TimeButton(
                    label: '开始',
                    time: _start,
                    onTap: () => _pickTime(true),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _TimeButton(
                    label: '结束',
                    time: _end,
                    onTap: () => _pickTime(false),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _repeatController,
              maxLength: 20,
              decoration: const InputDecoration(
                labelText: '重复规则',
                hintText: '例如：每天、周一至周五',
              ),
            ),
            DropdownButtonFormField<String>(
              initialValue: _sceneId,
              decoration: const InputDecoration(labelText: '执行配色'),
              items: [
                for (final scene in widget.scenes)
                  DropdownMenuItem(value: scene.id, child: Text(scene.name)),
              ],
              onChanged: (value) =>
                  setState(() => _sceneId = value ?? _sceneId),
            ),
          ],
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

  Future<void> _pickTime(bool start) async {
    final value = await showTimePicker(
      context: context,
      initialTime: start ? _start : _end,
    );
    if (value == null || !mounted) {
      return;
    }
    setState(() {
      if (start) {
        _start = value;
      } else {
        _end = value;
      }
    });
  }

  void _save() {
    final repeatLabel = _repeatController.text.trim().isEmpty
        ? '每天'
        : _repeatController.text.trim();
    final plan = widget.plan;
    // 定时槽位以属性值保存，编辑已有计划时保留日出日落等其它字段
    final result = plan == null
        ? SchedulePlan.fromFields(
            id: widget.newId,
            enabled: _enabled,
            startHour: _start.hour,
            startMinute: _start.minute,
            endHour: _end.hour,
            endMinute: _end.minute,
            repeatLabel: repeatLabel,
            sceneId: _sceneId,
          )
        : plan.copyWith(
            enabled: _enabled,
            startHour: _start.hour,
            startMinute: _start.minute,
            endHour: _end.hour,
            endMinute: _end.minute,
            repeatLabel: repeatLabel,
            sceneId: _sceneId,
          );
    Navigator.pop(context, result);
  }
}

class _TimeButton extends StatelessWidget {
  const _TimeButton({
    required this.label,
    required this.time,
    required this.onTap,
  });

  final String label;
  final TimeOfDay time;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: const Icon(Icons.schedule_rounded),
      label: Text('$label ${time.format(context)}'),
    );
  }
}
