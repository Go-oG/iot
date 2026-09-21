
import '../code/hex_codec.dart';
import '../spec/checksum_spec.dart';
import '../spec/frame_condition_spec.dart';
import '../spec/frame_field_spec.dart';
import '../spec/length_spec.dart';
import '../spec/packer_decode_spec.dart';
import '../types.dart';
import 'bitpart.dart';
import 'frame_defaults.dart';
import 'frame_span.dart';
import 'kind.dart';
import 'util.dart';

class RequestWriter {
  RequestWriter(this.fields, this.defaults);

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
          tokens.add(_expr(_head(Kind.value, field.name), codecTemplate(field.codec!), condition: field.condition));
        case FieldKind.property:
          tokens.add(
            _expr('${Kind.property.wire}.${field.property}', codecTemplate(field.codec!), condition: field.condition),
          );
        case FieldKind.variable:
          tokens.add(
            _expr('${Kind.variable.wire}.${field.variable}', codecTemplate(field.codec!), condition: field.condition),
          );
        case FieldKind.sequence:
          tokens.add(_expr(_head(Kind.sequence, field.name), codecTemplate(field.codec!), condition: field.condition));
        case FieldKind.timestamp:
          tokens.add(
            _expr(
              _head(Kind.timestamp, field.name),
              codecTemplate(field.codec!),
              options: [if (field.timestampUnit != null) 'unit=${field.timestampUnit!.wireName}'],
              condition: field.condition,
            ),
          );
        case FieldKind.length:
          final span = _lengthSpanTemplate(fields, index, field.length!, names, defaults);
          tokens.add(
            _expr(
              _head(Kind.length, field.name),
              codecTemplate(field.codec!),
              options: [
                if (span != null) 'span=$span',
                if (field.length!.adjust != 0) 'adjust=${signed(field.length!.adjust)}',
              ],
              condition: field.condition,
            ),
          );
        case FieldKind.checksum:
          final checksum = field.checksum!;
          final span = checksumSpanTemplate(checksum, names, defaults);
          final options = [
            if (span != null) 'span=$span',
            if (checksum.endian != DataEndian.big) 'endian=${checksum.endian.wireName}',
            for (final entry in checksum.options.entries) '${entry.key}=${literalTemplate(entry.value)}',
          ];
          // 没有其它参数时用算法名简写，读起来就是 ${crc16modbus}
          tokens.add(
            field.name != null && field.name != 'crc'
                ? _expr(
                    '${Kind.checksum.wire}.${field.name}',
                    algName(checksum.alg),
                    options: options,
                    condition: field.condition,
                  )
                : _expr(algName(checksum.alg), null, options: options, condition: field.condition),
          );
        case FieldKind.bitField:
          final bitField = field.bitField!;
          tokens.add(
            _expr(
              _head(Kind.bitfield, field.name),
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

class ResponseWriter {
  ResponseWriter(this.spec);
  final PacketDecodeSpec spec;
  String write() {
    final tokens = <String>[];
    final matches = List<PacketMatchSpec>.of(spec.match)..sort((left, right) => left.offset.compareTo(right.offset));
    var offset = 0;
    var offsetKnown = true;
    for (final match in matches) {
      final bytes = HexCodec.decode(match.hex);
      if (match.mask != null) {
        tokens.add(_expr(Kind.match.wire, match.hex, options: ['at=${match.offset}', 'mask=${match.mask}']));
        offsetKnown = false;
        continue;
      }
      // 中间空出来的字节用 skip 占位，读起来与回包一致
      if (offsetKnown && match.offset > offset) {
        final format = _skipFormat(match.offset - offset);
        if (format == null) {
          tokens.add(_expr(Kind.match.wire, match.hex, options: ['at=${match.offset}']));
          offsetKnown = false;
          continue;
        }
        tokens.add(_expr(Kind.skip.wire, format.wireName));
        offset = match.offset;
      }
      // 连续且不带 mask 的匹配还原成字面量
      if (offsetKnown && match.offset == offset) {
        tokens.add(HexCodec.encode(bytes));
        offset += bytes.length;
        continue;
      }
      tokens.add(_expr(Kind.match.wire, match.hex, options: ['at=${match.offset}']));
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
          Kind.value.wire,
          codecTemplate(value.codec),
          options: [
            if (value.length != null && value.length != value.codec.fixedByteLength) 'len=${value.length}',
            'at=${value.offset}',
          ],
        ),
      );
    }
    for (final item in spec.values) {
      tokens.add(
        _expr(
          '${Kind.property.wire}.${item.property}',
          codecTemplate(item.codec),
          options: [
            if (item.length != null && item.length != item.codec.fixedByteLength) 'len=${item.length}',
            'at=${item.offset}',
          ],
        ),
      );
    }

    final checksum = spec.checksum;
    if (checksum != null) {
      final end = checksum.end;
      tokens.add(
        _expr(
          algName(checksum.alg),
          null,
          options: [
            if (checksum.start != 0) 'start=${checksum.start}',
            if (end != null) 'end=${end is ResponseChecksumEnd ? end.wireName : end}',
            'at=${checksum.offset}',
            if (checksum.length != checksum.alg.byteLength) 'length=${checksum.length}',
            if (checksum.endian != DataEndian.big) 'endian=${checksum.endian.wireName}',
            for (final entry in checksum.options.entries) '${entry.key}=${literalTemplate(entry.value)}',
          ],
        ),
      );
    }
    return tokens.join(' ');
  }
}

/// 组装一个占位符写法
String _expr(String head, String? codec, {List<String> options = const [], FrameConditionSpec? condition}) {
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

String _label(String? name, String? fallback) => name == null || name == fallback ? '' : '.$name';

/// 占位符头部：类型名 + 非默认字段名
String _head(Kind kind, String? name) => '${kind.wire}${_label(name, kind.defaultLabel)}';

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
    LengthSource.field => FrameSpan.field(nameOf(names, length.fieldOrder)),
    LengthSource.range =>
      _isBodySpan(fields, index, length)
          ? const FrameSpan.body()
          : FrameSpan.range(nameOf(names, length.fromOrder), nameOf(names, length.toOrder)),
  };
  return span == defaults.lengthSpanValue ? null : span.template;
}

/// 判断 length 是否是「本字段之后到最后一个业务字段」
bool _isBodySpan(List<FrameFieldSpec> fields, int index, LengthSpec length) {
  var to = fields.length - 1;
  while (to > index + 1 && (fields[to].kind == FieldKind.length || fields[to].kind == FieldKind.checksum)) {
    to--;
  }
  if (index + 1 >= fields.length || to <= index) return false;
  return length.fromOrder == fields[index + 1].order && length.toOrder == fields[to].order;
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
    ConditionOperator.eq => '?$source==${literalTemplate(condition.value)}',
    ConditionOperator.ne => '?$source!=${literalTemplate(condition.value)}',
    ConditionOperator.gt => '?$source>${literalTemplate(condition.value)}',
    ConditionOperator.gte => '?$source>=${literalTemplate(condition.value)}',
    ConditionOperator.lt => '?$source<${literalTemplate(condition.value)}',
    ConditionOperator.lte => '?$source<=${literalTemplate(condition.value)}',
    ConditionOperator.isIn => '?$source in (${condition.values.map(literalTemplate).join(',')})',
    ConditionOperator.notIn => '?$source not in (${condition.values.map(literalTemplate).join(',')})',
    ConditionOperator.bitSet => '?$source & 0x${condition.mask!.toRadixString(16)}',
    ConditionOperator.bitClear => '?not $source & 0x${condition.mask!.toRadixString(16)}',
  };
}

/// 跨过的字节数可以用一个定宽整数占位，其它情况只能写 at=
WireFormat? _skipFormat(int gap) => switch (gap) {
  1 => WireFormat.uint8,
  2 => WireFormat.uint16,
  4 => WireFormat.uint32,
  8 => WireFormat.uint64,
  _ => null,
};
