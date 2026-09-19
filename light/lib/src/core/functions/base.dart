import 'dart:async';

import 'package:flutter/material.dart';

import '../device/device.dart';

/// 将模块控件接入应用的本机设置和命令路由
class DeviceFunctionBinding<T> {
  const DeviceFunctionBinding({
    required this.read,
    required this.preview,
    required this.commit,
  });

  final T Function() read;
  final void Function(T value) preview;
  final Future<void> Function(T value) commit;
}

class DeviceControlScope extends InheritedWidget {
  const DeviceControlScope({
    required this.bindings,
    required super.child,
    super.key,
  });

  final Map<Type, DeviceFunctionBinding> bindings;

  static DeviceFunctionBinding<T>? binding<T>(
    BuildContext context,
    DeviceFunction<T> function,
  ) {
    return context
            .dependOnInheritedWidgetOfExactType<DeviceControlScope>()
            ?.bindings[function.runtimeType]
        as DeviceFunctionBinding<T>?;
  }

  @override
  bool updateShouldNotify(DeviceControlScope oldWidget) => true;
}

abstract class ValueDeviceFunction<T> extends DeviceFunction<T> {
  ValueDeviceFunction({
    required T initialStatus,
    required this.executeCall,
    this.refreshCall,
  }) : super(initialStatus);

  final FutureOr<bool> Function(Device device, T value) executeCall;
  final FutureOr<bool> Function(Device device)? refreshCall;

  @override
  Future<bool> execute(covariant Device device, T value) async {
    final success = await executeCall(device, value);
    if (success) status = value;
    return success;
  }

  @override
  Future<bool> refresh(covariant Device device) async =>
      await refreshCall?.call(device) ?? false;

  /// 用设备上报的状态更新功能值，绕过执行路径
  ///
  /// 与 [execute] 一样只在拿到真实数据时调用，类型不符会抛出 [TypeError]。
  void applyStatus(Object value) => status = value as T;

  DeviceFunctionBinding<T> control(BuildContext context, Device device) {
    return DeviceControlScope.binding(context, this) ??
        DeviceFunctionBinding<T>(
          read: () => status,
          preview: (value) => status = value,
          commit: (value) async {
            try {
              if (!await execute(device, value)) throw StateError('$label执行失败');
            } catch (error) {
              if (context.mounted) {
                ScaffoldMessenger.maybeOf(context)
                    ?.showSnackBar(SnackBar(content: Text('$label失败：$error')));
              }
            }
          },
        );
  }
}

abstract class BoolDeviceFunction extends ValueDeviceFunction<bool> {
  BoolDeviceFunction({
    super.initialStatus = false,
    required super.executeCall,
    super.refreshCall,
  });
}
