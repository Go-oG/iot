import 'package:flutter/material.dart';
import 'package:light/src/core/device/device.dart';
import 'package:light/src/core/functions/base.dart';

import '../../widgets/app_widgets.dart';
import '../../widgets/device_card.dart';


class PowerFunction extends BoolDeviceFunction {
  PowerFunction({
    super.initialStatus,
    required super.executeCall,
    super.refreshCall,
  });

  @override
  Widget buildWidget(
    BuildContext context,
    covariant Device device,
    CardSize size,
  ) {
    final binding = control(context, device);
    return DeviceControlHeading(
      title: '电源',
      icon: Icons.power_settings_new_rounded,
      subtitle: binding.read() ? '当前设置 · 开启' : '当前设置 · 关闭',
      trailing: PowerButton(
        enabled: binding.read(),
        onTap: () async => binding.commit(!binding.read()),
      ),
    );
  }

  @override
  DeviceControlGroup get controlGroup => DeviceControlGroup.primary;

  @override
  String get label => "电源";

  @override
  Priority get priority => Priority.maxHigh;
}
