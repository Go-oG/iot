import '../spec/checksum_spec.dart';
import '../spec/wrie_codec_spec.dart';
import '../types.dart';
import 'frame_defaults.dart';
import 'frame_span.dart';

bool isHexDigit(String char) {
  final code = char.codeUnitAt(0);
  return (code >= 0x30 && code <= 0x39) || (code >= 0x41 && code <= 0x46) || (code >= 0x61 && code <= 0x66);
}

int indexOfTopLevel(String text, String target) {
  var depth = 0;
  for (var i = 0; i + target.length <= text.length; i++) {
    final char = text[i];
    if (char == '(') depth++;
    if (char == ')') depth--;
    if (depth == 0 && text.startsWith(target, i)) return i;
  }
  return -1;
}

List<String> splitTopLevel(String text, String separator) {
  final parts = <String>[];
  var depth = 0;
  final current = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    final char = text[i];
    if (char == '(') depth++;
    if (char == ')') depth--;
    if (depth == 0 && char == separator) {
      parts.add(current.toString());
      current.clear();
      continue;
    }
    current.write(char);
  }
  parts.add(current.toString());
  return parts;
}

FormatException templateError(String path, int position, String message, [String? source]) {
  if (source == null) return FormatException('$path: $message');
  final prefix = source.substring(0, position.clamp(0, source.length));
  final line = '\n'.allMatches(prefix).length + 1;
  final column = position - prefix.lastIndexOf('\n');
  return FormatException('$path: $message（$line 行 $column 列）');
}

String? fieldOption(Map<String, String> options, FrameFieldOption option) => options[option.wire];

num? tryNumber(String text) {
  if (text.startsWith('0x') || text.startsWith('0X')) {
    final value = int.tryParse(text.substring(2), radix: 16);
    return value;
  }
  final negative = text.startsWith('-');
  final body = negative ? text.substring(1) : text;
  if (body.startsWith('0x') || body.startsWith('0X')) {
    final value = int.tryParse(body.substring(2), radix: 16);
    return value == null ? null : (negative ? -value : value);
  }
  final value = int.tryParse(text);
  if (value != null) return value;
  return double.tryParse(text);
}

Object parseOptionValue(String text) {
  if (text == 'true') return true;
  if (text == 'false') return false;
  final number = tryNumber(text);
  return number ?? text;
}

int parseSignedInt(String text, String name, int position) {
  final value = tryNumber(text);
  if (value == null || value != value.roundToDouble()) {
    throw FormatException('$name 必须是整数：$text');
  }
  return value.round();
}

/// 简写里的算法名统一小写，读起来更接近协议文档
String algName(CheckSumAlg alg) => alg.wireName.toLowerCase();

String signed(int value) => value >= 0 ? '+$value' : '$value';

String codecTemplate(WireCodecSpec codec) {
  final buffer = StringBuffer(codec.format.wireName);
  if (codec.format.isMultiByte) {
    // 多字节格式显式写出端序，避免默认值带来的歧义
    buffer.write(codec.endian == DataEndian.little ? 'le' : 'be');
  }
  if (codec.scale != 1.0) {
    buffer.write(',scale=${_numberTemplate(codec.scale)}');
  }
  if (codec.offset != 0.0) {
    buffer.write(',offset=${_numberTemplate(codec.offset)}');
  }
  if (codec.fixedLength != null) buffer.write(',len=${codec.fixedLength}');
  if (codec.lengthPrefix != null) {
    buffer.write(',prefix=${codec.lengthPrefix!.name}');
  }
  if (codec.trueValue != 1) buffer.write(',true=${codec.trueValue}');
  if (codec.falseValue != 0) buffer.write(',false=${codec.falseValue}');
  if (codec.item != null) buffer.write(',items=${codecTemplate(codec.item!)}');
  if (codec.fields.isNotEmpty) {
    buffer.write(',fields=${codec.fields.map((field) => '${field.name}:${codecTemplate(field.codec)}').join(';')}');
  }
  return buffer.toString();
}

String _numberTemplate(num value) => value == value.roundToDouble() ? '${value.round()}' : '$value';

String literalTemplate(Object? value) => switch (value) {
  null => '',
  final bool item => '$item',
  final num item => _numberTemplate(item),
  _ => '$value',
};

String nameOf(Map<int, String> names, int? order) {
  final name = order == null ? null : names[order];
  if (name == null) {
    throw StateError('帧字段 order=$order 没有名字，无法写回模板');
  }
  return name;
}

String? checksumSpanTemplate(ChecksumSpec checksum, Map<int, String> names, FrameDefaults defaults) {
  final FrameSpan span;
  if (checksum.fromOrder == null && checksum.toOrder == null) {
    span = const FrameSpan.packet();
  } else if (checksum.fromOrder == checksum.toOrder) {
    span = FrameSpan.field(nameOf(names, checksum.fromOrder));
  } else {
    span = FrameSpan.range(nameOf(names, checksum.fromOrder), nameOf(names, checksum.toOrder));
  }
  return span == defaults.checksumSpanValue ? null : span.template;
}

