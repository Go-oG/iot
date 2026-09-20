import 'device_model.dart';

/// 语法前缀：属性引用、运行时变量与位域常量
const String propertyPrefix = '@';
const String variablePrefix = r'$';
const String propertyQualifier = 'property.';
const String variableQualifier = 'variable.';
const String constantSource = 'const(';

/// 条件表达式里的关键字
const String negationKeyword = 'not ';
const String inKeyword = ' in ';
const String notInKeyword = ' not in ';

/// 字段级选项。wire 是帧模板里的规范写法
enum FrameFieldOption {
  span('span', {}),
  start('start', {}),
  end('end', {}),
  length('length', {}),
  adjust('adjust', {}),
  at('at', {}),
  mask('mask', {}),
  hex('hex', {}),
  name('name', {}),
  unit('unit', {}),
  parts('parts', {});

  const FrameFieldOption(this.wire, this.aliases);

  final String wire;
  final Set<String> aliases;

  bool matches(String value) => wire == value || aliases.contains(value);
}

/// 编码选项
enum WireCodecOption {
  scale('scale', {}),
  offset('offset', {}),
  len('len', {}),
  prefix('prefix', {}),
  trueValue('true', {}),
  falseValue('false', {}),
  endian('endian', {}),
  items('items', {}),
  fields('fields', {});

  const WireCodecOption(this.wire, this.aliases);

  final String wire;
  final Set<String> aliases;

  bool matches(String value) => wire == value || aliases.contains(value);
}

/// 校验算法参数，键名与 ChecksumCodec 读取的 options 一致
enum ChecksumOption {
  polynomial('polynomial', {'poly'}),
  init('init', {}),
  xorOut('xorOut', {'xorout'}),
  reflectIn('reflectIn', {'reflectin'}),
  reflectOut('reflectOut', {'reflectout'});

  const ChecksumOption(this.wire, this.aliases);

  final String wire;
  final Set<String> aliases;

  bool matches(String value) => wire == value || aliases.contains(value);
}

/// 帧默认值：设备模型级配置
///
/// 裸写 `${length:u8}` 与 `${crc16modbus}` 时使用这里的默认跨度，不同协议对
/// 「长度」的定义不一致：有的算整帧、有的只算载荷，因此在模型里声明一次，
/// 单帧需要覆盖时用 `span=` 选项
class FrameDefaults {
  const FrameDefaults({
    this.lengthSpan = FrameSpan.bodyTemplate,
    this.checksumSpan = FrameSpan.packetTemplate,
  });

  /// 长度字段默认统计范围：body（本字段之后到最后一个业务字段）、all（整帧）、
  /// field(名字)、a..b
  final String lengthSpan;

  /// 校验字段默认统计范围：all（帧首到本字段之前）、a..b
  final String checksumSpan;

  bool get isDefault =>
      lengthSpan == FrameSpan.bodyTemplate &&
      checksumSpan == FrameSpan.packetTemplate;

  factory FrameDefaults.fromJson(Map<String, dynamic> json) {
    return FrameDefaults(
      lengthSpan: json['lengthSpan'] == null
          ? FrameSpan.bodyTemplate
          : FrameSpan.parse(
              json['lengthSpan'] as String,
              path: 'frame.lengthSpan',
            ).template,
      checksumSpan: json['checksumSpan'] == null
          ? FrameSpan.packetTemplate
          : FrameSpan.parse(
              json['checksumSpan'] as String,
              path: 'frame.checksumSpan',
            ).template,
    );
  }

  FrameSpan get lengthSpanValue =>
      FrameSpan.parse(lengthSpan, path: 'frame.lengthSpan');

  FrameSpan get checksumSpanValue =>
      FrameSpan.parse(checksumSpan, path: 'frame.checksumSpan');

  Map<String, dynamic> toJson() => {
    'lengthSpan': lengthSpan,
    'checksumSpan': checksumSpan,
  };
}

/// 帧模板：把一行字符串编译成运行时的帧结构，或把帧结构写回模板
///
/// 请求方向：字面量是常量，占位符按出现顺序决定 order，跨度按名字引用
/// 响应方向：字面量自动成为匹配锚点，占位符用 at= 表示绝对偏移
class FrameTemplate {
  const FrameTemplate._();

  /// 请求帧模板 → 运行时编码结构
  static PacketEncodeSpec parseRequest(
    String source, {
    FrameDefaults defaults = const FrameDefaults(),
    String path = 'frame',
  }) {
    final nodes = _TemplateParser(source, path).parse();
    return _RequestCompiler(nodes, defaults, path).compile();
  }

  /// 响应帧模板 → 运行时解码结构
  static PacketDecodeSpec parseResponse(
    String source, {
    String? service,
    String? characteristic,
    String path = 'frame',
  }) {
    final nodes = _TemplateParser(source, path).parse();
    return _ResponseCompiler(nodes, path).compile(
      service: service,
      characteristic: characteristic,
    );
  }

  /// 编码结构 → 规范模板，用于模型序列化、编辑器与迁移
  static String writeRequest(
    PacketEncodeSpec spec, {
    FrameDefaults defaults = const FrameDefaults(),
  }) {
    return _RequestWriter(spec.fields, defaults).write();
  }

  /// 解码结构 → 规范模板
  static String writeResponse(PacketDecodeSpec spec) {
    return _ResponseWriter(spec).write();
  }
}

// -----------------------------------------------------------------------------
// 节点
// -----------------------------------------------------------------------------
sealed class _Node {
  const _Node(this.position);

  /// 模板内的字符位置，用于错误提示
  final int position;
}

/// 一段字面量字节
class _LiteralNode extends _Node {
  const _LiteralNode(this.bytes, super.position);

  final List<int> bytes;
}

/// 一个 ${...} 占位符
class _FieldNode extends _Node {
  const _FieldNode(this.placeholder, super.position);

  final _Placeholder placeholder;
}

/// 模板占位符的类型。wire 是规范写法，aliases 是简写
enum _Kind {
  value('value', 'value', {}),
  property('property', null, {'prop'}),
  variable('variable', null, {'var'}),
  sequence('sequence', 'seq', {'seq'}),
  timestamp('timestamp', 'ts', {'ts'}),
  length('length', 'len', {'len'}),
  checksum('checksum', 'crc', {'crc'}),
  bitfield('bitfield', 'bits', {'bits'}),
  match('match', null, {}),
  skip('skip', null, {});

  const _Kind(this.wire, this.defaultLabel, this.aliases);

  final String wire;

  /// 字段默认名，跨度与校验范围按它引用
  final String? defaultLabel;
  final Set<String> aliases;

  bool matches(String value) => wire == value || aliases.contains(value);

  /// 接受 `value`、`property.mode` 这类写法，返回类型本身
  static _Kind? tryParse(String head) {
    final dot = head.indexOf('.');
    final name = dot < 0 ? head : head.substring(0, dot);
    for (final kind in values) {
      if (kind.matches(name)) return kind;
    }
    return null;
  }
}

class _Placeholder {
  _Placeholder({
    required this.kind,
    required this.position,
    this.label,
    this.codec,
    this.codecText,
    this.span,
    this.start,
    this.end,
    this.length,
    this.adjust = 0,
    this.at,
    this.mask,
    this.hex,
    this.unit,
    this.alg,
    this.condition,
    this.parts = const [],
    this.options = const {},
  });

  final _Kind kind;
  final int position;

  /// kind.property / kind.variable 的属性或变量名，其余类型的字段标签
  final String? label;
  final WireCodecSpec? codec;
  final String? codecText;

  /// length / checksum 的跨度写法
  final String? span;

  /// 响应校验字段的统计范围
  final String? start;
  final String? end;
  final String? length;

  /// length 的固定偏移
  final int adjust;

  /// 响应方向的绝对偏移，支持负数
  final int? at;
  final String? mask;
  final String? hex;
  final TimestampUnit? unit;
  final CheckSumAlg? alg;
  final FrameConditionSpec? condition;
  final List<_BitPart> parts;

  /// 校验算法的额外参数
  final Map<String, dynamic> options;
}

class _BitPart {
  const _BitPart({
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
}

// -----------------------------------------------------------------------------
// 模板解析
// -----------------------------------------------------------------------------
class _TemplateParser {
  _TemplateParser(this.source, this.path);

  final String source;
  final String path;
  int _index = 0;

  List<_Node> parse() {
    final nodes = <_Node>[];
    final literal = <int>[];
    var literalStart = 0;
    final digits = StringBuffer();

    void flushLiteral() {
      if (digits.isNotEmpty) {
        throw _error('十六进制字节不完整：$digits', literalStart);
      }
      if (literal.isNotEmpty) {
        nodes.add(_LiteralNode(List<int>.of(literal), literalStart));
        literal.clear();
      }
    }

    void flushDigits() {
      if (digits.isEmpty) return;
      final text = digits.toString();
      if (text.length.isOdd) {
        throw _error('十六进制字节不完整：$text', _index - text.length);
      }
      for (var i = 0; i < text.length; i += 2) {
        literal.add(int.parse(text.substring(i, i + 2), radix: 16));
      }
      digits.clear();
    }

    while (_index < source.length) {
      final char = source[_index];

      if (char == '/' && _peek(1) == '/') {
        flushDigits();
        while (_index < source.length && source[_index] != '\n') {
          _index++;
        }
        continue;
      }

      if (char.trim().isEmpty || char == ':' || char == '-') {
        flushDigits();
        // 空白是字面量字段的分隔，'AA55 05 00' 会被写成三个常量字段
        if (char.trim().isEmpty) flushLiteral();
        _index++;
        continue;
      }

      if (char == r'$' && _peek(1) == '{') {
        flushDigits();
        flushLiteral();
        final start = _index;
        final end = source.indexOf('}', _index);
        if (end < 0) {
          throw _error('占位符缺少结尾 }', start);
        }
        final body = source.substring(_index + 2, end);
        nodes.add(_FieldNode(_parsePlaceholder(body, start), start));
        _index = end + 1;
        continue;
      }

      if (char == '0' && (_peek(1) == 'x' || _peek(1) == 'X')) {
        flushDigits();
        if (literal.isEmpty) literalStart = _index;
        _index += 2;
        continue;
      }

      if (_isHexDigit(char)) {
        if (literal.isEmpty && digits.isEmpty) literalStart = _index;
        digits.write(char);
        _index++;
        continue;
      }

      throw _error('模板中不支持的字符：$char', _index);
    }

    flushDigits();
    flushLiteral();
    if (nodes.isEmpty) {
      throw _error('模板为空', 0);
    }
    return nodes;
  }

  String? _peek(int offset) {
    final index = _index + offset;
    return index < source.length ? source[index] : null;
  }

  _Placeholder _parsePlaceholder(String body, int position) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) {
      throw _error('占位符内容为空', position);
    }

    // 条件后缀写在类型之后、选项之前，避免与选项值里的 ? 冲突
    final firstComma = _indexOfTopLevel(trimmed, ',');
    final declarationEnd = firstComma < 0 ? trimmed.length : firstComma;
    final conditionIndex = _indexOfTopLevel(
      trimmed.substring(0, declarationEnd),
      '?',
    );
    final headPart = conditionIndex < 0
        ? trimmed
        : trimmed.substring(0, conditionIndex).trim();
    final condition = conditionIndex < 0
        ? null
        : _parseCondition(trimmed.substring(conditionIndex + 1), position);

    final parts = _splitTopLevel(headPart, ',');
    final declaration = parts.first.trim();
    final options = <String, String>{};
    for (final part in parts.skip(1)) {
      final index = _indexOfTopLevel(part, '=');
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
    final codecIndex = _indexOfTopLevel(declaration, ':');
    if (codecIndex >= 0) {
      head = declaration.substring(0, codecIndex).trim();
      codecText = declaration.substring(codecIndex + 1).trim();
    }

    var kind = _Kind.tryParse(head);
    String? label;
    if (kind == null) {
      // 算法名简写：${crc16modbus}
      if (_checksumAlgOf(head) != null) {
        kind = _Kind.checksum;
        codecText = head;
      } else if (head.startsWith(propertyPrefix)) {
        kind = _Kind.property;
        label = head.substring(propertyPrefix.length);
      } else if (head.startsWith(variablePrefix)) {
        kind = _Kind.variable;
        label = head.substring(variablePrefix.length);
      }
      if (kind == null) {
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
    if (label == null && (kind == _Kind.property || kind == _Kind.variable)) {
      final example = kind == _Kind.property
          ? '${propertyPrefix}power'
          : '${variablePrefix}nonce';
      throw _error('${kind.wire} 必须给出名字，例如 \${$example}', position);
    }

    WireCodecSpec? codec;
    CheckSumAlg? alg;
    String? hex;
    switch (kind) {
      case _Kind.checksum:
        if (codecText != null && codecText.isNotEmpty) {
          alg = _checksumAlgOf(codecText);
          if (alg == null) {
            throw _error('未知的校验算法：$codecText', position);
          }
        }
        if (alg == null) {
          throw _error('校验字段需要算法，例如 ${r'${crc16modbus}'}', position);
        }
      case _Kind.match:
        final raw = (codecText ?? options['hex'] ?? '').replaceAll(
          RegExp(r'[\s:-]'),
          '',
        );
        if (raw.isEmpty || raw.length.isOdd) {
          throw _error('match 需要成对的十六进制字节', position);
        }
        hex = raw.toUpperCase();
      case _Kind.value:
      case _Kind.property:
      case _Kind.variable:
      case _Kind.sequence:
      case _Kind.timestamp:
      case _Kind.length:
      case _Kind.bitfield:
      case _Kind.skip:
        codec = codecText == null || codecText.isEmpty
            ? null
            : _parseCodec(codecText, options, position);
    }

    return _Placeholder(
      kind: kind,
      position: position,
      label: label,
      codec: codec,
      codecText: codecText,
      span: _fieldOption(options, FrameFieldOption.span),
      start: _fieldOption(options, FrameFieldOption.start),
      end: _fieldOption(options, FrameFieldOption.end),
      length: _fieldOption(options, FrameFieldOption.length),
      adjust: _fieldOption(options, FrameFieldOption.adjust) == null
          ? 0
          : _parseSignedInt(
              _fieldOption(options, FrameFieldOption.adjust)!,
              FrameFieldOption.adjust.wire,
              position,
            ),
      at: _fieldOption(options, FrameFieldOption.at) == null
          ? null
          : _parseSignedInt(
              _fieldOption(options, FrameFieldOption.at)!,
              FrameFieldOption.at.wire,
              position,
            ),
      mask: _fieldOption(options, FrameFieldOption.mask),
      hex: hex,
      alg: alg,
      unit: _fieldOption(options, FrameFieldOption.unit) == null
          ? null
          : TimestampUnit.valueOf(
              _fieldOption(options, FrameFieldOption.unit)!,
            ),
      condition: condition,
      parts: _fieldOption(options, FrameFieldOption.parts) == null
          ? const []
          : _parseBitParts(
              _fieldOption(options, FrameFieldOption.parts)!,
              position,
            ),
      options: {
        for (final entry in options.entries)
          if (_checksumOptionOf(entry.key) != null)
            entry.key: _parseOptionValue(entry.value),
      },
    );
  }

  FormatException _error(String message, int position) =>
      _templateError(path, position, message, source);

}

/// 校验算法名，用于 ${crc16modbus} 简写
CheckSumAlg? _checksumAlgOf(String text) {
  for (final alg in CheckSumAlg.values) {
    if (alg.matches(text)) return alg;
  }
  return null;
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

String? _fieldOption(Map<String, String> options, FrameFieldOption option) =>
    options[option.wire];

ChecksumOption? _checksumOptionOf(String key) {
  for (final option in ChecksumOption.values) {
    if (option.matches(key)) return option;
  }
  return null;
}

Object _parseOptionValue(String text) {
  if (text == 'true') return true;
  if (text == 'false') return false;
  final number = _tryNumber(text);
  return number ?? text;
}

num? _tryNumber(String text) {
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

int _parseSignedInt(String text, String name, int position) {
  final value = _tryNumber(text);
  if (value == null || value != value.roundToDouble()) {
    throw FormatException('$name 必须是整数：$text');
  }
  return value.round();
}

int _indexOfTopLevel(String text, String target) {
  var depth = 0;
  for (var i = 0; i + target.length <= text.length; i++) {
    final char = text[i];
    if (char == '(') depth++;
    if (char == ')') depth--;
    if (depth == 0 && text.startsWith(target, i)) return i;
  }
  return -1;
}

List<String> _splitTopLevel(String text, String separator) {
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

bool _isHexDigit(String char) {
  final code = char.codeUnitAt(0);
  return (code >= 0x30 && code <= 0x39) ||
      (code >= 0x41 && code <= 0x46) ||
      (code >= 0x61 && code <= 0x66);
}

FormatException _templateError(String path, int position, String message, [String? source]) {
  if (source == null) return FormatException('$path: $message');
  final prefix = source.substring(0, position.clamp(0, source.length));
  final line = '\n'.allMatches(prefix).length + 1;
  final column = position - prefix.lastIndexOf('\n');
  return FormatException('$path: $message（$line 行 $column 列）');
}

// -----------------------------------------------------------------------------
// 编解码配置解析
// -----------------------------------------------------------------------------
ValueFormat? _formatOf(String text) {
  final normalized = text.toLowerCase();
  for (final format in ValueFormat.values) {
    if (format.matches(normalized)) return format;
  }
  return null;
}

bool _isMultiByte(ValueFormat format) => switch (format) {
  ValueFormat.uint16 ||
  ValueFormat.int16 ||
  ValueFormat.uint32 ||
  ValueFormat.int32 ||
  ValueFormat.uint64 ||
  ValueFormat.int64 ||
  ValueFormat.float32 ||
  ValueFormat.float64 => true,
  _ => false,
};

WireCodecSpec _parseCodec(
  String text,
  Map<String, String> options,
  int position,
) {
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
  final format = _formatOf(formatText);
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
    switch (_codecOptionOf(entry.key)) {
      case WireCodecOption.scale:
        scale = _tryNumber(value)?.toDouble() ?? double.nan;
      case WireCodecOption.offset:
        offset = _tryNumber(value)?.toDouble() ?? double.nan;
      case WireCodecOption.len:
        fixedLength = _parseSignedInt(value, WireCodecOption.len.wire, position);
      case WireCodecOption.prefix:
        prefix = LengthPrefix.valueOf(value);
      case WireCodecOption.trueValue:
        trueValue = _parseSignedInt(value, WireCodecOption.trueValue.wire, position);
      case WireCodecOption.falseValue:
        falseValue = _parseSignedInt(value, WireCodecOption.falseValue.wire, position);
      case WireCodecOption.endian:
        endian = DataEndian.valueOf(value);
      case WireCodecOption.items:
        item = _parseCodec(value, const {}, position);
      case WireCodecOption.fields:
        for (final field in _splitTopLevel(value, ';')) {
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

WireCodecOption? _codecOptionOf(String key) {
  for (final option in WireCodecOption.values) {
    if (option.matches(key)) return option;
  }
  return null;
}

WireCodecSpec _codecOf(
  _Placeholder placeholder,
  String path, {
  bool requireFixed = false,
}) {
  final codec = placeholder.codec;
  if (codec == null) {
    throw FormatException('$path: ${placeholder.kind.wire} 需要编码格式，例如 :u8');
  }
  if (requireFixed && codec.fixedByteLength == null) {
    throw FormatException('$path: 该字段必须是固定长度编码');
  }
  return codec;
}

// -----------------------------------------------------------------------------
// 条件表达式
// -----------------------------------------------------------------------------
FrameConditionSpec _parseCondition(String text, int position) {
  var body = text.trim();
  var negate = false;
  if (body.startsWith(negationKeyword)) {
    negate = true;
    body = body.substring(negationKeyword.length).trim();
  }

  final operators = ['==', '!=', '>=', '<=', '>', '<'];
  for (final operator in operators) {
    final index = _indexOfTopLevel(body, operator);
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
      value: _parseOptionValue(body.substring(index + operator.length).trim()),
    )..validate();
  }

  // 集合判断：source in (a,b) / source not in (a,b)
  for (final keyword in [notInKeyword, inKeyword]) {
    final index = _indexOfTopLevel(body, keyword);
    if (index <= 0) continue;
    final source = _parseConditionSource(body.substring(0, index), position);
    final list = body.substring(index + keyword.length).trim();
    if (!list.startsWith('(') || !list.endsWith(')')) {
      throw FormatException('集合判断需要写成 ($keyword 1,2)');
    }
    final values = _splitTopLevel(list.substring(1, list.length - 1), ',')
        .map((item) => _parseOptionValue(item.trim()))
        .toList();
    return FrameConditionSpec(
      source: source.source,
      operator: keyword == notInKeyword
          ? ConditionOperator.notIn
          : ConditionOperator.isIn,
      property: source.property,
      variable: source.variable,
      values: values,
    )..validate();
  }

  final ampersand = _indexOfTopLevel(body, '&');
  if (ampersand > 0) {
    final source = _parseConditionSource(
      body.substring(0, ampersand),
      position,
    );
    final mask = _parseSignedInt(
      body.substring(ampersand + 1).trim(),
      FrameFieldOption.mask.wire,
      position,
    );
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

({ConditionSource source, String? property, String? variable})
_parseConditionSource(String text, int position) {
  final body = text.trim();
  for (final source in [ConditionSource.value, ConditionSource.sequence]) {
    if (source.wireName == body) {
      return (source: source, property: null, variable: null);
    }
  }
  if (body.startsWith(propertyPrefix)) {
    return (
      source: ConditionSource.property,
      property: body.substring(propertyPrefix.length),
      variable: null,
    );
  }
  if (body.startsWith(variablePrefix)) {
    return (
      source: ConditionSource.variable,
      property: null,
      variable: body.substring(variablePrefix.length),
    );
  }
  if (body.startsWith(propertyQualifier)) {
    return (
      source: ConditionSource.property,
      property: body.substring(propertyQualifier.length),
      variable: null,
    );
  }
  if (body.startsWith(variableQualifier)) {
    return (
      source: ConditionSource.variable,
      property: null,
      variable: body.substring(variableQualifier.length),
    );
  }
  // 裸名字按属性处理，写在条件里更简洁
  if (body.isNotEmpty && !body.contains(' ')) {
    return (source: ConditionSource.property, property: body, variable: null);
  }
  throw FormatException('无法解析的条件来源：$text');
}

// -----------------------------------------------------------------------------
// 位域
// -----------------------------------------------------------------------------
List<_BitPart> _parseBitParts(String text, int position) {
  final parts = <_BitPart>[];
  for (final part in _splitTopLevel(text, ';')) {
    final index = part.indexOf(':');
    if (index <= 0) {
      throw FormatException('位域必须写成 位偏移:来源：$part');
    }
    final rangeText = part.substring(0, index).trim();
    var sourceText = part.substring(index + 1).trim();
    FrameConditionSpec? condition;
    final conditionIndex = sourceText.indexOf('?');
    if (conditionIndex >= 0) {
      condition = _parseCondition(sourceText.substring(conditionIndex + 1), position);
      sourceText = sourceText.substring(0, conditionIndex).trim();
    }

    final range = rangeText.split('..');
    final bitOffset = int.tryParse(range.first.trim());
    if (bitOffset == null) {
      throw FormatException('位偏移必须是整数：$rangeText');
    }
    // a 表示 1 位，a..b 表示从 a 到 b 的闭区间
    final bitEnd = range.length == 1
        ? bitOffset
        : int.tryParse(range[1].trim());
    if (bitEnd == null || bitEnd < bitOffset) {
      throw FormatException('位区间必须是 a 或 a..b：$rangeText');
    }
    final bitLength = bitEnd - bitOffset + 1;

    final direct = _directBitSource(sourceText);
    if (direct != null) {
      parts.add(
        _BitPart(
          bitOffset: bitOffset,
          bitLength: bitLength,
          source: direct,
          condition: condition,
        ),
      );
      continue;
    }
    if (sourceText.startsWith(constantSource) && sourceText.endsWith(')')) {
      final value = _tryNumber(
        sourceText.substring(constantSource.length, sourceText.length - 1).trim(),
      );
      if (value == null) {
        throw FormatException('位域常量必须是整数：$sourceText');
      }
      parts.add(_BitPart(bitOffset: bitOffset, bitLength: bitLength, source: BitFieldSource.constant, value: value.round(), condition: condition));
      continue;
    }
    if (sourceText.startsWith(propertyQualifier) ||
        sourceText.startsWith(propertyPrefix)) {
      final name = sourceText.startsWith(propertyPrefix)
          ? sourceText.substring(propertyPrefix.length)
          : sourceText.substring(propertyQualifier.length);
      parts.add(_BitPart(bitOffset: bitOffset, bitLength: bitLength, source: BitFieldSource.property, name: name, condition: condition));
      continue;
    }
    if (sourceText.startsWith(variableQualifier) ||
        sourceText.startsWith(variablePrefix)) {
      final name = sourceText.startsWith(variablePrefix)
          ? sourceText.substring(variablePrefix.length)
          : sourceText.substring(variableQualifier.length);
      parts.add(_BitPart(bitOffset: bitOffset, bitLength: bitLength, source: BitFieldSource.variable, name: name, condition: condition));
      continue;
    }
    throw FormatException('未知的位域来源：$sourceText');
  }
  return parts;
}

/// 位域里不带名字的来源
BitFieldSource? _directBitSource(String text) {
  for (final source in [BitFieldSource.value, BitFieldSource.sequence]) {
    if (source.wireName == text) return source;
  }
  return null;
}

// -----------------------------------------------------------------------------
// 跨度
// -----------------------------------------------------------------------------

/// 跨度的类型
/// wireName 是帧模板里的写法
enum FrameSpanKind {
  /// 整帧
  packet('all', {'packet'}),

  /// length 字段之后到最后一个业务字段
  body('body', {}),

  /// 单个字段
  field('field', {}),

  /// 具名闭区间，写成 a..b
  range('range', {});

  const FrameSpanKind(this.wireName, this.aliases);

  final String wireName;
  final Set<String> aliases;

  bool matches(String value) => wireName == value || aliases.contains(value);
}

/// 长度与校验的统计范围
class FrameSpan {
  const FrameSpan._({
    required this.kind,
    this.name,
    this.from,
    this.to,
  });

  static const String packetTemplate = 'all';
  static const String bodyTemplate = 'body';
  static const String fieldTemplate = 'field';

  const FrameSpan.packet() : this._(kind: FrameSpanKind.packet);

  const FrameSpan.body() : this._(kind: FrameSpanKind.body);

  const FrameSpan.field(String name)
    : this._(kind: FrameSpanKind.field, name: name);

  const FrameSpan.range(String from, String to)
    : this._(kind: FrameSpanKind.range, from: from, to: to);

  final FrameSpanKind kind;
  final String? name;
  final String? from;
  final String? to;

  /// 帧模板里的写法
  String get template => switch (kind) {
    FrameSpanKind.packet => packetTemplate,
    FrameSpanKind.body => bodyTemplate,
    FrameSpanKind.field => '$fieldTemplate($name)',
    FrameSpanKind.range => '$from..$to',
  };

  static FrameSpan parse(String text, {required String path}) {
    final body = text.trim();
    for (final kind in [FrameSpanKind.packet, FrameSpanKind.body]) {
      if (kind.matches(body)) return FrameSpan._(kind: kind);
    }
    if (body.startsWith('$fieldTemplate(') && body.endsWith(')')) {
      final name = body
          .substring(fieldTemplate.length + 1, body.length - 1)
          .trim();
      if (name.isEmpty) {
        throw FormatException('$path: $fieldTemplate() 必须给出字段名');
      }
      return FrameSpan.field(name);
    }
    final index = body.indexOf('..');
    if (index > 0) {
      return FrameSpan.range(
        body.substring(0, index).trim(),
        body.substring(index + 2).trim(),
      );
    }
    throw FormatException('$path: 无法解析的跨度：$text');
  }

  @override
  bool operator ==(Object other) =>
      other is FrameSpan &&
      other.kind == kind &&
      other.name == name &&
      other.from == from &&
      other.to == to;

  @override
  int get hashCode => Object.hash(kind, name, from, to);

  @override
  String toString() => template;
}

// -----------------------------------------------------------------------------
// 请求帧编译
// -----------------------------------------------------------------------------
class _FieldPlan {
  const _FieldPlan({
    required this.order,
    required this.name,
    this.literal,
    this.placeholder,
  });

  final int order;
  final String? name;
  final List<int>? literal;
  final _Placeholder? placeholder;

  bool get isLength => placeholder?.kind == _Kind.length;

  bool get isChecksum => placeholder?.kind == _Kind.checksum;
}

class _RequestCompiler {
  _RequestCompiler(this.nodes, this.defaults, this.path);

  final List<_Node> nodes;
  final FrameDefaults defaults;
  final String path;

  PacketEncodeSpec compile() {
    final plans = <_FieldPlan>[];
    final orders = <String, int>{};
    var order = 10;
    for (final node in nodes) {
      if (node is _LiteralNode) {
        plans.add(_FieldPlan(order: order, name: null, literal: node.bytes));
        order += 10;
        continue;
      }
      final placeholder = (node as _FieldNode).placeholder;
      final name = _nameFor(placeholder, orders);
      plans.add(_FieldPlan(order: order, name: name, placeholder: placeholder));
      if (name != null) orders[name] = order;
      order += 10;
    }

    final fields = <FrameFieldSpec>[];
    for (var index = 0; index < plans.length; index++) {
      fields.add(_buildField(plans, index, orders));
    }
    return PacketEncodeSpec(fields: fields);
  }

  /// 字段名：属性与变量用它们自己的名字，其余类型用标签或类型默认名
  String? _nameFor(_Placeholder placeholder, Map<String, int> orders) {
    switch (placeholder.kind) {
      case _Kind.property:
      case _Kind.variable:
        final name = placeholder.label!;
        _requireUnique(name, placeholder, orders);
        return name;
      case _Kind.value:
      case _Kind.sequence:
      case _Kind.timestamp:
      case _Kind.length:
      case _Kind.checksum:
      case _Kind.bitfield:
        final base = placeholder.label ?? placeholder.kind.defaultLabel;
        if (!orders.containsKey(base)) return base;
        if (placeholder.label != null) {
          throw _templateError(
            path,
            placeholder.position,
            '字段名重复：$base',
          );
        }
        var index = 2;
        while (orders.containsKey('$base$index')) {
          index++;
        }
        return '$base$index';
      case _Kind.match:
      case _Kind.skip:
        return null;
    }
  }

  void _requireUnique(
    String name,
    _Placeholder placeholder,
    Map<String, int> orders,
  ) {
    if (orders.containsKey(name)) {
      throw _templateError(path, placeholder.position, '字段名重复：$name');
    }
  }

  FrameFieldSpec _buildField(
    List<_FieldPlan> plans,
    int index,
    Map<String, int> orders,
  ) {
    final plan = plans[index];
    final literal = plan.literal;
    if (literal != null) {
      return FrameFieldSpec(
        order: plan.order,
        kind: FieldKind.constant,
        hex: HexCodec.encode(literal),
      );
    }

    final placeholder = plan.placeholder!;
    final kind = placeholder.kind;
    if (kind == _Kind.match || kind == _Kind.skip) {
      throw _templateError(
        path,
        placeholder.position,
        '${placeholder.kind.wire} 只能用在响应模板里',
      );
    }

    switch (kind) {
      case _Kind.value:
        return FrameFieldSpec(
          order: plan.order,
          name: plan.name,
          kind: FieldKind.value,
          codec: _codecOf(placeholder, path),
          condition: placeholder.condition,
        );
      case _Kind.property:
        return FrameFieldSpec(
          order: plan.order,
          name: plan.name,
          kind: FieldKind.property,
          property: placeholder.label,
          codec: _codecOf(placeholder, path),
          condition: placeholder.condition,
        );
      case _Kind.variable:
        return FrameFieldSpec(
          order: plan.order,
          name: plan.name,
          kind: FieldKind.variable,
          variable: placeholder.label,
          codec: _codecOf(placeholder, path),
          condition: placeholder.condition,
        );
      case _Kind.sequence:
        return FrameFieldSpec(
          order: plan.order,
          name: plan.name,
          kind: FieldKind.sequence,
          codec: _codecOf(placeholder, path, requireFixed: true),
          condition: placeholder.condition,
        );
      case _Kind.timestamp:
        return FrameFieldSpec(
          order: plan.order,
          name: plan.name,
          kind: FieldKind.timestamp,
          codec: _codecOf(placeholder, path),
          timestampUnit: placeholder.unit,
          condition: placeholder.condition,
        );
      case _Kind.length:
        return FrameFieldSpec(
          order: plan.order,
          name: plan.name,
          kind: FieldKind.length,
          codec: _codecOf(placeholder, path, requireFixed: true),
          length: _lengthSpec(plans, index, orders, placeholder),
          condition: placeholder.condition,
        );
      case _Kind.checksum:
        return FrameFieldSpec(
          order: plan.order,
          name: plan.name,
          kind: FieldKind.checksum,
          checksum: _checksumSpec(orders, placeholder),
          condition: placeholder.condition,
        );
      case _Kind.bitfield:
        return FrameFieldSpec(
          order: plan.order,
          name: plan.name,
          kind: FieldKind.bitField,
          bitField: BitFieldSpec(
            byteLength: _codecOf(placeholder, path, requireFixed: true)
                .fixedByteLength!,
            endian: placeholder.codec!.endian,
            bits: [
              for (var i = 0; i < placeholder.parts.length; i++)
                BitFieldPartSpec(
                  order: (i + 1) * 10,
                  source: placeholder.parts[i].source,
                  property: placeholder.parts[i].source ==
                          BitFieldSource.property
                      ? placeholder.parts[i].name
                      : null,
                  variable: placeholder.parts[i].source ==
                          BitFieldSource.variable
                      ? placeholder.parts[i].name
                      : null,
                  value: placeholder.parts[i].value,
                  bitOffset: placeholder.parts[i].bitOffset,
                  bitLength: placeholder.parts[i].bitLength,
                  condition: placeholder.parts[i].condition,
                ),
            ],
          ),
          condition: placeholder.condition,
        );
      case _Kind.match:
      case _Kind.skip:
        throw _templateError(path, placeholder.position, '响应专用字段');
    }
  }

  LengthSpec _lengthSpec(
    List<_FieldPlan> plans,
    int index,
    Map<String, int> orders,
    _Placeholder placeholder,
  ) {
    final span = FrameSpan.parse(
      placeholder.span ?? defaults.lengthSpan,
      path: '$path.length',
    );
    switch (span.kind) {
      case FrameSpanKind.packet:
        return LengthSpec(
          source: LengthSource.packet,
          adjust: placeholder.adjust,
        );
      case FrameSpanKind.field:
        return LengthSpec(
          source: LengthSource.field,
          fieldOrder: _orderOf(orders, span.name, placeholder),
          adjust: placeholder.adjust,
        );
      case FrameSpanKind.range:
        return LengthSpec(
          source: LengthSource.range,
          fromOrder: _orderOf(orders, span.from, placeholder),
          toOrder: _orderOf(orders, span.to, placeholder),
          adjust: placeholder.adjust,
        );
      case FrameSpanKind.body:
        final from = index + 1;
        var to = plans.length - 1;
        while (to > from && (plans[to].isLength || plans[to].isChecksum)) {
          to--;
        }
        if (from >= plans.length || to < from) {
          throw _templateError(
            path,
            placeholder.position,
            'length 的 body 范围为空，请用 span= 显式指定',
          );
        }
        return LengthSpec(
          source: LengthSource.range,
          fromOrder: plans[from].order,
          toOrder: plans[to].order,
          adjust: placeholder.adjust,
        );
    }
  }

  ChecksumSpec _checksumSpec(
    Map<String, int> orders,
    _Placeholder placeholder,
  ) {
    final span = FrameSpan.parse(
      placeholder.span ?? defaults.checksumSpan,
      path: '$path.checksum',
    );
    switch (span.kind) {
      case FrameSpanKind.packet:
        return ChecksumSpec(
          alg: placeholder.alg!,
          options: placeholder.options,
        );
      case FrameSpanKind.field:
        final order = _orderOf(orders, span.name, placeholder);
        return ChecksumSpec(
          alg: placeholder.alg!,
          fromOrder: order,
          toOrder: order,
          options: placeholder.options,
        );
      case FrameSpanKind.range:
        return ChecksumSpec(
          alg: placeholder.alg!,
          fromOrder: _orderOf(orders, span.from, placeholder),
          toOrder: _orderOf(orders, span.to, placeholder),
          options: placeholder.options,
        );
      case FrameSpanKind.body:
        throw _templateError(
          path,
          placeholder.position,
          'checksum 不支持 span=${FrameSpan.bodyTemplate}',
        );
    }
  }

  int _orderOf(
    Map<String, int> orders,
    String? name,
    _Placeholder placeholder,
  ) {
    if (name == null || name.isEmpty) {
      throw _templateError(path, placeholder.position, '跨度必须给出字段名');
    }
    final order = orders[name];
    if (order == null) {
      throw _templateError(
        path,
        placeholder.position,
        '跨度引用了不存在的字段：$name',
      );
    }
    return order;
  }
}

// -----------------------------------------------------------------------------
// 响应帧编译
// -----------------------------------------------------------------------------
class _ResponseCompiler {
  _ResponseCompiler(this.nodes, this.path);

  final List<_Node> nodes;
  final String path;

  PacketDecodeSpec compile({String? service, String? characteristic}) {
    final matches = <PacketMatchSpec>[];
    final values = <PacketNamedValueSpec>[];
    PacketValueSpec? value;
    ResponseChecksumSpec? checksum;

    var offset = 0;
    var offsetKnown = true;

    for (final node in nodes) {
      if (node is _LiteralNode) {
        if (!offsetKnown) {
          throw _templateError(
            path,
            node.position,
            '上一个字段长度不固定，后续字段必须显式给出 at=',
          );
        }
        // 每个字面量段单独成为一个匹配锚点，写回模板时保持原有分组
        matches.add(
          PacketMatchSpec(offset: offset, hex: HexCodec.encode(node.bytes)),
        );
        offset += node.bytes.length;
        continue;
      }
      final placeholder = (node as _FieldNode).placeholder;
      final at = placeholder.at ?? (offsetKnown ? offset : null);

      switch (placeholder.kind) {
        case _Kind.match:
          final at = placeholder.at;
          if (at == null) {
            throw _templateError(path, placeholder.position, 'match 必须给出 at=');
          }
          final bytes = HexCodec.decode(placeholder.hex!);
          matches.add(
            PacketMatchSpec(
              offset: at,
              hex: placeholder.hex!,
              mask: placeholder.mask,
            ),
          );
          if (at >= 0) {
            offset = at + bytes.length;
            offsetKnown = true;
          } else {
            offsetKnown = false;
          }
        case _Kind.skip:
          final codec = _codecOf(placeholder, path, requireFixed: true);
          if (at == null) {
            throw _templateError(path, placeholder.position, 'skip 必须能确定偏移');
          }
          _advance(at, codec.fixedByteLength!, (value, known) {
            offset = value;
            offsetKnown = known;
          });
        case _Kind.value:
          if (value != null) {
            throw _templateError(path, placeholder.position, '响应只能有一个主值');
          }
          final codec = _codecOf(placeholder, path);
          if (at == null) {
            throw _templateError(path, placeholder.position, '响应字段必须能确定偏移');
          }
          value = PacketValueSpec(offset: at, codec: codec);
          _advance(at, codec.fixedByteLength, (next, known) {
            offset = next;
            offsetKnown = known;
          });
        case _Kind.property:
          final codec = _codecOf(placeholder, path);
          if (at == null) {
            throw _templateError(path, placeholder.position, '响应字段必须能确定偏移');
          }
          values.add(
            PacketNamedValueSpec(
              order: (values.length + 1) * 10,
              property: placeholder.label!,
              offset: at,
              codec: codec,
            ),
          );
          _advance(at, codec.fixedByteLength, (next, known) {
            offset = next;
            offsetKnown = known;
          });
        case _Kind.checksum:
          if (checksum != null) {
            throw _templateError(path, placeholder.position, '响应只能有一个校验字段');
          }
          final alg = placeholder.alg!;
          if (at == null) {
            throw _templateError(path, placeholder.position, '校验字段必须能确定偏移');
          }
          final length = placeholder.length == null
              ? alg.byteLength
              : _parseSignedInt(placeholder.length!, FrameFieldOption.length.wire, placeholder.position);
          if (length != alg.byteLength) {
            throw _templateError(
              path,
              placeholder.position,
              'length=$length 与 ${alg.wireName} 的 ${alg.byteLength} 字节不一致',
            );
          }
          checksum = ResponseChecksumSpec(
            alg: alg,
            start: placeholder.start == null
                ? 0
                : _parseSignedInt(placeholder.start!, FrameFieldOption.start.wire, placeholder.position),
            end: placeholder.end == null
                ? null
                : switch (placeholder.end!) {
                    'beforeChecksum' => ResponseChecksumEnd.beforeChecksum,
                    final String text =>
                      _parseSignedInt(text, FrameFieldOption.end.wire, placeholder.position),
                  },
            offset: at,
            length: length,
            options: placeholder.options,
          );
          _advance(at, alg.byteLength, (next, known) {
            offset = next;
            offsetKnown = known;
          });
        default:
          throw _templateError(
            path,
            placeholder.position,
            '${placeholder.kind.wire} 不能用在响应模板里',
          );
      }
    }
    if (matches.isEmpty && value == null && values.isEmpty) {
      throw _templateError(path, 0, '响应模板至少要有一个匹配或取值段');
    }
    return PacketDecodeSpec(
      service: service,
      characteristic: characteristic,
      match: matches,
      value: value,
      values: values,
      checksum: checksum,
    );
  }

  void _advance(
    int at,
    int? width,
    void Function(int offset, bool known) apply,
  ) {
    if (at < 0 || width == null) {
      apply(0, false);
      return;
    }
    apply(at + width, true);
  }
}

// -----------------------------------------------------------------------------
// 写回模板
// -----------------------------------------------------------------------------
class _RequestWriter {
  _RequestWriter(this.fields, this.defaults);

  final List<FrameFieldSpec> fields;
  final FrameDefaults defaults;

  String write() {
    final names = <int, String>{
      for (final field in fields)
        if (field.name != null) field.order: field.name!,
    };
    final tokens = <String>[];
    for (var index = 0; index < fields.length; index++) {
      final field = fields[index];
      switch (field.kind) {
        case FieldKind.constant:
          tokens.add(HexCodec.encode(HexCodec.decode(field.hex!)));
        case FieldKind.value:
          tokens.add(
            _expr(
              _head(_Kind.value, field.name),
              _codecTemplate(field.codec!),
              condition: field.condition,
            ),
          );
        case FieldKind.property:
          tokens.add(
            _expr(
              '${_Kind.property.wire}.${field.property}',
              _codecTemplate(field.codec!),
              condition: field.condition,
            ),
          );
        case FieldKind.variable:
          tokens.add(
            _expr(
              '${_Kind.variable.wire}.${field.variable}',
              _codecTemplate(field.codec!),
              condition: field.condition,
            ),
          );
        case FieldKind.sequence:
          tokens.add(
            _expr(
              _head(_Kind.sequence, field.name),
              _codecTemplate(field.codec!),
              condition: field.condition,
            ),
          );
        case FieldKind.timestamp:
          tokens.add(
            _expr(
              _head(_Kind.timestamp, field.name),
              _codecTemplate(field.codec!),
              options: [
                if (field.timestampUnit != null)
                  'unit=${field.timestampUnit!.wireName}',
              ],
              condition: field.condition,
            ),
          );
        case FieldKind.length:
          final span = _lengthSpanTemplate(fields, index, field.length!, names, defaults);
          tokens.add(
            _expr(
              _head(_Kind.length, field.name),
              _codecTemplate(field.codec!),
              options: [
                if (span != null) 'span=$span',
                if (field.length!.adjust != 0)
                  'adjust=${_signed(field.length!.adjust)}',
              ],
              condition: field.condition,
            ),
          );
        case FieldKind.checksum:
          final checksum = field.checksum!;
          final span = _checksumSpanTemplate(checksum, names, defaults);
          final options = [
            if (span != null) 'span=$span',
            if (checksum.endian != DataEndian.big)
              'endian=${checksum.endian.wireName}',
            for (final entry in checksum.options.entries)
              '${entry.key}=${_literalTemplate(entry.value)}',
          ];
          // 没有其它参数时用算法名简写，读起来就是 ${crc16modbus}
          tokens.add(
            field.name != null && field.name != 'crc'
                ? _expr(
              '${_Kind.checksum.wire}.${field.name}',
                    _algName(checksum.alg),
                    options: options,
                    condition: field.condition,
                  )
                : _expr(
                    _algName(checksum.alg),
                    null,
                    options: options,
                    condition: field.condition,
                  ),
          );
        case FieldKind.bitField:
          final bitField = field.bitField!;
          tokens.add(
            _expr(
              _head(_Kind.bitfield, field.name),
              'u${bitField.byteLength * 8}'
                  '${bitField.endian == DataEndian.little ? 'le' : ''}',
              options: ['parts=${_bitPartsTemplate(bitField)}'],
              condition: field.condition,
            ),
          );
      }
    }
    return tokens.join(' ');
  }
}

class _ResponseWriter {
  _ResponseWriter(this.spec);

  final PacketDecodeSpec spec;

  String write() {
    final tokens = <String>[];
    final matches = List<PacketMatchSpec>.of(spec.match)
      ..sort((left, right) => left.offset.compareTo(right.offset));
    var offset = 0;
    var offsetKnown = true;
    for (final match in matches) {
      final bytes = HexCodec.decode(match.hex);
      if (match.mask != null) {
        tokens.add(
          _expr(
            _Kind.match.wire,
            match.hex,
            options: ['at=${match.offset}', 'mask=${match.mask}'],
          ),
        );
        offsetKnown = false;
        continue;
      }
      // 中间空出来的字节用 skip 占位，读起来与回包一致
      if (offsetKnown && match.offset > offset) {
        final format = _skipFormat(match.offset - offset);
        if (format == null) {
          tokens.add(_expr(_Kind.match.wire, match.hex, options: ['at=${match.offset}']));
          offsetKnown = false;
          continue;
        }
        tokens.add(_expr(_Kind.skip.wire, format.wireName));
        offset = match.offset;
      }
      // 连续且不带 mask 的匹配还原成字面量
      if (offsetKnown && match.offset == offset) {
        tokens.add(HexCodec.encode(bytes));
        offset += bytes.length;
        continue;
      }
      tokens.add(
        _expr(
          _Kind.match.wire,
          match.hex,
          options: ['at=${match.offset}'],
        ),
      );
      if (match.offset >= 0) {
        offset = match.offset + bytes.length;
        offsetKnown = true;
      } else {
        offsetKnown = false;
      }
    }

    final value = spec.value;
    if (value != null) {
      tokens.add(
        _expr(
          _Kind.value.wire,
          _codecTemplate(value.codec),
          options: [
            if (value.length != null &&
                value.length != value.codec.fixedByteLength)
              'len=${value.length}',
            'at=${value.offset}',
          ],
        ),
      );
    }
    for (final item in spec.values) {
      tokens.add(
        _expr(
          '${_Kind.property.wire}.${item.property}',
          _codecTemplate(item.codec),
          options: [
            if (item.length != null &&
                item.length != item.codec.fixedByteLength)
              'len=${item.length}',
            'at=${item.offset}',
          ],
        ),
      );
    }

    final checksum = spec.checksum;
    if (checksum != null) {
      final end = checksum.end;
      tokens.add(
        _expr(_algName(checksum.alg), null, options: [
            if (checksum.start != 0) 'start=${checksum.start}',
            if (end != null)
              'end=${end is ResponseChecksumEnd ? end.wireName : end}',
            'at=${checksum.offset}',
            if (checksum.length != checksum.alg.byteLength)
              'length=${checksum.length}',
            if (checksum.endian != DataEndian.big)
              'endian=${checksum.endian.wireName}',
            for (final entry in checksum.options.entries)
              '${entry.key}=${_literalTemplate(entry.value)}',
        ]),
      );
    }
    return tokens.join(' ');
  }
}

/// 组装一个占位符写法
String _expr(
  String head,
  String? codec, {
  List<String> options = const [],
  FrameConditionSpec? condition,
}) {
  final buffer = StringBuffer(r'${')..write(head);
  if (codec != null && codec.isNotEmpty) buffer.write(':$codec');
  if (condition != null) buffer.write(_conditionTemplate(condition));
  for (final option in options) {
    buffer
      ..write(',')
      ..write(option);
  }
  buffer.write('}');
  return buffer.toString();
}

String _label(String? name, String? fallback) =>
    name == null || name == fallback ? '' : '.$name';

/// 占位符头部：类型名 + 非默认字段名
String _head(_Kind kind, String? name) => '${kind.wire}${_label(name, kind.defaultLabel)}';

/// 跨过的字节数可以用一个定宽整数占位，其它情况只能写 at=
ValueFormat? _skipFormat(int gap) => switch (gap) {
  1 => ValueFormat.uint8,
  2 => ValueFormat.uint16,
  4 => ValueFormat.uint32,
  8 => ValueFormat.uint64,
  _ => null,
};

/// 简写里的算法名统一小写，读起来更接近协议文档
String _algName(CheckSumAlg alg) => alg.wireName.toLowerCase();

String _signed(int value) => value >= 0 ? '+$value' : '$value';

String _codecTemplate(WireCodecSpec codec) {
  final buffer = StringBuffer(codec.format.wireName);
  if (_isMultiByte(codec.format)) {
    // 多字节格式显式写出端序，避免默认值带来的歧义
    buffer.write(codec.endian == DataEndian.little ? 'le' : 'be');
  }
  if (codec.scale != 1.0) buffer.write(',scale=${_numberTemplate(codec.scale)}');
  if (codec.offset != 0.0) {
    buffer.write(',offset=${_numberTemplate(codec.offset)}');
  }
  if (codec.fixedLength != null) buffer.write(',len=${codec.fixedLength}');
  if (codec.lengthPrefix != null) {
    buffer.write(',prefix=${codec.lengthPrefix!.name}');
  }
  if (codec.trueValue != 1) buffer.write(',true=${codec.trueValue}');
  if (codec.falseValue != 0) buffer.write(',false=${codec.falseValue}');
  if (codec.item != null) buffer.write(',items=${_codecTemplate(codec.item!)}');
  if (codec.fields.isNotEmpty) {
    buffer.write(
      ',fields=${codec.fields.map((field) => '${field.name}:${_codecTemplate(field.codec)}').join(';')}',
    );
  }
  return buffer.toString();
}

String _numberTemplate(num value) =>
    value == value.roundToDouble() ? '${value.round()}' : '$value';

String _literalTemplate(Object? value) => switch (value) {
  null => '',
  final bool item => '$item',
  final num item => _numberTemplate(item),
  _ => '$value',
};

/// 返回 null 表示与模型默认值一致，不需要写出 span=
String? _lengthSpanTemplate(
  List<FrameFieldSpec> fields,
  int index,
  LengthSpec length,
  Map<int, String> names,
  FrameDefaults defaults,
) {
  final span = switch (length.source) {
    LengthSource.packet => const FrameSpan.packet(),
    LengthSource.field => FrameSpan.field(
      _nameOf(names, length.fieldOrder),
    ),
    LengthSource.range => _isBodySpan(fields, index, length)
        ? const FrameSpan.body()
        : FrameSpan.range(
            _nameOf(names, length.fromOrder),
            _nameOf(names, length.toOrder),
          ),
  };
  return span == defaults.lengthSpanValue ? null : span.template;
}

String? _checksumSpanTemplate(
  ChecksumSpec checksum,
  Map<int, String> names,
  FrameDefaults defaults,
) {
  final FrameSpan span;
  if (checksum.fromOrder == null && checksum.toOrder == null) {
    span = const FrameSpan.packet();
  } else if (checksum.fromOrder == checksum.toOrder) {
    span = FrameSpan.field(_nameOf(names, checksum.fromOrder));
  } else {
    span = FrameSpan.range(
      _nameOf(names, checksum.fromOrder),
      _nameOf(names, checksum.toOrder),
    );
  }
  return span == defaults.checksumSpanValue ? null : span.template;
}

String _nameOf(Map<int, String> names, int? order) {
  final name = order == null ? null : names[order];
  if (name == null) {
    throw StateError('帧字段 order=$order 没有名字，无法写回模板');
  }
  return name;
}

/// 判断 length 是否是「本字段之后到最后一个业务字段」
bool _isBodySpan(
  List<FrameFieldSpec> fields,
  int index,
  LengthSpec length,
) {
  var to = fields.length - 1;
  while (to > index + 1 &&
      (fields[to].kind == FieldKind.length ||
          fields[to].kind == FieldKind.checksum)) {
    to--;
  }
  if (index + 1 >= fields.length || to <= index) return false;
  return length.fromOrder == fields[index + 1].order &&
      length.toOrder == fields[to].order;
}

String _bitPartsTemplate(BitFieldSpec bitField) {
  return [
    for (final part in bitField.bits)
      '${part.bitLength == 1 ? part.bitOffset : '${part.bitOffset}..${part.bitOffset + part.bitLength - 1}'}'
          ':${_bitSourceTemplate(part)}',
  ].join(';');
}

String _bitSourceTemplate(BitFieldPartSpec part) {
  final source = switch (part.source) {
    BitFieldSource.constant => '$constantSource${part.value})',
    BitFieldSource.value => BitFieldSource.value.wireName,
    BitFieldSource.property => '$propertyQualifier${part.property}',
    BitFieldSource.variable => '$variableQualifier${part.variable}',
    BitFieldSource.sequence => BitFieldSource.sequence.wireName,
  };
  final condition = part.condition;
  return condition == null ? source : '$source${_conditionTemplate(condition)}';
}

String _conditionTemplate(FrameConditionSpec condition) {
  final source = switch (condition.source) {
    ConditionSource.value => ConditionSource.value.wireName,
    ConditionSource.sequence => ConditionSource.sequence.wireName,
    ConditionSource.property => '$propertyQualifier${condition.property}',
    ConditionSource.variable => '$variableQualifier${condition.variable}',
  };
  return switch (condition.operator) {
    ConditionOperator.exists => '?$source',
    ConditionOperator.notExists => '?not $source',
    ConditionOperator.eq => '?$source==${_literalTemplate(condition.value)}',
    ConditionOperator.ne => '?$source!=${_literalTemplate(condition.value)}',
    ConditionOperator.gt => '?$source>${_literalTemplate(condition.value)}',
    ConditionOperator.gte => '?$source>=${_literalTemplate(condition.value)}',
    ConditionOperator.lt => '?$source<${_literalTemplate(condition.value)}',
    ConditionOperator.lte => '?$source<=${_literalTemplate(condition.value)}',
    ConditionOperator.isIn =>
      '?$source in (${condition.values.map(_literalTemplate).join(',')})',
    ConditionOperator.notIn =>
      '?$source not in (${condition.values.map(_literalTemplate).join(',')})',
    ConditionOperator.bitSet =>
      '?$source & 0x${condition.mask!.toRadixString(16)}',
    ConditionOperator.bitClear =>
      '?not $source & 0x${condition.mask!.toRadixString(16)}',
  };
}
