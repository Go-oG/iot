import 'package:flutter/material.dart';

import '../device/device.dart';
import '../protocol/protocol.dart';
import '../protocol/remote_protocol.dart';
import 'base.dart';

/// 定时槽位下发的字段名
enum TimerField implements WireEnum {
  slot('index'),
  enabled('enabled'),
  startHour('startHour'),
  startMinute('startMinute'),
  endHour('endHour'),
  endMinute('endMinute'),
  sunriseSunsetEnabled('sunriseSunsetEnabled'),
  sunriseMinutes('sunriseMinutes'),
  sunsetMinutes('sunsetMinutes');

  const TimerField(this.wire);

  @override
  final String wire;
}

class TimerConfig {
  const TimerConfig({
    required this.index,
    required this.enabled,
    required this.startHour,
    required this.startMinute,
    required this.endHour,
    required this.endMinute,
    required this.sunriseSunsetEnabled,
    required this.sunriseMinutes,
    required this.sunsetMinutes,
  });

  /// 定时区间编号
  ///
  /// 1 = 第一组
  /// 2 = 第二组
  final int index;

  /// 是否启用该定时区间
  final bool enabled;

  final int startHour;
  final int startMinute;

  final int endHour;
  final int endMinute;

  /// 是否启用日出 / 日落渐变
  final bool sunriseSunsetEnabled;

  /// 日出渐亮持续时间，单位：分钟
  final int sunriseMinutes;

  /// 日落渐暗持续时间，单位：分钟
  final int sunsetMinutes;

  Map<String, Object?> toJson() => {
    TimerField.slot.wire: index,
    TimerField.enabled.wire: enabled,
    TimerField.startHour.wire: startHour,
    TimerField.startMinute.wire: startMinute,
    TimerField.endHour.wire: endHour,
    TimerField.endMinute.wire: endMinute,
    TimerField.sunriseSunsetEnabled.wire: sunriseSunsetEnabled,
    TimerField.sunriseMinutes.wire: sunriseMinutes,
    TimerField.sunsetMinutes.wire: sunsetMinutes,
  };

  /// 负载不符合设备约定时抛出 [RemoteCommandRejected]
  factory TimerConfig.fromJson(Map<String, Object?> json) => TimerConfig(
    index: _integerInRange(json[TimerField.slot.wire], 1, 2, TimerField.slot),
    enabled: _boolean(json[TimerField.enabled.wire], TimerField.enabled),
    startHour: _integerInRange(
      json[TimerField.startHour.wire],
      0,
      23,
      TimerField.startHour,
    ),
    startMinute: _integerInRange(
      json[TimerField.startMinute.wire],
      0,
      59,
      TimerField.startMinute,
    ),
    endHour: _integerInRange(
      json[TimerField.endHour.wire],
      0,
      23,
      TimerField.endHour,
    ),
    endMinute: _integerInRange(
      json[TimerField.endMinute.wire],
      0,
      59,
      TimerField.endMinute,
    ),
    sunriseSunsetEnabled: _boolean(
      json[TimerField.sunriseSunsetEnabled.wire],
      TimerField.sunriseSunsetEnabled,
    ),
    sunriseMinutes: _integerInRange(
      json[TimerField.sunriseMinutes.wire],
      0,
      255,
      TimerField.sunriseMinutes,
    ),
    sunsetMinutes: _integerInRange(
      json[TimerField.sunsetMinutes.wire],
      0,
      255,
      TimerField.sunsetMinutes,
    ),
  );

  static int _integerInRange(Object? value, int min, int max, TimerField field) {
    if (value is! int || value < min || value > max) {
      throw RemoteCommandRejected(
        '${field.wire} 必须是 $min-$max 的整数',
        code: GatewayErrorCode.invalidArgument,
      );
    }
    return value;
  }

  static bool _boolean(Object? value, TimerField field) {
    if (value is! bool) {
      throw RemoteCommandRejected(
        '${field.wire} 必须是布尔值',
        code: GatewayErrorCode.invalidArgument,
      );
    }
    return value;
  }
}

class TimerFunction extends ValueDeviceFunction<TimerConfig> {
  TimerFunction({required super.executeCall, super.refreshCall})
    : super(
        initialStatus: const TimerConfig(
          index: 1,
          enabled: false,
          startHour: 8,
          startMinute: 0,
          endHour: 20,
          endMinute: 0,
          sunriseSunsetEnabled: false,
          sunriseMinutes: 0,
          sunsetMinutes: 0,
        ),
      );

  @override
  String get label => '定时';

  @override
  Priority get priority => Priority.low;

  @override
  bool get hasControl => false;

  @override
  Widget buildWidget(BuildContext context, Device device, CardSize size) =>
      const SizedBox.shrink();
}
