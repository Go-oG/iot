import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../widgets/device_card.dart';
import '../device/device.dart';
import 'base.dart';

class TemperatureFunction extends ValueDeviceFunction<double> {
  TemperatureFunction({
    super.initialStatus = 31,
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DeviceControlHeading(
          title: '温控',
          icon: Icons.thermostat_rounded,
          color: AppColors.orange,
          subtitle: '目标温度',
          trailing: DeviceControlValue(
            '${binding.read().round()}℃',
            color: AppColors.orange,
          ),
        ),
        const SizedBox(height: 12),
        Slider(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          value: binding.read().clamp(
            minOutput.toDouble(),
            maxOutput.toDouble(),
          ),
          min: minOutput.toDouble(),
          max: maxOutput.toDouble(),
          divisions: maxOutput - minOutput,
          activeColor: AppColors.orange,
          onChanged: binding.preview,
          onChangeEnd: (_) => binding.commit(binding.read()),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '$minOutput℃',
                style: const TextStyle(fontSize: 10, color: AppColors.muted),
              ),
              Text(
                '$maxOutput℃',
                style: const TextStyle(fontSize: 10, color: AppColors.muted),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  DeviceControlGroup get controlGroup => DeviceControlGroup.climate;

  @override
  String get label => "温度(℃)";

  @override
  Priority get priority => Priority.normal;

  int get maxOutput => 80;

  int get minOutput => 20;
}
