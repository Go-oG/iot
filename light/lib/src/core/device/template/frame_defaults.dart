import 'frame_span.dart';


/// 帧默认值
/// 裸写 `${length:u8}` 与 `${crc16modbus}` 时使用这里的默认跨度，不同协议对
/// 「长度」的定义不一致：有的算整帧、有的只算载荷，因此在模型里声明一次，
/// 单帧需要覆盖时用 `span=` 选项
class FrameDefaults {
  const FrameDefaults({this.lengthSpan = FrameSpan.bodyTemplate, this.checksumSpan = FrameSpan.packetTemplate});

  /// 长度字段默认统计范围：body（本字段之后到最后一个业务字段）、all（整帧）、
  /// field(名字)、a..b
  final String lengthSpan;

  /// 校验字段默认统计范围：all（帧首到本字段之前）、a..b
  final String checksumSpan;

  bool get isDefault => lengthSpan == FrameSpan.bodyTemplate && checksumSpan == FrameSpan.packetTemplate;

  factory FrameDefaults.fromJson(Map<String, dynamic> json) {
    return FrameDefaults(
      lengthSpan: json['lengthSpan'] == null
          ? FrameSpan.bodyTemplate
          : FrameSpan.parse(json['lengthSpan'] as String, path: 'frame.lengthSpan').template,
      checksumSpan: json['checksumSpan'] == null
          ? FrameSpan.packetTemplate
          : FrameSpan.parse(json['checksumSpan'] as String, path: 'frame.checksumSpan').template,
    );
  }

  FrameSpan get lengthSpanValue => FrameSpan.parse(lengthSpan, path: 'frame.lengthSpan');

  FrameSpan get checksumSpanValue => FrameSpan.parse(checksumSpan, path: 'frame.checksumSpan');

  Map<String, dynamic> toJson() => {'lengthSpan': lengthSpan, 'checksumSpan': checksumSpan};
}
