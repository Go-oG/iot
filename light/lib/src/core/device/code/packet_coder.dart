
import 'dart:typed_data';

import '../spec/frame_field_spec.dart';
import '../spec/length_spec.dart';
import '../spec/packer_decode_spec.dart';
import '../spec/response_checksum_spec.dart';
import '../template/bitpart.dart';
import '../template/packet_encode_pec.dart';
import '../types.dart';
import 'checksum_codec.dart';
import 'hex_codec.dart';
import 'wire_codec.dart';

// Packet encoder
// Runtime encode context
class PacketEncodeContext {
  /// 当前被写入的 property 新值
  final Object? value;

  /// 当前设备其它 property 的已知状态，供 kind=property 使用。
  final Map<String, Object?> properties;

  /// 会话级或调用级动态变量，例如 transactionId、sessionId、nonce。
  final Map<String, Object?> variables;

  /// 由调用方维护的请求序号。
  final int sequence;

  final DateTime timestamp;

  PacketEncodeContext({
    required this.value,
    this.properties = const {},
    this.variables = const {},
    this.sequence = 0,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

class PacketEncoder {
  const PacketEncoder._();

  static Uint8List encode(PacketEncodeSpec spec, PacketEncodeContext context) {
    // condition 在任何长度/CRC 计算之前求值。未激活字段等同于不存在
    final activeFields = spec.fields
        .where((field) => field.condition?.evaluate(context) ?? true)
        .toList(growable: false);

    final segments = <int, Uint8List>{};
    final widths = <int, int>{};

    // Phase 1: 编码所有非 length/checksum 字段，并确定活动字段宽度。
    for (final field in activeFields) {
      switch (field.kind) {
        case FieldKind.constant:
          final bytes = Uint8List.fromList(HexCodec.decode(field.hex!));
          segments[field.order] = bytes;
          widths[field.order] = bytes.length;
          break;

        case FieldKind.value:
          final bytes = WireCodec.encode(context.value, field.codec!);
          segments[field.order] = bytes;
          widths[field.order] = bytes.length;
          break;

        case FieldKind.property:
          if (!context.properties.containsKey(field.property)) {
            throw StateError('Property state not found for frame field: ${field.property}');
          }
          final bytes = WireCodec.encode(context.properties[field.property], field.codec!);
          segments[field.order] = bytes;
          widths[field.order] = bytes.length;
          break;

        case FieldKind.variable:
          if (!context.variables.containsKey(field.variable)) {
            throw StateError('Runtime variable not found for frame field: ${field.variable}');
          }
          final bytes = WireCodec.encode(context.variables[field.variable], field.codec!);
          segments[field.order] = bytes;
          widths[field.order] = bytes.length;
          break;

        case FieldKind.bitField:
          final bytes = _encodeBitField(field.bitField!, context);
          segments[field.order] = bytes;
          widths[field.order] = bytes.length;
          break;

        case FieldKind.sequence:
          final bytes = WireCodec.encode(context.sequence, field.codec!);
          segments[field.order] = bytes;
          widths[field.order] = bytes.length;
          break;

        case FieldKind.timestamp:
          final unit = field.timestampUnit ?? TimestampUnit.milliseconds;
          final timestampValue = switch (unit) {
            TimestampUnit.seconds => context.timestamp.millisecondsSinceEpoch ~/ 1000,
            TimestampUnit.milliseconds => context.timestamp.millisecondsSinceEpoch,
          };
          final bytes = WireCodec.encode(timestampValue, field.codec!);
          segments[field.order] = bytes;
          widths[field.order] = bytes.length;
          break;

        case FieldKind.length:
          widths[field.order] = field.codec!.fixedByteLength!;
          break;

        case FieldKind.checksum:
          widths[field.order] = field.checksum!.byteLength;
          break;
      }
    }

    // Phase 2: 解析 length。packet/range 仅统计实际激活字段。
    for (final field in activeFields) {
      if (field.kind != FieldKind.length) continue;
      final length = _resolveLength(field.length!, widths);
      final bytes = WireCodec.encode(length, field.codec!);
      if (bytes.length != widths[field.order]) {
        throw StateError('Length field(order=${field.order}) encoded width changed unexpectedly');
      }
      segments[field.order] = bytes;
    }

    // Phase 3: checksum 只能依赖其之前已经解析完成的活动字段。
    for (final field in activeFields) {
      if (field.kind != FieldKind.checksum) continue;

      final checksum = field.checksum!;
      final input = BytesBuilder(copy: false);

      final fromOrder = checksum.fromOrder;
      for (final candidate in activeFields) {
        // fromOrder/toOrder 都是闭区间；未指定 fromOrder 表示从帧首开始
        // 未指定 toOrder 表示范围到本校验字段之前
        if (fromOrder != null && candidate.order < fromOrder) continue;
        if (candidate.order > (checksum.toOrder ?? field.order - 1)) continue;

        final data = segments[candidate.order];
        if (data == null) {
          throw StateError(
            'Checksum(order=${field.order}) references unresolved field '
            'order=${candidate.order}',
          );
        }
        input.add(data);
      }

      final bytes = ChecksumCodec.calculate(
        checksum.alg,
        input.takeBytes(),
        endian: checksum.endian,
        options: checksum.options,
      );

      if (bytes.length != checksum.byteLength) {
        throw StateError('Checksum ${checksum.alg.wireName} returned invalid byte length');
      }
      segments[field.order] = bytes;
    }

    // Phase 4: 最终帧严格按 order 输出，未激活字段完全不输出。
    final result = BytesBuilder(copy: false);
    for (final field in activeFields) {
      final bytes = segments[field.order];
      if (bytes == null) {
        throw StateError('Frame field unresolved: order=${field.order}');
      }
      result.add(bytes);
    }
    return result.takeBytes();
  }

  static Uint8List _encodeBitField(BitFieldSpec spec, PacketEncodeContext context) {
    var aggregate = 0;

    for (final part in spec.bits) {
      if (!(part.condition?.evaluate(context) ?? true)) {
        continue;
      }

      final raw = switch (part.source) {
        BitFieldSource.constant => part.value,
        BitFieldSource.value => context.value,
        BitFieldSource.sequence => context.sequence,
        BitFieldSource.property =>
          context.properties.containsKey(part.property)
              ? context.properties[part.property]
              : throw StateError('Property state not found for bitField: ${part.property}'),
        BitFieldSource.variable =>
          context.variables.containsKey(part.variable)
              ? context.variables[part.variable]
              : throw StateError('Runtime variable not found for bitField: ${part.variable}'),
      };

      final value = _toBitInt(raw);
      final maxValue = (1 << part.bitLength) - 1;
      if (value < 0 || value > maxValue) {
        throw RangeError(
          'bitField part(order=${part.order}) value=$value does not fit '
          '${part.bitLength} bits',
        );
      }

      aggregate |= value << part.bitOffset;
    }

    final result = Uint8List(spec.byteLength);
    for (var i = 0; i < spec.byteLength; i++) {
      final byte = (aggregate >> (i * 8)) & 0xFF;
      final index = spec.endian.isLittle ? i : spec.byteLength - 1 - i;
      result[index] = byte;
    }
    return result;
  }

  static int _toBitInt(Object? value) {
    if (value is bool) return value ? 1 : 0;
    if (value is num) return value.toInt();
    throw ArgumentError('bitField source requires bool/num, got $value');
  }

  static int _resolveLength(LengthSpec spec, Map<int, int> widths) {
    int value;
    switch (spec.source) {
      case LengthSource.packet:
        value = widths.values.fold<int>(0, (sum, item) => sum + item);
        break;
      case LengthSource.field:
        // 被 condition 排除的字段长度视为 0。
        value = widths[spec.fieldOrder] ?? 0;
        break;
      case LengthSource.range:
        value = 0;
        for (final entry in widths.entries) {
          if (entry.key >= spec.fromOrder! && entry.key <= spec.toOrder!) {
            value += entry.value;
          }
        }
        break;
    }
    return value + spec.adjust;
  }
}

// -----------------------------------------------------------------------------
// Packet decoder
// -----------------------------------------------------------------------------
class PacketDecoder {
  const PacketDecoder._();

  static bool matches(PacketDecodeSpec spec, Uint8List packet) {
    for (final match in spec.match) {
      final expected = HexCodec.decode(match.hex);
      final mask = match.mask == null ? null : HexCodec.decode(match.mask!);
      final offset = _normalizeOffset(match.offset, packet.length);
      if (offset < 0 || offset + expected.length > packet.length) {
        return false;
      }
      for (var i = 0; i < expected.length; i++) {
        final actualByte = packet[offset + i];
        final expectedByte = expected[i];
        if (mask == null) {
          if (actualByte != expectedByte) return false;
        } else {
          final bitMask = mask[i];
          if ((actualByte & bitMask) != (expectedByte & bitMask)) return false;
        }
      }
    }
    return true;
  }

  static Object? decode(PacketDecodeSpec spec, Uint8List packet) {
    _verifyPacket(spec, packet);

    if (spec.value != null) {
      return _decodeValue(spec.value!, packet);
    }
    if (spec.values.isNotEmpty) {
      return _decodeNamedValues(spec.values, packet);
    }
    return null;
  }

  static Map<String, Object?> decodeValues(PacketDecodeSpec spec, Uint8List packet) {
    _verifyPacket(spec, packet);
    if (spec.values.isEmpty) {
      throw StateError('Response definition does not contain values');
    }
    return _decodeNamedValues(spec.values, packet);
  }

  static void _verifyPacket(PacketDecodeSpec spec, Uint8List packet) {
    if (!matches(spec, packet)) {
      throw FormatException('Packet does not match response definition');
    }
    if (spec.checksum != null) {
      _verifyChecksum(spec.checksum!, packet);
    }
  }

  static Object? _decodeValue(PacketValueSpec value, Uint8List packet) {
    final start = _normalizeOffset(value.offset, packet.length);
    if (start < 0 || start > packet.length) {
      throw RangeError('Invalid response value offset: ${value.offset}');
    }

    final length = value.length ?? value.codec.fixedByteLength ?? (packet.length - start);
    final end = start + length;
    if (end > packet.length) {
      throw RangeError('Response value exceeds packet length');
    }

    return WireCodec.decode(Uint8List.sublistView(packet, start, end), value.codec);
  }

  static Map<String, Object?> _decodeNamedValues(List<PacketNamedValueSpec> values, Uint8List packet) {
    final result = <String, Object?>{};
    for (final value in values) {
      final start = _normalizeOffset(value.offset, packet.length);
      if (start < 0 || start > packet.length) {
        throw RangeError('Invalid response value offset for ${value.property}: ${value.offset}');
      }
      final length = value.length ?? value.codec.fixedByteLength ?? (packet.length - start);
      final end = start + length;
      if (end > packet.length) {
        throw RangeError('Response value ${value.property} exceeds packet length');
      }
      result[value.property] = WireCodec.decode(Uint8List.sublistView(packet, start, end), value.codec);
    }
    return result;
  }

  static void _verifyChecksum(ResponseChecksumSpec spec, Uint8List packet) {
    final checksumOffset = _normalizeOffset(spec.offset, packet.length);
    if (checksumOffset < 0 || checksumOffset + spec.length > packet.length) {
      throw RangeError('Invalid checksum offset/length');
    }

    final end = switch (spec.end) {
      null => checksumOffset,
      ResponseChecksumEnd.beforeChecksum => checksumOffset,
      int value => _normalizeExclusiveOffset(value, packet.length),
      _ => throw FormatException('Unsupported response checksum end: ${spec.end}'),
    };

    final start = _normalizeOffset(spec.start, packet.length);
    if (start < 0 || end < start || end > packet.length) {
      throw RangeError('Invalid response checksum data range');
    }

    final actual = Uint8List.sublistView(packet, checksumOffset, checksumOffset + spec.length);
    final expected = ChecksumCodec.calculate(
      spec.alg,
      Uint8List.sublistView(packet, start, end),
      endian: spec.endian,
      options: spec.options,
    );

    if (!_bytesEqual(actual, expected)) {
      throw FormatException(
        'Checksum mismatch: actual=${HexCodec.encode(actual)}, '
        'expected=${HexCodec.encode(expected)}',
      );
    }
  }
}

int _normalizeOffset(int offset, int length) {
  return offset >= 0 ? offset : length + offset;
}

int _normalizeExclusiveOffset(int offset, int length) {
  return offset >= 0 ? offset : length + offset;
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
