/// 语法前缀：属性引用、运行时变量与位域常量
const String propertyPrefix = '@';
const String variablePrefix = r'$';
const String propertyQualifier = 'attr.';
const String variableQualifier = 'var.';
const String constantSource = 'const(';

/// 条件表达式里的关键字
const String negationKeyword = 'not ';
const String inKeyword = ' in ';
const String notInKeyword = ' not in ';

/// 字段级选项
enum FrameFieldOption {
  span('span'),
  start('start'),
  end('end'),
  length('length'),
  adjust('adjust'),
  at('at'),
  mask('mask'),
  hex('hex'),
  name('name'),
  unit('unit'),
  parts('parts');

  const FrameFieldOption(this.wire);

  final String wire;

  bool matches(String value) => wire == value;
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

  static WireCodecOption? of(String key) {
    for (final option in WireCodecOption.values) {
      if (option.matches(key)) return option;
    }
    return null;
  }
}

/// 校验算法参数，键名与 ChecksumCodec 读取的 options 一致
enum ChecksumOption {
  polynomial('polynomial', {'poly'}),
  init('init', {}),
  xorOut('xorOut', {}),
  reflectIn('reflectIn', {'reflectin'}),
  reflectOut('reflectOut', {'reflectout'});

  const ChecksumOption(this.wire, this.aliases);

  final String wire;
  final Set<String> aliases;

  bool matches(String value) => wire == value || aliases.contains(value);

  static ChecksumOption? valueOf(String key) {
    for (final option in values) {
      if (option.matches(key)) return option;
    }
    return null;
  }
}

/// 逻辑数据类型
enum ValueType {
  boolean('bool', {'bool', 'boolean'}),
  integer('int', {'int', 'integer'}),
  double('double', {'double', 'decimal'}),
  string('string', {'string', 'str'}),
  enumeration('enum', {'enum', 'enumeration'}),
  array('array', {'array', 'list'}),
  object('object', {'object', 'obj'});

  final String wireName;

  final Set<String> aliases;

  const ValueType(this.wireName, this.aliases);

  static ValueType valueOf(String value) {
    for (final v in values) {
      if (v.wireName == value || v.aliases.contains(value)) {
        return v;
      }
    }
    throw FormatException('Unsupported value type: $value');
  }
}

/// BLE 操作类型
enum OpType {
  read('read', {'r'}),
  write('write', {'w'}),
  subscribe('subscribe', {'subs'});

  final String wireName;
  final Set<String> aliases;

  const OpType(this.wireName, this.aliases);

  static OpType valueOf(String value) {
    for (final v in values) {
      if (v.wireName == value || v.aliases.contains(value)) {
        return v;
      }
    }
    throw FormatException('Unsupported operation type: $value');
  }
}

/// 写入方式
enum WriteMode {
  withResponse('withResponse'),
  withoutResponse('withoutResponse');

  final String wireName;

  const WriteMode(this.wireName);

  static WriteMode valueOf(String value) {
    for (final v in values) {
      if (v.wireName == value) {
        return v;
      }
    }
    throw FormatException('Unsupported write mode: $value');
  }
}


/// 长度前缀占用的字节宽度
enum LengthPrefix {
  uint8(1, {'u8'}),
  uint16(2, {'u16'}),
  uint32(4, {'u32'});

  final int byteLength;

  /// 帧定义里的规范写法是 name，aliases 是兼容写法
  final Set<String> aliases;

  const LengthPrefix(this.byteLength, this.aliases);

  bool matches(String value) => name == value || aliases.contains(value);

  static LengthPrefix valueOf(String value) {
    for (final v in values) {
      if (v.matches(value)) {
        return v;
      }
    }
    throw FormatException('Unsupported lengthPrefix: $value');
  }
}

/// 时间戳单位
enum TimestampUnit {
  seconds('seconds'),
  milliseconds('milliseconds');

  final String wireName;

  const TimestampUnit(this.wireName);

  static TimestampUnit valueOf(String value) {
    for (final v in values) {
      if (v.wireName == value) {
        return v;
      }
    }
    throw FormatException('Unsupported timestampUnit: $value');
  }
}

/// 响应校验范围的结束位置
enum ResponseChecksumEnd {
  beforeChecksum('beforeChecksum');

  final String wireName;

  const ResponseChecksumEnd(this.wireName);

  static ResponseChecksumEnd valueOf(String value) {
    for (final v in values) {
      if (v.wireName == value) {
        return v;
      }
    }
    throw FormatException('Unsupported response checksum end: $value');
  }
}



/// 帧内的二进制编码格式
enum WireFormat {
  bool8('bool8'),
  uint8('u8'),
  int8('i8'),
  uint16('u16'),
  int16('i16'),
  uint32('u32'),
  int32('i32'),
  uint64('u64'),
  int64('i64'),
  float32('f32'),
  float64('f64'),
  utf8('utf8'),
  ascii('ascii'),
  bytes('bytes'),
  array('array'),
  object('object');

  const WireFormat(this.wireName);

  final String wireName;

  bool matches(String value) => wireName == value;

  static WireFormat valueOf(String value) {
    for (final v in values) {
      if (v.matches(value)) {
        return v;
      }
    }
    throw FormatException('Unsupported wire format: $value');
  }

  static WireFormat? formatOf(String text) {
    final normalized = text.toLowerCase();
    for (final format in WireFormat.values) {
      if (format.matches(normalized)) return format;
    }
    return null;
  }

  bool get isMultiByte => switch (this) {
    WireFormat.uint16 ||
    WireFormat.int16 ||
    WireFormat.uint32 ||
    WireFormat.int32 ||
    WireFormat.uint64 ||
    WireFormat.int64 ||
    WireFormat.float32 ||
    WireFormat.float64 => true,
    _ => false,
  };
}


/// 条件比较运算符
enum ConditionOperator {
  eq('eq'),
  ne('ne'),
  gt('gt'),
  gte('gte'),
  lt('lt'),
  lte('lte'),
  isIn('in'),
  notIn('notIn'),
  exists('exists'),
  notExists('notExists'),
  bitSet('bitSet'),
  bitClear('bitClear');

  final String wireName;

  const ConditionOperator(this.wireName);

  static ConditionOperator valueOf(String value) {
    for (final v in values) {
      if (v.wireName == value) {
        return v;
      }
    }
    throw FormatException('Unsupported condition operator: $value');
  }
}
