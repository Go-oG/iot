import '../protocol/wire.dart';

/// 通用设备配置里声明的功能类型
///
/// 设备配置的 `functions[].type`、命令字段的 `target` 与写命令绑定都用它表达，
/// 只有序列化配置时才写回 [wire]。
enum ConfigurableFunction implements WireEnum {
  power('power', '电源', '开关状态'),
  light('light', '五路灯光', '红、绿、蓝、白与 UV 通道'),
  temperature('temperature', '温控', '目标温度 20～80℃'),
  fanSpeed('fanSpeed', '档位风扇', '低速与高速切换'),
  fanSpeedPercent('fanSpeedPercent', '风速调节', '连续调节 0～100%'),
  timer('timer', '定时', '时间段与日出日落渐变');

  const ConfigurableFunction(this.wire, this.label, this.description);

  @override
  final String wire;

  final String label;
  final String description;

  static ConfigurableFunction? valueOf(Object? raw) =>
      wireValueOf(values, raw);
}
