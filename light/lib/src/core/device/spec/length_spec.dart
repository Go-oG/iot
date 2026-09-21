
/// 长度字段的计算来源
enum LengthSource {
  packet('packet'),
  field('field'),
  range('range');

  final String wireName;

  const LengthSource(this.wireName);

  static LengthSource valueOf(String value) {
    for (final v in values) {
      if (v.wireName == value) {
        return v;
      }
    }
    throw FormatException('Unsupported length source: $value');
  }
}

class LengthSpec {
  /// packet 表示整帧字节数（含 length 字段与 checksum 字段自身）
  final LengthSource source;

  /// source=field
  final int? fieldOrder;

  /// source=range
  final int? fromOrder;
  final int? toOrder;

  /// 某些协议 length = 实际长度 + 固定值
  final int adjust;

  const LengthSpec({required this.source, this.fieldOrder, this.fromOrder, this.toOrder, this.adjust = 0});

  /// 校验来源与 order 参数是否自洽
  void validate() {
    switch (source) {
      case LengthSource.packet:
        break;
      case LengthSource.field:
        if (fieldOrder == null) {
          throw FormatException('length source=field requires fieldOrder');
        }
        break;
      case LengthSource.range:
        if (fromOrder == null || toOrder == null || fromOrder! > toOrder!) {
          throw FormatException('length source=range requires valid fromOrder/toOrder');
        }
        break;
    }
  }
}
