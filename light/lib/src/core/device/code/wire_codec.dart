
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../spec/checksum_spec.dart';
import '../spec/wrie_codec_spec.dart';
import '../types.dart';
import 'hex_codec.dart';

// Wire encode/decode implementation
class WireCodec {
  const WireCodec._();

  static Uint8List encode(Object? logicalValue, WireCodecSpec spec) {
    switch (spec.format) {
      case WireFormat.bool8:
        if (logicalValue is! bool) {
          throw ArgumentError('bool8 requires bool, got $logicalValue');
        }
        return Uint8List.fromList([logicalValue ? spec.trueValue : spec.falseValue]);

      case WireFormat.uint8:
        return _encodeInteger(_toRawInt(logicalValue, spec), 1, false, spec.endian);
      case WireFormat.int8:
        return _encodeInteger(_toRawInt(logicalValue, spec), 1, true, spec.endian);
      case WireFormat.uint16:
        return _encodeInteger(_toRawInt(logicalValue, spec), 2, false, spec.endian);
      case WireFormat.int16:
        return _encodeInteger(_toRawInt(logicalValue, spec), 2, true, spec.endian);
      case WireFormat.uint32:
        return _encodeInteger(_toRawInt(logicalValue, spec), 4, false, spec.endian);
      case WireFormat.int32:
        return _encodeInteger(_toRawInt(logicalValue, spec), 4, true, spec.endian);
      case WireFormat.uint64:
        return _encodeInteger(_toRawInt(logicalValue, spec), 8, false, spec.endian);
      case WireFormat.int64:
        return _encodeInteger(_toRawInt(logicalValue, spec), 8, true, spec.endian);

      case WireFormat.float32:
        return _encodeFloat(_toRawDouble(logicalValue, spec), 4, spec.endian);
      case WireFormat.float64:
        return _encodeFloat(_toRawDouble(logicalValue, spec), 8, spec.endian);

      case WireFormat.utf8:
        if (logicalValue is! String) {
          throw ArgumentError('utf8 requires String');
        }
        return _encodeText(utf8.encode(logicalValue), spec);

      case WireFormat.ascii:
        if (logicalValue is! String) {
          throw ArgumentError('ascii requires String');
        }
        return _encodeText(ascii.encode(logicalValue), spec);

      case WireFormat.bytes:
        return _encodeBytesValue(logicalValue, spec);

      case WireFormat.array:
        if (logicalValue is! List) {
          throw ArgumentError('array codec requires List');
        }
        if (spec.item == null) {
          throw StateError('array codec requires item');
        }
        final builder = BytesBuilder(copy: false);
        if (spec.lengthPrefix != null) {
          builder.add(_encodeLengthPrefix(logicalValue.length, spec.lengthPrefix!));
        }
        for (final item in logicalValue) {
          builder.add(encode(item, spec.item!));
        }
        return builder.takeBytes();

      case WireFormat.object:
        if (logicalValue is! Map) {
          throw ArgumentError('object codec requires Map');
        }
        final builder = BytesBuilder(copy: false);
        for (final field in spec.fields) {
          if (!logicalValue.containsKey(field.name)) {
            throw StateError('object field missing: ${field.name}');
          }
          builder.add(encode(logicalValue[field.name], field.codec));
        }
        final bytes = builder.takeBytes();
        return _applyFixedLength(bytes, spec.fixedLength);
    }
  }

  static Object? decode(Uint8List bytes, WireCodecSpec spec) {
    switch (spec.format) {
      case WireFormat.bool8:
        if (bytes.isEmpty) throw FormatException('bool8 requires 1 byte');
        final value = bytes[0];
        if (value == spec.trueValue) return true;
        if (value == spec.falseValue) return false;
        throw FormatException('Invalid bool8 value: $value');

      case WireFormat.uint8:
        return _fromRawNumber(_decodeInteger(bytes, 1, false, spec.endian), spec);
      case WireFormat.int8:
        return _fromRawNumber(_decodeInteger(bytes, 1, true, spec.endian), spec);
      case WireFormat.uint16:
        return _fromRawNumber(_decodeInteger(bytes, 2, false, spec.endian), spec);
      case WireFormat.int16:
        return _fromRawNumber(_decodeInteger(bytes, 2, true, spec.endian), spec);
      case WireFormat.uint32:
        return _fromRawNumber(_decodeInteger(bytes, 4, false, spec.endian), spec);
      case WireFormat.int32:
        return _fromRawNumber(_decodeInteger(bytes, 4, true, spec.endian), spec);
      case WireFormat.uint64:
        return _fromRawNumber(_decodeInteger(bytes, 8, false, spec.endian), spec);
      case WireFormat.int64:
        return _fromRawNumber(_decodeInteger(bytes, 8, true, spec.endian), spec);

      case WireFormat.float32:
        return _fromRawNumber(_decodeFloat(bytes, 4, spec.endian), spec);
      case WireFormat.float64:
        return _fromRawNumber(_decodeFloat(bytes, 8, spec.endian), spec);

      case WireFormat.utf8:
        final payload = _stripLengthPrefix(bytes, spec);
        return utf8.decode(payload);

      case WireFormat.ascii:
        final payload = _stripLengthPrefix(bytes, spec);
        return ascii.decode(payload);

      case WireFormat.bytes:
        return Uint8List.fromList(_stripLengthPrefix(bytes, spec));

      case WireFormat.array:
        if (spec.item == null) {
          throw StateError('array codec requires item');
        }
        final prefix = _readLengthPrefix(bytes, spec.lengthPrefix);
        final itemSize = spec.item!.fixedByteLength;
        if (itemSize == null) {
          throw UnsupportedError('array decode currently requires fixed-size item codec');
        }
        final count = prefix.count ?? ((bytes.length - prefix.bytesUsed) ~/ itemSize);
        final result = <Object?>[];
        var offset = prefix.bytesUsed;
        for (var i = 0; i < count; i++) {
          final end = offset + itemSize;
          if (end > bytes.length) {
            throw FormatException('array packet truncated');
          }
          result.add(decode(Uint8List.sublistView(bytes, offset, end), spec.item!));
          offset = end;
        }
        return result;

      case WireFormat.object:
        final result = <String, Object?>{};
        var offset = 0;
        for (final field in spec.fields) {
          final size = field.codec.fixedByteLength;
          if (size == null) {
            throw UnsupportedError('object decode requires fixed-size child codecs');
          }
          final end = offset + size;
          if (end > bytes.length) {
            throw FormatException('object packet truncated');
          }
          result[field.name] = decode(Uint8List.sublistView(bytes, offset, end), field.codec);
          offset = end;
        }
        return result;
    }
  }

  static int _toRawInt(Object? value, WireCodecSpec spec) {
    if (value is! num) {
      throw ArgumentError('${spec.format} requires num, got $value');
    }
    final raw = (value.toDouble() - spec.offset) / spec.scale;
    final rounded = raw.round();
    if ((raw - rounded).abs() > 0.000001) {
      throw ArgumentError(
        'Logical value $value cannot be represented exactly by ${spec.format} '
            'with scale=${spec.scale}, offset=${spec.offset}',
      );
    }
    return rounded;
  }

  static double _toRawDouble(Object? value, WireCodecSpec spec) {
    if (value is! num) {
      throw ArgumentError('${spec.format} requires num, got $value');
    }
    return (value.toDouble() - spec.offset) / spec.scale;
  }

  static Object _fromRawNumber(num raw, WireCodecSpec spec) {
    final value = raw.toDouble() * spec.scale + spec.offset;
    if (value.isFinite && (value - value.roundToDouble()).abs() < 0.000000001) {
      return value.toInt();
    }
    return value;
  }

  static Uint8List _encodeInteger(int value, int bytes, bool signed, DataEndian endian) {
    final data = ByteData(bytes);
    final e = endian.isLittle ? Endian.little : Endian.big;
    switch ((bytes, signed)) {
      case (1, false):
        data.setUint8(0, value);
        break;
      case (1, true):
        data.setInt8(0, value);
        break;
      case (2, false):
        data.setUint16(0, value, e);
        break;
      case (2, true):
        data.setInt16(0, value, e);
        break;
      case (4, false):
        data.setUint32(0, value, e);
        break;
      case (4, true):
        data.setInt32(0, value, e);
        break;
      case (8, false):
        data.setUint64(0, value, e);
        break;
      case (8, true):
        data.setInt64(0, value, e);
        break;
      default:
        throw UnsupportedError('Unsupported integer width: $bytes');
    }
    return data.buffer.asUint8List();
  }

  static int _decodeInteger(Uint8List bytes, int width, bool signed, DataEndian endian) {
    if (bytes.length < width) {
      throw FormatException('Need $width bytes, got ${bytes.length}');
    }
    final data = ByteData.sublistView(bytes, 0, width);
    final e = endian.isLittle ? Endian.little : Endian.big;
    return switch ((width, signed)) {
      (1, false) => data.getUint8(0),
      (1, true) => data.getInt8(0),
      (2, false) => data.getUint16(0, e),
      (2, true) => data.getInt16(0, e),
      (4, false) => data.getUint32(0, e),
      (4, true) => data.getInt32(0, e),
      (8, false) => data.getUint64(0, e),
      (8, true) => data.getInt64(0, e),
      _ => throw UnsupportedError('Unsupported integer width: $width'),
    };
  }

  static Uint8List _encodeFloat(double value, int bytes, DataEndian endian) {
    final data = ByteData(bytes);
    final e = endian.isLittle ? Endian.little : Endian.big;
    if (bytes == 4) {
      data.setFloat32(0, value, e);
    } else if (bytes == 8) {
      data.setFloat64(0, value, e);
    } else {
      throw UnsupportedError('Unsupported float width: $bytes');
    }
    return data.buffer.asUint8List();
  }

  static double _decodeFloat(Uint8List bytes, int width, DataEndian endian) {
    if (bytes.length < width) {
      throw FormatException('Need $width bytes, got ${bytes.length}');
    }
    final data = ByteData.sublistView(bytes, 0, width);
    final e = endian.isLittle ? Endian.little : Endian.big;
    return width == 4 ? data.getFloat32(0, e) : data.getFloat64(0, e);
  }

  static Uint8List _encodeText(List<int> textBytes, WireCodecSpec spec) {
    final payload = _applyFixedLength(Uint8List.fromList(textBytes), spec.fixedLength);
    if (spec.lengthPrefix == null) return payload;
    final builder = BytesBuilder(copy: false)
      ..add(_encodeLengthPrefix(textBytes.length, spec.lengthPrefix!))
      ..add(payload);
    return builder.takeBytes();
  }

  static Uint8List _encodeBytesValue(Object? value, WireCodecSpec spec) {
    late Uint8List bytes;
    if (value is Uint8List) {
      bytes = value;
    } else if (value is List<int>) {
      bytes = Uint8List.fromList(value);
    } else if (value is String) {
      bytes = Uint8List.fromList(HexCodec.decode(value));
    } else {
      throw ArgumentError('bytes codec requires Uint8List/List<int>/hex String');
    }
    bytes = _applyFixedLength(bytes, spec.fixedLength);
    if (spec.lengthPrefix == null) return bytes;
    final builder = BytesBuilder(copy: false)
      ..add(_encodeLengthPrefix(bytes.length, spec.lengthPrefix!))
      ..add(bytes);
    return builder.takeBytes();
  }

  static Uint8List _applyFixedLength(Uint8List bytes, int? fixedLength) {
    if (fixedLength == null) return bytes;
    if (bytes.length > fixedLength) {
      throw ArgumentError('Encoded data length ${bytes.length} exceeds fixedLength=$fixedLength');
    }
    if (bytes.length == fixedLength) return bytes;
    final result = Uint8List(fixedLength);
    result.setRange(0, bytes.length, bytes);
    return result;
  }

  static List<int> _stripLengthPrefix(Uint8List bytes, WireCodecSpec spec) {
    if (spec.lengthPrefix == null) {
      if (spec.fixedLength == null) return bytes;
      var end = math.min(spec.fixedLength!, bytes.length);
      while (end > 0 && bytes[end - 1] == 0) {
        end--;
      }
      return bytes.sublist(0, end);
    }
    final prefix = _readLengthPrefix(bytes, spec.lengthPrefix);
    final count = prefix.count!;
    final start = prefix.bytesUsed;
    final end = start + count;
    if (end > bytes.length) {
      throw FormatException('Length-prefixed data truncated');
    }
    return bytes.sublist(start, end);
  }

  static Uint8List _encodeLengthPrefix(int value, LengthPrefix format) {
    return _encodeInteger(value, format.byteLength, false, DataEndian.big);
  }

  static _PrefixRead _readLengthPrefix(Uint8List bytes, LengthPrefix? format) {
    if (format == null) return const _PrefixRead(null, 0);
    if (bytes.length < format.byteLength) {
      throw FormatException('Length prefix truncated: ${format.name}');
    }
    return _PrefixRead(_decodeInteger(bytes, format.byteLength, false, DataEndian.big), format.byteLength);
  }
}

class _PrefixRead {
  final int? count;
  final int bytesUsed;

  const _PrefixRead(this.count, this.bytesUsed);
}
