import 'package:light/src/core/device/template/bitpart.dart';

import '../code/hex_codec.dart';
import '../types.dart';
import 'checksum_spec.dart';
import 'frame_condition_spec.dart';
import 'length_spec.dart';
import 'wrie_codec_spec.dart';

/// 请求帧字段类型
enum FieldKind {
  constant('constant'),
  value('value'),
  property('property'),
  variable('variable'),
  bitField('bitField'),
  length('length'),
  sequence('sequence'),
  timestamp('timestamp'),
  checksum('checksum');

  final String wireName;

  const FieldKind(this.wireName);

  static FieldKind valueOf(String value) {
    for (final v in values) {
      if (v.wireName == value) {
        return v;
      }
    }
    throw FormatException('Unsupported field kind: $value');
  }
}

class FrameFieldSpec {
  final int order;
  final FieldKind kind;

  /// 字段名，供 length / checksum 的跨度引用，模板里的 `${property.mode:u8}` 等
  /// 名字会写在这里
  final String? name;

  /// 当条件不成立时，整个字段不参与帧、length 和 checksum。
  final FrameConditionSpec? condition;

  /// constant
  final String? hex;

  /// property
  final String? property;

  /// variable
  final String? variable;

  /// value/property/variable/length/sequence/timestamp
  final WireCodecSpec? codec;

  /// bitField
  final BitFieldSpec? bitField;

  /// length
  final LengthSpec? length;

  /// timestamp
  final TimestampUnit? timestampUnit;

  /// checksum
  final ChecksumSpec? checksum;

  const FrameFieldSpec({
    required this.order,
    required this.kind,
    this.name,
    this.condition,
    this.hex,
    this.property,
    this.variable,
    this.codec,
    this.bitField,
    this.length,
    this.timestampUnit,
    this.checksum,
  });

  /// 校验字段类型所需的参数是否齐全
  void validate() {
    switch (kind) {
      case FieldKind.constant:
        if (hex == null || hex!.isEmpty) {
          throw FormatException('constant field(order=$order) requires hex');
        }
        HexCodec.decode(hex!);
        break;
      case FieldKind.value:
        if (codec == null) {
          throw FormatException('value field(order=$order) requires codec');
        }
        break;
      case FieldKind.property:
        if (property == null || property!.isEmpty || codec == null) {
          throw FormatException('property field(order=$order) requires property and codec');
        }
        break;
      case FieldKind.variable:
        if (variable == null || variable!.isEmpty || codec == null) {
          throw FormatException('variable field(order=$order) requires variable and codec');
        }
        break;
      case FieldKind.bitField:
        if (bitField == null) {
          throw FormatException('bitField field(order=$order) requires bitField');
        }
        break;
      case FieldKind.length:
        if (length == null || codec == null) {
          throw FormatException('length field(order=$order) requires length and codec');
        }
        if (codec!.fixedByteLength == null) {
          throw FormatException('length field(order=$order) codec must have fixed byte length');
        }
        break;
      case FieldKind.sequence:
        if (codec == null || codec!.fixedByteLength == null) {
          throw FormatException('sequence field(order=$order) requires fixed-length codec');
        }
        break;
      case FieldKind.timestamp:
        if (codec == null || (codec!.format != WireFormat.uint32 && codec!.format != WireFormat.uint64)) {
          throw FormatException('timestamp field(order=$order) requires uint32/uint64 codec');
        }
        break;
      case FieldKind.checksum:
        if (checksum == null) {
          throw FormatException('checksum field(order=$order) requires checksum');
        }
        break;
    }
  }
}
