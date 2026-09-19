import 'package:flutter/material.dart';
import 'package:light/src/data/models.dart';

Future<SavedDevice?> showDeviceEditor(
  BuildContext context,
  SavedDevice device,
) {
  return showDialog<SavedDevice>(
    context: context,
    builder: (context) => _DeviceEditorDialog(device: device),
  );
}

class _DeviceEditorDialog extends StatefulWidget {
  const _DeviceEditorDialog({required this.device});

  final SavedDevice device;

  @override
  State<_DeviceEditorDialog> createState() => _DeviceEditorDialogState();
}

class _DeviceEditorDialogState extends State<_DeviceEditorDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _roomController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.device.name);
    _roomController = TextEditingController(text: widget.device.room);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _roomController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('编辑设备'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _nameController,
            maxLength: 24,
            decoration: const InputDecoration(labelText: '设备名称'),
          ),
          TextField(
            controller: _roomController,
            maxLength: 16,
            decoration: const InputDecoration(labelText: '房间'),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('设备型号'),
            subtitle: Text(widget.device.model.wire),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final name = _nameController.text.trim();
            if (name.isEmpty) {
              return;
            }
            Navigator.pop(
              context,
              widget.device.copyWith(
                name: name,
                room: _roomController.text.trim().isEmpty
                    ? '未分组'
                    : _roomController.text.trim(),
              ),
            );
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}
