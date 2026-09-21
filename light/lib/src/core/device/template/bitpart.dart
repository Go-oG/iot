import '../spec/checksum_spec.dart';
import '../spec/frame_condition_spec.dart';
import '../types.dart';
import 'parser.dart';
import 'util.dart';

/// 位域取值来源
enum BitFieldSource {
  constant('constant'),
  value('value'),
  property('property'),
  variable('variable'),
  sequence('sequence');

  final String wireName;

  const BitFieldSource(this.wireName);

  static BitFieldSource valueOf(String value) {
    for (final v in values) {
      if (v.wireName == value) {
        return v;
      }
    }
    throw FormatException('Unsupported bitField source: $value');
  }
}

class BitPart {
  const BitPart({
    required this.bitOffset,
    required this.bitLength,
    required this.source,
    this.value,
    this.name,
    this.condition,
  });

  final int bitOffset;
  final int bitLength;
  final BitFieldSource source;
  final int? value;
  final String? name;
  final FrameConditionSpec? condition;

  static List<BitPart> parseBitParts(String text, int position) {
    final parts = <BitPart>[];
    for (final part in splitTopLevel(text, ';')) {
      final index = part.indexOf(':');
      if (index <= 0) {
        throw FormatException('位域必须写成 位偏移:来源：$part');
      }
      final rangeText = part.substring(0, index).trim();
      var sourceText = part.substring(index + 1).trim();
      FrameConditionSpec? condition;
      final conditionIndex = sourceText.indexOf('?');
      if (conditionIndex >= 0) {
        condition = parseCondition(sourceText.substring(conditionIndex + 1), position);
        sourceText = sourceText.substring(0, conditionIndex).trim();
      }

      final range = rangeText.split('..');
      final bitOffset = int.tryParse(range.first.trim());
      if (bitOffset == null) {
        throw FormatException('位偏移必须是整数：$rangeText');
      }
      // a 表示 1 位，a..b 表示从 a 到 b 的闭区间
      final bitEnd = range.length == 1 ? bitOffset : int.tryParse(range[1].trim());
      if (bitEnd == null || bitEnd < bitOffset) {
        throw FormatException('位区间必须是 a 或 a..b：$rangeText');
      }
      final bitLength = bitEnd - bitOffset + 1;

      final direct = _directBitSource(sourceText);
      if (direct != null) {
        parts.add(BitPart(bitOffset: bitOffset, bitLength: bitLength, source: direct, condition: condition));
        continue;
      }
      if (sourceText.startsWith(constantSource) && sourceText.endsWith(')')) {
        final value = tryNumber(sourceText.substring(constantSource.length, sourceText.length - 1).trim());
        if (value == null) {
          throw FormatException('位域常量必须是整数：$sourceText');
        }
        parts.add(
          BitPart(
            bitOffset: bitOffset,
            bitLength: bitLength,
            source: BitFieldSource.constant,
            value: value.round(),
            condition: condition,
          ),
        );
        continue;
      }
      final propertyName = _qualifiedName(sourceText, [propertyPrefix, propertyQualifier, 'property.']);
      if (propertyName != null) {
        parts.add(
          BitPart(
            bitOffset: bitOffset,
            bitLength: bitLength,
            source: BitFieldSource.property,
            name: propertyName,
            condition: condition,
          ),
        );
        continue;
      }
      final variableName = _qualifiedName(sourceText, [variablePrefix, variableQualifier, 'variable.']);
      if (variableName != null) {
        parts.add(
          BitPart(
            bitOffset: bitOffset,
            bitLength: bitLength,
            source: BitFieldSource.variable,
            name: variableName,
            condition: condition,
          ),
        );
        continue;
      }
      throw FormatException('未知的位域来源：$sourceText');
    }
    return parts;
  }
}

String? _qualifiedName(String text, List<String> prefixes) {
  for (final prefix in prefixes) {
    if (text.startsWith(prefix)) {
      final name = text.substring(prefix.length).trim();
      return name.isEmpty ? null : name;
    }
  }
  return null;
}

/// 位域里不带名字的来源
BitFieldSource? _directBitSource(String text) {
  for (final source in [BitFieldSource.value, BitFieldSource.sequence]) {
    if (source.wireName == text) return source;
  }
  return null;
}

class BitFieldSpec {
  /// 位域最终占用的字节数。
  final int byteLength;

  /// 只影响最终多字节序列化
  /// bitOffset 始终从数值最低位开始计数，0 表示 bit0
  final DataEndian endian;

  final List<BitFieldPartSpec> bits;

  BitFieldSpec({required this.byteLength, this.endian = DataEndian.big, required List<BitFieldPartSpec> bits})
    : bits = _prepareBitFieldParts(bits) {
    if (byteLength <= 0 || byteLength > 8) {
      throw FormatException('bitField byteLength must be 1..8');
    }
    if (bits.isEmpty) {
      throw FormatException('bitField must define at least one part');
    }
    _validateRange();
  }

  void _validateRange() {
    final occupied = <int>{};
    final maxBits = byteLength * 8;
    for (final part in bits) {
      if (part.bitOffset < 0 || part.bitLength <= 0) {
        throw FormatException(
          'Invalid bitField part order=${part.order}: '
          'offset=${part.bitOffset}, length=${part.bitLength}',
        );
      }
      if (part.bitOffset + part.bitLength > maxBits) {
        throw FormatException('bitField part order=${part.order} exceeds $maxBits bits');
      }
      for (var bit = part.bitOffset; bit < part.bitOffset + part.bitLength; bit++) {
        if (!occupied.add(bit)) {
          throw FormatException('bitField bit overlap at bit=$bit');
        }
      }
    }
  }
}

class BitFieldPartSpec {
  final int order;

  final BitFieldSource source;

  final String? property;
  final String? variable;
  final int? value;

  final int bitOffset;
  final int bitLength;

  /// 条件不成立时，该位段按 0 处理。
  final FrameConditionSpec? condition;

  const BitFieldPartSpec({
    required this.order,
    required this.source,
    required this.bitOffset,
    required this.bitLength,
    this.property,
    this.variable,
    this.value,
    this.condition,
  });

  void validate() {
    if (order < 0) {
      throw FormatException('bitField part order must be >= 0: $order');
    }
    switch (source) {
      case BitFieldSource.constant:
        if (value == null) {
          throw FormatException('bitField constant requires value');
        }
        break;
      case BitFieldSource.value:
      case BitFieldSource.sequence:
        break;
      case BitFieldSource.property:
        if (property == null || property!.isEmpty) {
          throw FormatException('bitField property source requires property');
        }
        break;
      case BitFieldSource.variable:
        if (variable == null || variable!.isEmpty) {
          throw FormatException('bitField variable source requires variable');
        }
        break;
    }
  }
}

List<BitFieldPartSpec> _prepareBitFieldParts(List<BitFieldPartSpec> input) {
  final parts = List<BitFieldPartSpec>.of(input)..sort((a, b) => a.order.compareTo(b.order));
  final orders = <int>{};
  for (final part in parts) {
    if (!orders.add(part.order)) {
      throw FormatException('Duplicate bitField part order: ${part.order}');
    }
  }
  return List<BitFieldPartSpec>.unmodifiable(parts);
}
