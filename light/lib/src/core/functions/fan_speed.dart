import 'package:flutter/material.dart';
import 'package:light/src/core/device/device.dart';
import 'package:light/src/core/functions/base.dart';
import 'package:light/src/core/protocol/wire.dart';

import '../../app/theme.dart';
import '../../shared/device_control_widgets.dart';

enum FanSpeed implements WireEnum {
  low(0x01, 'low'),
  high(0x02, 'high');

  const FanSpeed(this.value, this.wire);

  /// AT5 协议里的档位字节
  final int value;

  /// 通用设备配置里的档位取值
  @override
  final String wire;

  static FanSpeed? fromValue(int value) {
    for (final speed in values) {
      if (speed.value == value) {
        return speed;
      }
    }
    return null;
  }

  static FanSpeed? valueOf(Object? raw) => wireValueOf(values, raw);
}

class FanSpeedFunction extends ValueDeviceFunction<FanSpeed> {
  FanSpeedFunction({
    super.initialStatus = FanSpeed.low,
    required super.executeCall,
    super.refreshCall,
  });

  @override
  String get label => "风速";

  @override
  Priority get priority => Priority.normal;

  @override
  Widget buildWidget(
    BuildContext context,
    covariant Device<dynamic> device,
    CardSize size,
  ) {
    final binding = control(context, device);
    final isHigh = binding.read() == FanSpeed.high;
    return DeviceControlHeading(
      title: '风扇',
      icon: Icons.air_rounded,
      subtitle: isHigh ? '当前档位 · 高速' : '当前档位 · 低速',
      trailing: Switch(
        value: isHigh,
        onChanged: (value) =>
            binding.commit(value ? FanSpeed.high : FanSpeed.low),
      ),
    );
  }

  @override
  DeviceControlGroup get controlGroup => DeviceControlGroup.climate;
}

class FanSpeedFunction2 extends ValueDeviceFunction<int> {
  FanSpeedFunction2({
    super.initialStatus = 0,
    required super.executeCall,
    super.refreshCall,
  });

  @override
  Widget buildWidget(
    BuildContext context,
    covariant Device<dynamic> device,
    CardSize size,
  ) {
    final binding = control(context, device);
    final value = binding.read();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DeviceControlHeading(
          title: '风速调节',
          icon: Icons.air_rounded,
          trailing: DeviceControlValue('$value%'),
        ),
        const SizedBox(height: 12),
        Slider(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          value: value.clamp(minOutput, maxOutput).toDouble(),
          min: minOutput.toDouble(),
          max: maxOutput.toDouble(),
          divisions: maxOutput - minOutput,
          activeColor: AppColors.blue,
          onChanged: (value) => binding.preview(value.round()),
          onChangeEnd: (_) => binding.commit(binding.read()),
        ),
      ],
    );
  }

  @override
  String get label => "风速调节";

  @override
  DeviceControlGroup get controlGroup => DeviceControlGroup.climate;

  @override
  Priority get priority => Priority.normal;

  int get maxOutput => 100;

  int get minOutput => 0;
}

/// 温控与风速共用一条协议指令时使用的组合功能
class TemperatureFanState {
  const TemperatureFanState({
    required this.temperature,
    required this.fanSpeed,
  });

  final int temperature;
  final FanSpeed fanSpeed;
}

class TemperatureFanFunction extends ValueDeviceFunction<TemperatureFanState> {
  TemperatureFanFunction({required super.executeCall})
    : super(
        initialStatus: const TemperatureFanState(
          temperature: 31,
          fanSpeed: FanSpeed.low,
        ),
      );

  @override
  String get label => '温度与风扇';

  @override
  Priority get priority => Priority.normal;

  @override
  bool get hasControl => false;

  @override
  Widget buildWidget(BuildContext context, Device device, CardSize size) =>
      const SizedBox.shrink();
}
