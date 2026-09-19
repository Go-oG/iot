import 'package:flutter/material.dart';
import 'package:light/src/core/device/device.dart';
import 'package:light/src/core/protocol/wire.dart';

import '../../app/theme.dart';
import '../../widgets/app_widgets.dart';
import '../../widgets/device_card.dart';
import 'base.dart';

class LightState {
  static const mixed = LightState(red: 44, green: 44, blue: 44, white: 44, uv: 44);

  static const greenLight = LightState(red: 32, green: 42, blue: 42, white: 42, uv: 42);

  static const redLight = LightState(red: 63, green: 47, blue: 63, white: 63, uv: 63);

  const LightState({required this.red, required this.green, required this.blue, required this.white, required this.uv});

  final int red;
  final int green;
  final int blue;
  final int white;
  final int uv;

  /// 软件界面中的“功率”目前确认等于五路亮度平均值
  int get powerPercent {
    return ((red + green + blue + white + uv) / 5).round();
  }

  int get peak => [red, green, blue, white, uv].reduce((a, b) => a > b ? a : b);

  /// 五路通道的状态结构，与通用设备配置里的 `light.status` 一致
  Map<String, Object> toJson() => {for (final channel in LightChannel.values) channel.wire: levelOf(channel)};

  int levelOf(LightChannel channel) => switch (channel) {
    LightChannel.red => red,
    LightChannel.green => green,
    LightChannel.blue => blue,
    LightChannel.white => white,
    LightChannel.uv => uv,
  };

  LightState withChannel(LightChannel channel, int value) => switch (channel) {
    LightChannel.red => copyWith(red: value),
    LightChannel.green => copyWith(green: value),
    LightChannel.blue => copyWith(blue: value),
    LightChannel.white => copyWith(white: value),
    LightChannel.uv => copyWith(uv: value),
  };

  LightState limitedTo(int limit) {
    final maximum = limit.clamp(1, 100);
    if (peak <= maximum) return this;
    return _scaled(maximum / peak);
  }

  LightState _scaled(double scale) => LightState(
    red: (red * scale).round().clamp(0, 100),
    green: (green * scale).round().clamp(0, 100),
    blue: (blue * scale).round().clamp(0, 100),
    white: (white * scale).round().clamp(0, 100),
    uv: (uv * scale).round().clamp(0, 100),
  );

  // 总亮度按五路比例缩放，达到单路上限后保持配色
  LightState withPowerPercent(int value, {int limit = 100}) {
    final target = value.clamp(0, 100);
    final maximum = limit.clamp(1, 100);
    final average = (red + green + blue + white + uv) / 5;
    if (average == 0) {
      return LightState(red: 0, green: 0, blue: 0, white: (target * 5).clamp(0, maximum), uv: 0);
    }
    final requested = target / average;
    return _scaled(requested > maximum / peak ? maximum / peak : requested);
  }

  LightState copyWith({int? red, int? green, int? blue, int? white, int? uv}) {
    return LightState(
      red: red ?? this.red,
      green: green ?? this.green,
      blue: blue ?? this.blue,
      white: white ?? this.white,
      uv: uv ?? this.uv,
    );
  }

  @override
  String toString() {
    return 'At5LightState('
        'red: $red, '
        'green: $green, '
        'blue: $blue, '
        'white: $white, '
        'uv: $uv'
        ')';
  }
}

enum LightChannel implements WireEnum {
  red('red'),
  green('green'),
  blue('blue'),
  white('white'),
  uv('uv');

  const LightChannel(this.wire);

  @override
  final String wire;

  static LightChannel? valueOf(Object? raw) => wireValueOf(values, raw);
}

class LightControlBinding extends DeviceFunctionBinding<LightState> {
  const LightControlBinding({
    required super.read,
    required super.preview,
    required super.commit,
    required this.outputLimit,
    required this.beginBrightness,
    required this.changeBrightness,
    required this.commitBrightness,
  });

  final int outputLimit;
  final VoidCallback beginBrightness;
  final ValueChanged<double> changeBrightness;
  final Future<void> Function() commitBrightness;
}

class LightFunction extends ValueDeviceFunction<LightState> {
  LightFunction({
    super.initialStatus = const LightState(red: 15, green: 15, blue: 17, white: 25, uv: 0),
    required super.executeCall,
    super.refreshCall,
  });

  LightState? _brightnessSource;

  @override
  Widget buildWidget(BuildContext context, Device device, CardSize size) {
    final binding = control(context, device);
    final value = binding.read();
    final options = binding is LightControlBinding ? binding : null;
    final limit = options?.outputLimit ?? 100;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DeviceControlHeading(
          title: '灯光亮度',
          icon: Icons.light_mode_rounded,
          subtitle: '保持配色比例 · 每路上限 $limit%',
          trailing: DeviceControlValue('${value.powerPercent}%'),
        ),
        const SizedBox(height: 12),
        Slider(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          value: value.powerPercent.toDouble(),
          min: 0,
          max: 100,
          onChangeStart: (_) {
            _brightnessSource = binding.read();
            options?.beginBrightness();
          },
          onChanged: (v) {
            if (options != null) {
              options.changeBrightness(v);
            } else {
              binding.preview((_brightnessSource ?? binding.read()).withPowerPercent(v.round(), limit: limit));
            }
          },
          onChangeEnd: (_) async {
            _brightnessSource = null;
            if (options != null) {
              await options.commitBrightness();
            } else {
              await binding.commit(binding.read());
            }
          },
        ),
        if (size == CardSize.large) ...[
          const Padding(padding: EdgeInsets.only(top: 12, bottom: 16), child: Divider()),
          const Text(
            '五路调色',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.muted),
          ),
          const SizedBox(height: 10),
          for (final channel in LightChannel.values)
            ChannelSlider(
              label: switch (channel) {
                LightChannel.red => 'Red',
                LightChannel.green => 'Green',
                LightChannel.blue => 'Blue',
                LightChannel.white => 'White',
                LightChannel.uv => 'UV',
              },
              icon: channel == LightChannel.white ? Icons.blur_on_rounded : Icons.light_mode_rounded,
              color: switch (channel) {
                LightChannel.red => const Color(0xFFFF3131),
                LightChannel.green => const Color(0xFF00C765),
                LightChannel.blue => const Color(0xFF2585FF),
                LightChannel.white => const Color(0xFF9BA9C4),
                LightChannel.uv => const Color(0xFFAD50EE),
              },
              value: switch (channel) {
                LightChannel.red => value.red,
                LightChannel.green => value.green,
                LightChannel.blue => value.blue,
                LightChannel.white => value.white,
                LightChannel.uv => value.uv,
              },
              max: limit.toDouble(),
              onChanged: (v) => binding.preview(binding.read().withChannel(channel, v.round().clamp(0, limit))),
              onChangeEnd: () => binding.commit(binding.read()),
            ),
        ],
      ],
    );
  }

  @override
  DeviceControlGroup get controlGroup => DeviceControlGroup.lighting;

  @override
  String get label => '灯光调节';

  @override
  Priority get priority => Priority.high;

  void setChannel(LightChannel channel, int value) => status = status.withChannel(channel, value.clamp(0, 100));
}
