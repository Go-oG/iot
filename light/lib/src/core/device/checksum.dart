import '../protocol/wire.dart';

/// 通用设备配置里声明的校验算法
enum ChecksumKind implements WireEnum {
  crc16Modbus('crc16-modbus'),
  crc16Ccitt('crc16-ccitt'),
  sum8('sum8'),
  xor8('xor8'),
  none('none');

  const ChecksumKind(this.wire);

  @override
  final String wire;

  static ChecksumKind? valueOf(Object? raw) => wireValueOf(values, raw);

  /// 校验值占用的字节数
  int get size => switch (this) {
    crc16Modbus || crc16Ccitt => 2,
    sum8 || xor8 => 1,
    none => 0,
  };

  int compute(List<int> data) => switch (this) {
    crc16Modbus => Checksums.crc16Modbus(data),
    crc16Ccitt => Checksums.crc16Ccitt(data),
    sum8 => Checksums.sum8(data),
    xor8 => Checksums.xor8(data),
    none => 0,
  };
}

/// 通用设备的在线校验和
///
/// AT5 与配置驱动的通用设备共用同一套实现，避免两处算法漂移。
class Checksums {
  const Checksums._();

  /// poly 0xA001，init 0xFFFF，xorout 0
  ///
  /// [start] 与 [length] 用于只对报文的一段计算校验和。
  static int crc16Modbus(List<int> data, {int? length, int start = 0}) {
    return _crc16(
      data,
      poly: 0xA001,
      init: 0xFFFF,
      length: length,
      start: start,
    );
  }

  /// poly 0x1021，init 0xFFFF
  static int crc16Ccitt(
    List<int> data, {
    int? length,
    int start = 0,
    int init = 0xFFFF,
  }) {
    return _crc16(data, poly: 0x1021, init: init, length: length, start: start);
  }

  static int _crc16(
    List<int> data, {
    required int poly,
    required int init,
    int? length,
    int start = 0,
  }) {
    var crc = init;
    final end = length == null ? data.length : start + length;
    for (var i = start; i < end && i < data.length; i++) {
      crc ^= data[i] & 0xFF;
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc & 1) != 0 ? (crc >> 1) ^ poly : crc >> 1;
      }
    }
    return crc & 0xFFFF;
  }

  /// 逐字节累加取低 8 位
  static int sum8(List<int> data) {
    var sum = 0;
    for (final byte in data) {
      sum = (sum + (byte & 0xFF)) & 0xFF;
    }
    return sum;
  }

  /// 逐字节异或
  static int xor8(List<int> data) {
    var value = 0;
    for (final byte in data) {
      value ^= byte & 0xFF;
    }
    return value;
  }
}
