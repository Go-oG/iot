// -----------------------------------------------------------------------------
// Checksum
// -----------------------------------------------------------------------------
import 'dart:typed_data';

import '../spec/checksum_spec.dart';

class ChecksumCodec {
  const ChecksumCodec._();

  static Uint8List calculate(
    CheckSumAlg algorithm,
    Uint8List data, {
    DataEndian endian = DataEndian.big,
    Map<String, dynamic> options = const {},
  }) {
    switch (algorithm) {
      case CheckSumAlg.sum8:
        var sum = 0;
        for (final value in data) {
          sum = (sum + value) & 0xFF;
        }
        return Uint8List.fromList([sum]);

      case CheckSumAlg.xor8:
        var value = 0;
        for (final byte in data) {
          value ^= byte;
        }
        return Uint8List.fromList([value & 0xFF]);

      case CheckSumAlg.crc8:
        return _encodeChecksumInt(
          _crcGeneric(
            data,
            width: 8,
            polynomial: (options['polynomial'] as int?) ?? 0x07,
            init: (options['init'] as int?) ?? 0x00,
            xorOut: (options['xorOut'] as int?) ?? 0x00,
            reflectIn: options['reflectIn'] as bool? ?? false,
            reflectOut: options['reflectOut'] as bool? ?? false,
          ),
          1,
          endian,
        );

      case CheckSumAlg.crc16:
        return _encodeChecksumInt(
          _crcGeneric(
            data,
            width: 16,
            polynomial: (options['polynomial'] as int?) ?? 0x1021,
            init: (options['init'] as int?) ?? 0xFFFF,
            xorOut: (options['xorOut'] as int?) ?? 0x0000,
            reflectIn: options['reflectIn'] as bool? ?? false,
            reflectOut: options['reflectOut'] as bool? ?? false,
          ),
          2,
          endian,
        );

      case CheckSumAlg.crc16Modbus:
        return _encodeChecksumInt(_crc16Modbus(data), 2, endian);

      case CheckSumAlg.crc16CcittFalse:
        return _encodeChecksumInt(_crc16CcittFalse(data), 2, endian);

      case CheckSumAlg.crc32:
        return _encodeChecksumInt(_crc32(data), 4, endian);
    }
  }

  static int _crcGeneric(
    Uint8List data, {
    required int width,
    required int polynomial,
    required int init,
    required int xorOut,
    required bool reflectIn,
    required bool reflectOut,
  }) {
    if (width <= 0 || width > 32) {
      throw ArgumentError('Generic CRC width must be 1..32');
    }
    final mask = width == 32 ? 0xFFFFFFFF : (1 << width) - 1;
    final topBit = 1 << (width - 1);
    var crc = init & mask;

    for (final originalByte in data) {
      final byte = reflectIn ? _reflectBits(originalByte, 8) : originalByte;
      crc ^= byte << (width - 8);
      for (var i = 0; i < 8; i++) {
        crc = (crc & topBit) != 0 ? ((crc << 1) ^ polynomial) & mask : (crc << 1) & mask;
      }
    }

    if (reflectOut) {
      crc = _reflectBits(crc, width);
    }
    return (crc ^ xorOut) & mask;
  }

  static int _reflectBits(int value, int width) {
    var result = 0;
    for (var i = 0; i < width; i++) {
      if ((value & (1 << i)) != 0) {
        result |= 1 << (width - 1 - i);
      }
    }
    return result;
  }

  static int _crc16Modbus(Uint8List data) {
    var crc = 0xFFFF;
    for (final byte in data) {
      crc ^= byte;
      for (var i = 0; i < 8; i++) {
        if ((crc & 0x0001) != 0) {
          crc = (crc >> 1) ^ 0xA001;
        } else {
          crc >>= 1;
        }
      }
    }
    return crc & 0xFFFF;
  }

  static int _crc16CcittFalse(Uint8List data) {
    var crc = 0xFFFF;
    for (final byte in data) {
      crc ^= byte << 8;
      for (var i = 0; i < 8; i++) {
        if ((crc & 0x8000) != 0) {
          crc = ((crc << 1) ^ 0x1021) & 0xFFFF;
        } else {
          crc = (crc << 1) & 0xFFFF;
        }
      }
    }
    return crc & 0xFFFF;
  }

  static int _crc32(Uint8List data) {
    var crc = 0xFFFFFFFF;
    for (final byte in data) {
      crc ^= byte;
      for (var i = 0; i < 8; i++) {
        crc = (crc & 1) != 0 ? ((crc >> 1) ^ 0xEDB88320) : (crc >> 1);
      }
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  static Uint8List _encodeChecksumInt(int value, int length, DataEndian endian) {
    final result = Uint8List(length);
    if (endian.isLittle) {
      for (var i = 0; i < length; i++) {
        result[i] = (value >> (8 * i)) & 0xFF;
      }
    } else {
      for (var i = 0; i < length; i++) {
        result[length - 1 - i] = (value >> (8 * i)) & 0xFF;
      }
    }
    return result;
  }
}
