import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:light/src/core/device/device_property.dart';

import '../app/router.dart';
import '../app/scope.dart';
import '../app/theme.dart';
import '../core/device/code/value_validator.dart';
import '../core/device/device.dart';
import '../core/device/models.dart';
import '../core/device/spec/ui_spec.dart';
import '../core/device/spec/value_spec.dart';
import '../core/device/types.dart';
import '../widgets/app_widgets.dart';

/// 由 [Device] 渲染的设备页
///
/// 通用 UI 渲染：属性按 ui.renderer 生成控件，读写通知能力与角色权限决定可用动作，
/// 上报值、期望值、下发记录都直接来自 [Device]，页面不包含设备私有逻辑。
class DevicePage extends StatefulWidget {
  const DevicePage({required this.device, super.key, this.onDisconnect, this.onEditModel});

  final Device device;

  /// 断开网关侧连接的入口，缺省时不显示断开按钮
  final Future<void> Function()? onDisconnect;

  /// 编辑设备定义的入口，缺省时不显示编辑按钮
  final VoidCallback? onEditModel;

  @override
  State<DevicePage> createState() => _DevicePageState();
}

class _DevicePageState extends State<DevicePage> {
  String? _error;

  Device get _device => widget.device;

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _error = null);
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  /// 按属性声明的逻辑类型写入，控件只负责取值
  Future<void> _write(String property, Object? value) => _run(() async => _device.writeProperty(property, value));

  Future<void> _edit(String id, DeviceProperty property, Object? current) async {
    final value = await showDialog<Object?>(
      context: context,
      builder: (_) => _ModelValueDialog(spec: property.value, title: '设置${property.name}', initialValue: current),
    );
    if (value == _ModelValueDialog.cancelled) return;
    await _write(id, value);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _device,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(title: Text(_device.name)),
          floatingActionButton: widget.onEditModel == null
              ? null
              : FloatingActionButton.extended(
                  onPressed: widget.onEditModel,
                  icon: const Icon(Icons.data_object),
                  label: const Text('编辑模型'),
                ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              SurfaceCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${_device.deviceId} · 模板 ${_device.modelId} · ${_device.role.wireName}',
                      style: const TextStyle(color: AppColors.muted),
                    ),
                    const SizedBox(height: 8),
                    Text(_device.ready ? '网关在线' : '网关离线'),
                    if (_device.stale && _device.reported.isNotEmpty)
                      const Text('部分上报已过期或缺少顺序校验', style: TextStyle(color: AppColors.orange)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        FilledButton(
                          onPressed: _device.ready && !_device.busy ? () => _run(_device.start) : null,
                          child: const Text('连接'),
                        ),
                        OutlinedButton(
                          onPressed: _device.ready && !_device.busy ? () => _run(_device.refresh) : null,
                          child: const Text('读取属性'),
                        ),
                        if (widget.onDisconnect != null)
                          OutlinedButton(
                            onPressed: _device.busy ? null : () => _run(widget.onDisconnect!),
                            child: const Text('断开连接'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              if (_device.busy)
                const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: LinearProgressIndicator()),
              if (_error ?? _device.lastError case final String error)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(error, style: const TextStyle(color: AppColors.red)),
                ),
              const SizedBox(height: 20),
              const SectionTitle('属性'),
              const SizedBox(height: 8),
              for (final entry in _device.properties.entries)
                if (entry.value.ui?.renderer != UiRenderer.hidden)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _PropertyCard(
                      id: entry.key,
                      property: entry.value,
                      device: _device,
                      onWrite: _write,
                      onEdit: _edit,
                      onRead: (property) => _run(() => _device.readProperty(property)),
                    ),
                  ),
              const SizedBox(height: 12),
              const SectionTitle('下发记录'),
              const SizedBox(height: 8),
              const Text('“已写入”表示网关完成 BLE 写入，实际状态以设备上报为准', style: TextStyle(fontSize: 12, color: AppColors.muted)),
              if (_device.commands.isEmpty) const Text('暂无记录', style: TextStyle(color: AppColors.muted)),
              for (final record in _device.commands.take(20))
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('${record.operation} · ${_stateLabel(record.state)}'),
                  subtitle: Text('${record.requestId ?? record.message ?? ''}\n${record.at.toLocal()}'),
                ),
            ],
          ),
        );
      },
    );
  }

  static String _stateLabel(DeviceCommandState state) => switch (state) {
    DeviceCommandState.written => '已写入',
    DeviceCommandState.deviceAck => '设备已确认',
    DeviceCommandState.deviceState => '设备已回报',
    DeviceCommandState.read => '已读取',
    DeviceCommandState.failed => '执行失败',
    DeviceCommandState.unknown => '结果未确认',
  };
}

/// 单个属性的卡片：状态、能力、权限与按渲染器生成的控件
class _PropertyCard extends StatelessWidget {
  const _PropertyCard({
    required this.id,
    required this.property,
    required this.device,
    required this.onWrite,
    required this.onEdit,
    required this.onRead,
  });

  final String id;
  final DeviceProperty property;
  final Device device;
  final Future<void> Function(String property, Object? value) onWrite;
  final Future<void> Function(String id, DeviceProperty property, Object? current) onEdit;
  final Future<void> Function(String property) onRead;

  bool get _enabled => device.ready && !device.busy;

  Object? get _current {
    final reported = device.reported[id];
    if (reported != null) return reported.value;
    final desired = device.desired[id];
    if (desired != null) return desired;
    return property.value.hasDefault ? property.value.defaultValue : null;
  }

  @override
  Widget build(BuildContext context) {
    final state = device.reported[id];
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(property.name, style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
              Text(_capabilities, style: const TextStyle(color: AppColors.muted)),
            ],
          ),
          const SizedBox(height: 8),
          SelectableText(
            state == null
                ? '尚未收到设备上报'
                : '${_display(state.value)}${property.value.unit == null ? '' : ' ${property.value.unit}'}',
          ),
          if (state != null)
            Text(
              '${device.isFresh(state)
                  ? '有效'
                  : state.verified
                  ? '已过期'
                  : '未校验'} · 接收于 ${state.receivedAt.toLocal()}',
              style: const TextStyle(fontSize: 11, color: AppColors.muted),
            ),
          if (state?.sampledAt case final DateTime sampledAt)
            Text('采样于 ${sampledAt.toLocal()}', style: const TextStyle(fontSize: 11, color: AppColors.muted)),
          if (device.desired[id] case final Object desired)
            Text('期望值：${_display(desired)} · 尚未回报一致值', style: const TextStyle(color: AppColors.orange)),
          const SizedBox(height: 12),
          ..._control(context),
          if (property.canRead)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: _enabled ? () => onRead(id) : null, child: const Text('读取')),
            ),
        ],
      ),
    );
  }

  String get _capabilities {
    final roles = property.permissions;
    final parts = <String>[if (property.canRead) '可读', if (property.canWrite) '可写', if (property.canNotify) '通知'];
    if (parts.isEmpty) return '不可访问';
    final restricted = <String>[
      if (roles?.read != null && property.canRead) '读 ${roles!.read!.map((role) => role.wireName).join('/')}',
      if (roles?.write != null && property.canWrite) '写 ${roles!.write!.map((role) => role.wireName).join('/')}',
      if (roles?.notify != null && property.canNotify) '通知 ${roles!.notify!.map((role) => role.wireName).join('/')}',
    ];
    final names = parts.join(' ');
    return restricted.isEmpty ? names : '$names（${restricted.join('，')}）';
  }

  /// 按 ui.renderer 选择控件，未声明渲染器时用类型推断
  List<Widget> _control(BuildContext context) {
    final spec = property.value;
    // 不可写的属性只展示上报状态，不生成写入控件
    if (!property.canWrite) return const [];
    final renderer = property.ui?.renderer ?? _inferredRenderer(spec);
    final writable = property.canWrite && _enabled;
    switch (renderer) {
      case UiRenderer.toggle:
        return [
          Row(
            children: [
              const Expanded(child: Text('开关')),
              Switch(value: _current == true, onChanged: writable ? (value) => onWrite(id, value) : null),
            ],
          ),
        ];
      case UiRenderer.slider:
        return [_slider(spec, writable)];
      case UiRenderer.segmented:
        return [_segmented(spec, writable)];
      case UiRenderer.stepper:
        return [_stepper(spec, writable)];
      case UiRenderer.input:
      case UiRenderer.hexEditor:
        return [
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: writable ? () => onEdit(id, property, _current) : null,
              child: const Text('输入值'),
            ),
          ),
        ];
      case UiRenderer.color:
        return _channels(spec, writable);
      case UiRenderer.scheduleList:
        return [
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: writable ? () => onEdit(id, property, _current) : null,
              child: const Text('编辑定时'),
            ),
          ),
        ];
      case UiRenderer.hidden:
        return const [];
    }
  }

  static UiRenderer _inferredRenderer(ValueSpec spec) => switch (spec.type) {
    ValueType.boolean => UiRenderer.toggle,
    ValueType.enumeration => UiRenderer.segmented,
    ValueType.integer || ValueType.double =>
      spec.constraints?.min != null && spec.constraints?.max != null ? UiRenderer.slider : UiRenderer.input,
    _ => UiRenderer.input,
  };

  Widget _slider(ValueSpec spec, bool writable) {
    final min = (spec.constraints?.min ?? 0).toDouble();
    final max = (spec.constraints?.max ?? 100).toDouble();
    final value = (_current as num?)?.toDouble() ?? min;
    final step = spec.constraints?.step?.toDouble() ?? 1;
    final divisions = ((max - min) / step).round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions > 0 ? divisions : null,
          label: '$value${spec.unit ?? ''}',
          onChanged: writable ? (_) {} : null,
          onChangeEnd: writable ? (next) => onWrite(id, _number(spec, next)) : null,
        ),
        Text(
          '$min${spec.unit ?? ''} ～ $max${spec.unit ?? ''}',
          style: const TextStyle(fontSize: 11, color: AppColors.muted),
        ),
      ],
    );
  }

  Widget _segmented(ValueSpec spec, bool writable) {
    final current = _current;
    return SegmentedButton<Object?>(
      segments: [for (final value in spec.values) ButtonSegment(value: value.value, label: Text(value.label))],
      selected: {?current},
      emptySelectionAllowed: true,
      onSelectionChanged: writable
          ? (selection) {
              if (selection.isEmpty) return;
              onWrite(id, selection.first);
            }
          : null,
    );
  }

  Widget _stepper(ValueSpec spec, bool writable) {
    final min = (spec.constraints?.min ?? 0).toDouble();
    final max = (spec.constraints?.max ?? 100).toDouble();
    final step = (spec.constraints?.step ?? 1).toDouble();
    final value = (_current as num?)?.toDouble() ?? min;
    return Row(
      children: [
        IconButton(
          onPressed: writable && value - step >= min ? () => onWrite(id, _number(spec, value - step)) : null,
          icon: const Icon(Icons.remove_rounded),
        ),
        Expanded(child: Text('$value${spec.unit ?? ''}', textAlign: TextAlign.center)),
        IconButton(
          onPressed: writable && value + step <= max ? () => onWrite(id, _number(spec, value + step)) : null,
          icon: const Icon(Icons.add_rounded),
        ),
      ],
    );
  }

  /// 颜色渲染器用于 object 属性，每个数值子属性一条通道
  List<Widget> _channels(ValueSpec spec, bool writable) {
    final current = _current;
    final values = current is Map ? current : const <String, Object?>{};
    return [
      for (final entry in spec.properties.entries)
        if (entry.value.type == ValueType.integer || entry.value.type == ValueType.double)
          _channel(entry.key, entry.value, (values[entry.key] as num?)?.toDouble() ?? 0, writable),
    ];
  }

  Widget _channel(String name, ValueSpec spec, double value, bool writable) {
    final min = (spec.constraints?.min ?? 0).toDouble();
    final max = (spec.constraints?.max ?? 100).toDouble();
    return Row(
      children: [
        SizedBox(width: 64, child: Text(name)),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: max - min > 0 ? (max - min).round() : null,
            onChanged: writable ? (_) {} : null,
            onChangeEnd: writable ? (next) => onWrite(id, _channelValue(name, spec, next)) : null,
          ),
        ),
        SizedBox(width: 40, child: Text('${value.round()}')),
      ],
    );
  }

  /// 写入其中一个通道时保留其它通道的当前值
  Map<String, Object?> _channelValue(String name, ValueSpec spec, double value) {
    final current = _current;
    final values = current is Map
        ? {for (final entry in current.entries) '${entry.key}': entry.value}
        : <String, Object?>{};
    return {
      for (final entry in spec.properties.entries)
        entry.key: entry.key == name
            ? _number(entry.value, value)
            : values[entry.key] ?? (entry.value.constraints?.min ?? 0),
    };
  }

  static Object _number(ValueSpec spec, double value) => spec.type == ValueType.integer ? value.round() : value;

  static String _display(Object? value) => value is String ? value : jsonEncode(value);
}

/// 通用取值对话框：按值声明递归生成输入控件
class _ModelValueDialog extends StatefulWidget {
  const _ModelValueDialog({required this.spec, required this.title, this.initialValue});

  /// 取消时返回它，与合法的 null 值区分
  static final Object cancelled = Object();

  final ValueSpec spec;
  final String title;
  final Object? initialValue;

  @override
  State<_ModelValueDialog> createState() => _ModelValueDialogState();
}

class _ModelValueDialogState extends State<_ModelValueDialog> {
  late Object? _value = widget.initialValue ?? _default(widget.spec);
  String? _error;

  Object? _default(ValueSpec spec) => switch (spec.type) {
    ValueType.boolean => false,
    ValueType.integer || ValueType.double => spec.constraints?.min ?? 0,
    ValueType.string => '',
    ValueType.enumeration => spec.values.isEmpty ? null : spec.values.first.value,
    ValueType.array => <Object?>[],
    ValueType.object => {for (final entry in spec.properties.entries) entry.key: _default(entry.value)},
  };

  Widget _field(ValueSpec spec, String label, Object? value, ValueChanged<Object?> changed) {
    if (spec.type == ValueType.enumeration) {
      return DropdownButtonFormField<Object>(
        initialValue: spec.values.any((item) => item.value == value) ? value : null,
        isExpanded: true,
        decoration: InputDecoration(labelText: label),
        items: [for (final item in spec.values) DropdownMenuItem(value: item.value, child: Text(item.label))],
        onChanged: changed,
      );
    }
    if (spec.type == ValueType.boolean) {
      return SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(label),
        value: value == true,
        onChanged: changed,
      );
    }
    if (spec.type == ValueType.object) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final entry in spec.properties.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _field(
                entry.value,
                '${entry.key}${entry.value.unit == null ? '' : ' (${entry.value.unit})'}',
                (value as Map?)?[entry.key],
                (next) => changed(<String, Object?>{...?value as Map<String, Object?>?, entry.key: next}),
              ),
            ),
        ],
      );
    }
    return TextFormField(
      initialValue: value == null
          ? ''
          : spec.type == ValueType.array
          ? jsonEncode(value)
          : '$value',
      keyboardType: (spec.type == ValueType.integer || spec.type == ValueType.double)
          ? const TextInputType.numberWithOptions(decimal: true, signed: true)
          : TextInputType.text,
      maxLines: spec.type == ValueType.array ? 4 : 1,
      decoration: InputDecoration(
        labelText: label,
        helperText: spec.constraints == null
            ? null
            : '范围 ${spec.constraints?.min ?? '不限'} ～ ${spec.constraints?.max ?? '不限'}'
                  '${spec.constraints?.minLength == null ? '' : '，长度 ${spec.constraints?.minLength}～${spec.constraints?.maxLength}'}',
      ),
      onChanged: (text) {
        switch (spec.type) {
          case ValueType.integer:
            changed(int.tryParse(text) ?? text);
          case ValueType.double:
            changed(double.tryParse(text) ?? text);
          case ValueType.array:
            try {
              changed(jsonDecode(text));
            } on FormatException {
              changed(text);
            }
          case ValueType.string:
            changed(text);
          case ValueType.boolean:
          case ValueType.enumeration:
          case ValueType.object:
            break;
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 460,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _field(widget.spec, '值', _value, (value) => setState(() => _value = value)),
            if (_error != null) Text(_error!, style: const TextStyle(color: AppColors.red)),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context, _ModelValueDialog.cancelled), child: const Text('取消')),
      FilledButton(
        onPressed: () {
          try {
            ValueValidator.validate(_value, widget.spec, path: '输入');
            Navigator.pop(context, _value);
          } catch (error) {
            setState(() => _error = '$error');
          }
        },
        child: const Text('下发'),
      ),
    ],
  );
}

/// 由路由打开的通用设备页：设备定义来自本地保存的 [Device]
class DeviceRoutePage extends StatelessWidget {
  const DeviceRoutePage({required this.deviceId, super.key});

  final String deviceId;

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.watch(context);
    final device = controller.deviceFor(deviceId);
    if (device == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('设备不可用')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.devices_other_rounded, size: 48, color: AppColors.muted),
                const SizedBox(height: 16),
                Text(
                  '设备 $deviceId 没有可用协议模板',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                const Text(
                  '请先新建或导入对应模板，并为设备完成绑定',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.muted),
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: context.pushDeviceModel,
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('新建协议模板'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return DevicePage(
      device: device,
      onDisconnect: () => controller.deviceRegistry.disconnectDevice(deviceId),
      onEditModel: () => context.pushDeviceModel(modelId: device.modelId),
    );
  }
}
