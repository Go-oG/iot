enum CheckSumAlg {
  sum8('sum8', {'checksum8'}),
  xor8('xor8', {}),
  crc8('crc8', {}),
  crc16('crc16', {}),
  crc16Modbus('crc16Modbus', {'modbus', 'crc16-modbus'}),
  crc16CcittFalse('crc16CcittFalse', {'ccitt', 'crc16-ccitt'}),
  crc32('crc32', {});

  final String wireName;

  /// 帧模板里的兼容写法
  final Set<String> aliases;

  const CheckSumAlg(this.wireName, this.aliases);

  /// 大小写不敏感，帧模板里通常写成小写
  bool matches(String value) {
    final normalized = value.toLowerCase();
    return wireName.toLowerCase() == normalized || aliases.contains(normalized);
  }

  /// 校验字节数
  int get byteLength => switch (this) {
    CheckSumAlg.sum8 || CheckSumAlg.xor8 || CheckSumAlg.crc8 => 1,
    CheckSumAlg.crc16 || CheckSumAlg.crc16Modbus || CheckSumAlg.crc16CcittFalse => 2,
    CheckSumAlg.crc32 => 4,
  };

  static CheckSumAlg valueOf(String value) {
    for (final v in values) {
      if (v.matches(value)) {
        return v;
      }
    }
    throw FormatException('Unsupported checksum algorithm: $value');
  }
}
/// 大小端
enum DataEndian {
  big('big'),
  little('little');

  final String wireName;

  const DataEndian(this.wireName);

  bool get isBig => this == big;

  bool get isLittle => this == little;

  /// 未声明时按 big 处理
  static DataEndian valueOf(String? value) {
    if (value == null || value.isEmpty) {
      return big;
    }
    for (final v in values) {
      if (v.wireName == value) {
        return v;
      }
    }
    throw FormatException('Unsupported endian: $value');
  }
}

class ChecksumSpec {
  final CheckSumAlg alg;

  /// 请求帧中按 field order 选择校验范围
  final int? fromOrder;
  final int? toOrder;

  ///对 1-byte checksum 无影响
  final DataEndian endian;

  final Map<String, dynamic> options;

  const ChecksumSpec({
    required this.alg,
    this.fromOrder,
    this.toOrder,
    this.endian = DataEndian.big,
    this.options = const {},
  });

  int get byteLength => alg.byteLength;
}
