import '../spec/checksum_spec.dart';
import '../spec/frame_condition_spec.dart';
import '../spec/packer_decode_spec.dart';
import '../spec/wrie_codec_spec.dart';
import '../types.dart';
import 'bitpart.dart';
import 'compiler.dart';
import 'kind.dart';
import 'placeholder.dart';
import 'template_node.dart';
import 'util.dart';

class TemplateParser {
  TemplateParser(this.source, this.path);

  final String source;
  final String path;
  List<TemplateNode> parse() {
    final nodes = <TemplateNode>[];
    var cursor = 0;

    while (cursor < source.length) {
      final placeholderStart = _nextPlaceholder(cursor);
      if (placeholderStart < 0) {
        _parseLiteral(source.substring(cursor), cursor, nodes);
        break;
      }

      _parseLiteral(source.substring(cursor, placeholderStart), cursor, nodes);
      final end = source.indexOf('}', placeholderStart + 2);
      if (end < 0) {
        throw _error('占位符缺少结尾 }', placeholderStart);
      }
      final body = source.substring(placeholderStart + 2, end);
      nodes.add(FieldNode(_parsePlaceholder(body, placeholderStart), placeholderStart));
      cursor = end + 1;
    }

    if (nodes.isEmpty) {
      throw _error('模板为空', 0);
    }
    return nodes;
  }

  /// 查找下一个不在注释里的 ${。
  int _nextPlaceholder(int start) {
    var index = start;
    while (index + 1 < source.length) {
      if (source[index] == '/' && source[index + 1] == '/') {
        final newline = source.indexOf('\n', index + 2);
        if (newline < 0) return -1;
        index = newline + 1;
        continue;
      }
      if (source[index] == r'$' && source[index + 1] == '{') {
        return index;
      }
      index++;
    }
    return -1;
  }

  /// 占位符之间的十六进制字面量，空白和常用分隔符全部忽略。
  void _parseLiteral(String text, int offset, List<TemplateNode> nodes) {
    final digits = StringBuffer();
    var literalStart = offset;
    var index = 0;

    while (index < text.length) {
      final char = text[index];
      if (char == '/' && index + 1 < text.length && text[index + 1] == '/') {
        final newline = text.indexOf('\n', index + 2);
        if (newline < 0) break;
        index = newline + 1;
        continue;
      }
      if (char.trim().isEmpty || char == ':' || char == '-') {
        index++;
        continue;
      }
      if (char == '0' &&
          index + 1 < text.length &&
          (text[index + 1] == 'x' || text[index + 1] == 'X')) {
        index += 2;
        continue;
      }
      if (!isHexDigit(char)) {
        throw _error('模板中不支持的字符：$char', offset + index);
      }
      if (digits.isEmpty) {
        literalStart = offset + index;
      }
      digits.write(char);
      index++;
    }

    final hex = digits.toString();
    if (hex.isEmpty) return;
    if (hex.length.isOdd) {
      throw _error('十六进制字节不完整：$hex', literalStart);
    }
    final bytes = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    nodes.add(LiteralNode(bytes, literalStart));
  }

  FramePlaceholder _parsePlaceholder(String body, int position) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) {
      throw _error('占位符内容为空', position);
    }

    // 条件后缀写在类型之后、选项之前，避免与选项值里的 ? 冲突
    final firstComma = indexOfTopLevel(trimmed, ',');
    final declarationEnd = firstComma < 0 ? trimmed.length : firstComma;
    final conditionIndex = indexOfTopLevel(trimmed.substring(0, declarationEnd), '?');
    final headPart = conditionIndex < 0 ? trimmed : trimmed.substring(0, conditionIndex).trim();
    final condition = conditionIndex < 0 ? null : parseCondition(trimmed.substring(conditionIndex + 1), position);

    final parts = splitTopLevel(headPart, ',');
    final declaration = parts.first.trim();
    final options = <String, String>{};
    for (final part in parts.skip(1)) {
      final index = indexOfTopLevel(part, '=');
      if (index <= 0) {
        throw _error('选项必须写成 key=value：$part', position);
      }
      final rawKey = part.substring(0, index).trim();
      final key = _optionWire(rawKey, position);
      if (options.containsKey(key)) {
        throw _error('选项重复：$rawKey', position);
      }
      options[key] = part.substring(index + 1).trim();
    }

    var head = declaration;
    String? codecText;
    final codecIndex = indexOfTopLevel(declaration, ':');
    if (codecIndex >= 0) {
      head = declaration.substring(0, codecIndex).trim();
      codecText = declaration.substring(codecIndex + 1).trim();
    }

    var kind = Kind.tryParse(head);
    String? label;
    if (kind == null) {
      // 算法名简写：${crc16modbus}
      if (_checksumAlgOf(head) != null) {
        kind = Kind.checksum;
        codecText = head;
      } else if (head.startsWith(propertyPrefix)) {
        kind = Kind.property;
        label = head.substring(propertyPrefix.length).trim();
      } else if (head.startsWith(variablePrefix)) {
        kind = Kind.variable;
        label = head.substring(variablePrefix.length).trim();
      } else {
        throw _error('未知的字段类型：$head', position);
      }
    }

    final dotIndex = head.indexOf('.');
    if (dotIndex >= 0) {
      final name = head.substring(dotIndex + 1).trim();
      if (name.isEmpty) {
        throw _error('字段名不能为空：$head', position);
      }
      label = name;
    }
    if (label == null && (kind == Kind.property || kind == Kind.variable)) {
      final example = kind == Kind.property ? '${propertyPrefix}power' : '${variablePrefix}nonce';
      throw _error('${kind.wire} 必须给出名字，例如 \${$example}', position);
    }

    WireCodecSpec? codec;
    CheckSumAlg? alg;
    String? hex;
    switch (kind) {
      case Kind.checksum:
        if (codecText != null && codecText.isNotEmpty) {
          alg = _checksumAlgOf(codecText);
          if (alg == null) {
            throw _error('未知的校验算法：$codecText', position);
          }
        }
        if (alg == null) {
          throw _error('校验字段需要算法，例如 ${r'${crc16modbus}'}', position);
        }
      case Kind.match:
        final raw = (codecText ?? options['hex'] ?? '').replaceAll(RegExp(r'[\s:-]'), '');
        if (raw.isEmpty || raw.length.isOdd) {
          throw _error('match 需要成对的十六进制字节', position);
        }
        hex = raw.toUpperCase();
      case Kind.value:
      case Kind.property:
      case Kind.variable:
      case Kind.sequence:
      case Kind.timestamp:
      case Kind.length:
      case Kind.bitfield:
      case Kind.skip:
        codec = codecText == null || codecText.isEmpty ? null : _parseCodec(codecText, options, position);
    }

    return FramePlaceholder(
      kind: kind,
      position: position,
      label: label,
      codec: codec,
      codecText: codecText,
      span: fieldOption(options, FrameFieldOption.span),
      start: fieldOption(options, FrameFieldOption.start),
      end: fieldOption(options, FrameFieldOption.end),
      length: fieldOption(options, FrameFieldOption.length),
      adjust: fieldOption(options, FrameFieldOption.adjust) == null
          ? 0
          : parseSignedInt(fieldOption(options, FrameFieldOption.adjust)!, FrameFieldOption.adjust.wire, position),
      at: fieldOption(options, FrameFieldOption.at) == null
          ? null
          : parseSignedInt(fieldOption(options, FrameFieldOption.at)!, FrameFieldOption.at.wire, position),
      mask: fieldOption(options, FrameFieldOption.mask),
      hex: hex,
      alg: alg,
      unit: fieldOption(options, FrameFieldOption.unit) == null
          ? null
          : TimestampUnit.valueOf(fieldOption(options, FrameFieldOption.unit)!),
      condition: condition,
      parts: fieldOption(options, FrameFieldOption.parts) == null
          ? const []
          : BitPart.parseBitParts(fieldOption(options, FrameFieldOption.parts)!, position),
      options: {
        for (final entry in options.entries)
          if (ChecksumOption.valueOf(entry.key) != null) entry.key: parseOptionValue(entry.value),
      },
    );
  }

  FormatException _error(String message, int position) => templateError(path, position, message, source);
}

/// 响应帧模板 → 运行时解码结构
PacketDecodeSpec parseResponseTemplate(
  String source, {
  String? service,
  String? characteristic,
  String path = 'frame',
}) {
  final nodes = TemplateParser(source, path).parse();
  return ResponseCompiler(nodes, path).compile(service: service, characteristic: characteristic);
}

WireCodecSpec _parseCodec(String text, Map<String, String> options, int position) {
  var formatText = text.trim();
  var endian = DataEndian.big;
  final lower = formatText.toLowerCase();
  if (lower.endsWith('le')) {
    formatText = formatText.substring(0, formatText.length - 2);
    endian = DataEndian.little;
  } else if (lower.endsWith('be')) {
    formatText = formatText.substring(0, formatText.length - 2);
    endian = DataEndian.big;
  }
  final format = WireFormat.formatOf(formatText);
  if (format == null) {
    throw FormatException('未知的编码格式：$formatText');
  }

  double scale = 1;
  double offset = 0;
  int? fixedLength;
  LengthPrefix? prefix;
  var trueValue = 1;
  var falseValue = 0;
  WireCodecSpec? item;
  final fields = <WireObjectFieldSpec>[];

  for (final entry in options.entries) {
    final value = entry.value;
    // 只处理编码选项，字段级与校验级选项由调用方读取
    switch (WireCodecOption.of(entry.key)) {
      case WireCodecOption.scale:
        scale = tryNumber(value)?.toDouble() ?? double.nan;
      case WireCodecOption.offset:
        offset = tryNumber(value)?.toDouble() ?? double.nan;
      case WireCodecOption.len:
        fixedLength = parseSignedInt(value, WireCodecOption.len.wire, position);
      case WireCodecOption.prefix:
        prefix = LengthPrefix.valueOf(value);
      case WireCodecOption.trueValue:
        trueValue = parseSignedInt(value, WireCodecOption.trueValue.wire, position);
      case WireCodecOption.falseValue:
        falseValue = parseSignedInt(value, WireCodecOption.falseValue.wire, position);
      case WireCodecOption.endian:
        endian = DataEndian.valueOf(value);
      case WireCodecOption.items:
        item = _parseCodec(value, const {}, position);
      case WireCodecOption.fields:
        for (final field in splitTopLevel(value, ';')) {
          final index = field.indexOf(':');
          if (index <= 0) {
            throw FormatException('object 字段必须写成 name:format：$field');
          }
          fields.add(
            WireObjectFieldSpec(
              order: (fields.length + 1) * 10,
              name: field.substring(0, index).trim(),
              codec: _parseCodec(field.substring(index + 1), const {}, position),
            ),
          );
        }
      case null:
        break;
    }
  }
  if (scale.isNaN || offset.isNaN) {
    throw FormatException('scale / offset 必须是数值');
  }

  final codec = WireCodecSpec(
    format: format,
    endian: endian,
    scale: scale,
    offset: offset,
    fixedLength: fixedLength,
    lengthPrefix: prefix,
    trueValue: trueValue,
    falseValue: falseValue,
    item: item,
    fields: fields,
  );
  codec.validate();
  return codec;
}

// -----------------------------------------------------------------------------
// 条件表达式
// -----------------------------------------------------------------------------
FrameConditionSpec parseCondition(String text, int position) {
  var body = text.trim();
  var negate = false;
  if (body.startsWith(negationKeyword)) {
    negate = true;
    body = body.substring(negationKeyword.length).trim();
  }

  final operators = ['==', '!=', '>=', '<=', '>', '<'];
  for (final operator in operators) {
    final index = indexOfTopLevel(body, operator);
    if (index <= 0) continue;
    final source = _parseConditionSource(body.substring(0, index), position);
    if (negate) {
      throw FormatException('条件中 not 只能用于存在性与位判断');
    }
    return FrameConditionSpec(
      source: source.source,
      operator: switch (operator) {
        '==' => ConditionOperator.eq,
        '!=' => ConditionOperator.ne,
        '>' => ConditionOperator.gt,
        '>=' => ConditionOperator.gte,
        '<' => ConditionOperator.lt,
        _ => ConditionOperator.lte,
      },
      property: source.property,
      variable: source.variable,
      value: parseOptionValue(body.substring(index + operator.length).trim()),
    )..validate();
  }

  // 集合判断：source in (a,b) / source not in (a,b)
  for (final keyword in [notInKeyword, inKeyword]) {
    final index = indexOfTopLevel(body, keyword);
    if (index <= 0) continue;
    final source = _parseConditionSource(body.substring(0, index), position);
    final list = body.substring(index + keyword.length).trim();
    if (!list.startsWith('(') || !list.endsWith(')')) {
      throw FormatException('集合判断需要写成 ($keyword 1,2)');
    }
    final values = splitTopLevel(
      list.substring(1, list.length - 1),
      ',',
    ).map((item) => parseOptionValue(item.trim())).toList();
    return FrameConditionSpec(
      source: source.source,
      operator: keyword == notInKeyword ? ConditionOperator.notIn : ConditionOperator.isIn,
      property: source.property,
      variable: source.variable,
      values: values,
    )..validate();
  }

  final ampersand = indexOfTopLevel(body, '&');
  if (ampersand > 0) {
    final source = _parseConditionSource(body.substring(0, ampersand), position);
    final mask = parseSignedInt(body.substring(ampersand + 1).trim(), FrameFieldOption.mask.wire, position);
    return FrameConditionSpec(
      source: source.source,
      operator: negate ? ConditionOperator.bitClear : ConditionOperator.bitSet,
      property: source.property,
      variable: source.variable,
      mask: mask,
    )..validate();
  }

  final source = _parseConditionSource(body, position);
  return FrameConditionSpec(
    source: source.source,
    operator: negate ? ConditionOperator.notExists : ConditionOperator.exists,
    property: source.property,
    variable: source.variable,
  )..validate();
}

({ConditionSource source, String? property, String? variable}) _parseConditionSource(String text, int position) {
  final body = text.trim();
  for (final source in [ConditionSource.value, ConditionSource.sequence]) {
    if (source.wireName == body) {
      return (source: source, property: null, variable: null);
    }
  }
  if (body.startsWith(propertyPrefix)) {
    return (source: ConditionSource.property, property: body.substring(propertyPrefix.length), variable: null);
  }
  if (body.startsWith(variablePrefix)) {
    return (source: ConditionSource.variable, property: null, variable: body.substring(variablePrefix.length));
  }
  if (body.startsWith(propertyQualifier)) {
    return (source: ConditionSource.property, property: body.substring(propertyQualifier.length), variable: null);
  }
  if (body.startsWith(variableQualifier)) {
    return (source: ConditionSource.variable, property: null, variable: body.substring(variableQualifier.length));
  }
  // 裸名字按属性处理，写在条件里更简洁
  if (body.isNotEmpty && !body.contains(' ')) {
    return (source: ConditionSource.property, property: body, variable: null);
  }
  throw FormatException('无法解析的条件来源：$text');
}

/// 选项键归一化成规范写法，未知键直接报错
String _optionWire(String key, int position) {
  for (final option in FrameFieldOption.values) {
    if (option.matches(key)) return option.wire;
  }
  for (final option in WireCodecOption.values) {
    if (option.matches(key)) return option.wire;
  }
  for (final option in ChecksumOption.values) {
    if (option.matches(key)) return option.wire;
  }
  throw FormatException('未知的选项：$key');
}

/// 校验算法名，用于 ${crc16modbus} 简写
CheckSumAlg? _checksumAlgOf(String text) {
  for (final alg in CheckSumAlg.values) {
    if (alg.matches(text)) return alg;
  }
  return null;
}
