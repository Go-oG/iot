// -----------------------------------------------------------------------------
// Wire codec
// -----------------------------------------------------------------------------
import '../types.dart';
import 'checksum_spec.dart';

class WireCodecSpec {
  final WireFormat format;
  final DataEndian endian;

  /// logical = raw * scale + offset
  final double scale;
  final double offset;

  /// string/bytes 可以使用固定长度。
  final int? fixedLength;

  /// string: 前缀表示 byte 长度。
  /// array: 前缀表示 item 数量。
  final LengthPrefix? lengthPrefix;

  final int trueValue;
  final int falseValue;

  /// array
  final WireCodecSpec? item;

  /// object，解析后已经按 order 排序。
  final List<WireObjectFieldSpec> fields;

  final Map<String, dynamic> options;

  WireCodecSpec({
    required this.format,
    this.endian = DataEndian.big,
    this.scale = 1.0,
    this.offset = 0.0,
    this.fixedLength,
    this.lengthPrefix,
    this.trueValue = 1,
    this.falseValue = 0,
    this.item,
    List<WireObjectFieldSpec> fields = const [],
    this.options = const {},
  }) : fields = _prepareObjectFields(fields);

  /// 校验编码参数的适用范围
  void validate() {
    if (scale == 0) {
      throw FormatException('codec scale must not be 0');
    }
    if (fixedLength != null && fixedLength! <= 0) {
      throw FormatException('codec fixedLength must be > 0');
    }
    if (format == WireFormat.array && item == null) {
      throw FormatException('array codec requires item');
    }
    if (format != WireFormat.array && item != null) {
      throw FormatException('item is only allowed for array codec, got ${format.name}');
    }
    if (format == WireFormat.object && fields.isEmpty) {
      throw FormatException('object codec requires fields');
    }
    if (format != WireFormat.object && fields.isNotEmpty) {
      throw FormatException('fields is only allowed for object codec, got ${format.name}');
    }
    if (lengthPrefix != null && format == WireFormat.bool8) {
      throw FormatException('bool8 codec does not support lengthPrefix');
    }
    if (format == WireFormat.array && item!.fixedByteLength == null) {
      throw FormatException('array codec requires fixed-size item codec');
    }
    if (format == WireFormat.object && fixedLength == null) {
      for (final field in fields) {
        if (field.codec.fixedByteLength == null) {
          throw FormatException('object codec requires fixed-size field codec: ${field.name}');
        }
      }
    }
  }

  int? get fixedByteLength {
    switch (format) {
      case WireFormat.bool8:
      case WireFormat.uint8:
      case WireFormat.int8:
        return 1;
      case WireFormat.uint16:
      case WireFormat.int16:
        return 2;
      case WireFormat.uint32:
      case WireFormat.int32:
      case WireFormat.float32:
        return 4;
      case WireFormat.uint64:
      case WireFormat.int64:
      case WireFormat.float64:
        return 8;
      case WireFormat.utf8:
      case WireFormat.ascii:
      case WireFormat.bytes:
        if (lengthPrefix != null) return null;
        return fixedLength;
      case WireFormat.object:
        if (lengthPrefix != null) return null;
        var total = 0;
        for (final field in fields) {
          final size = field.codec.fixedByteLength;
          if (size == null) return null;
          total += size;
        }
        return total;
      case WireFormat.array:
        return null;
    }
  }
}

class WireObjectFieldSpec {
  final int order;
  final String name;
  final WireCodecSpec codec;

  const WireObjectFieldSpec({required this.order, required this.name, required this.codec});
}

List<WireObjectFieldSpec> _prepareObjectFields(List<WireObjectFieldSpec> input) {
  final fields = List<WireObjectFieldSpec>.of(input)..sort((a, b) => a.order.compareTo(b.order));
  final orders = <int>{};
  for (final field in fields) {
    if (!orders.add(field.order)) {
      throw FormatException('Duplicate object field order: ${field.order}');
    }
  }
  return List<WireObjectFieldSpec>.unmodifiable(fields);
}
