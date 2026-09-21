import '../code/hex_codec.dart';
import '../spec/checksum_spec.dart';
import '../spec/frame_field_spec.dart';
import '../spec/length_spec.dart';
import '../spec/packer_decode_spec.dart';
import '../spec/response_checksum_spec.dart';
import '../spec/wrie_codec_spec.dart';
import '../types.dart';
import 'bitpart.dart';
import 'field_plan.dart';
import 'frame_defaults.dart';
import 'frame_span.dart';
import 'kind.dart';
import 'packet_encode_pec.dart';
import 'placeholder.dart';
import 'template_node.dart';
import 'util.dart';

class RequestCompiler {
  RequestCompiler(this.nodes, this.defaults, this.path);

  final List<TemplateNode> nodes;
  final FrameDefaults defaults;
  final String path;

  PacketEncodeSpec compile() {
    final plans = <FieldPlan>[];
    final orders = <String, int>{};
    var order = 10;
    for (final node in nodes) {
      if (node is LiteralNode) {
        plans.add(FieldPlan(order: order, name: null, literal: node.bytes));
        order += 10;
        continue;
      }
      final placeholder = (node as FieldNode).placeholder;
      final name = _nameFor(placeholder, orders);
      plans.add(FieldPlan(order: order, name: name, placeholder: placeholder));
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
  String? _nameFor(FramePlaceholder placeholder, Map<String, int> orders) {
    switch (placeholder.kind) {
      case Kind.property:
      case Kind.variable:
        final name = placeholder.label!;
        _requireUnique(name, placeholder, orders);
        return name;
      case Kind.value:
      case Kind.sequence:
      case Kind.timestamp:
      case Kind.length:
      case Kind.checksum:
      case Kind.bitfield:
        final base = placeholder.label ?? placeholder.kind.defaultLabel;
        if (!orders.containsKey(base)) return base;
        if (placeholder.label != null) {
          throw templateError(path, placeholder.position, '字段名重复：$base');
        }
        var index = 2;
        while (orders.containsKey('$base$index')) {
          index++;
        }
        return '$base$index';
      case Kind.match:
      case Kind.skip:
        return null;
    }
  }

  void _requireUnique(String name, FramePlaceholder placeholder, Map<String, int> orders) {
    if (orders.containsKey(name)) {
      throw templateError(path, placeholder.position, '字段名重复：$name');
    }
  }

  FrameFieldSpec _buildField(List<FieldPlan> plans, int index, Map<String, int> orders) {
    final plan = plans[index];
    final literal = plan.literal;
    if (literal != null) {
      return FrameFieldSpec(order: plan.order, kind: FieldKind.constant, hex: HexCodec.encode(literal));
    }

    final placeholder = plan.placeholder!;
    final kind = placeholder.kind;
    if (kind == Kind.match || kind == Kind.skip) {
      throw templateError(path, placeholder.position, '${placeholder.kind.wire} 只能用在响应模板里');
    }

    switch (kind) {
      case Kind.value:
        return FrameFieldSpec(
          order: plan.order,
          name: plan.name,
          kind: FieldKind.value,
          codec: _codecOf(placeholder, path),
          condition: placeholder.condition,
        );
      case Kind.property:
        return FrameFieldSpec(
          order: plan.order,
          name: plan.name,
          kind: FieldKind.property,
          property: placeholder.label,
          codec: _codecOf(placeholder, path),
          condition: placeholder.condition,
        );
      case Kind.variable:
        return FrameFieldSpec(
          order: plan.order,
          name: plan.name,
          kind: FieldKind.variable,
          variable: placeholder.label,
          codec: _codecOf(placeholder, path),
          condition: placeholder.condition,
        );
      case Kind.sequence:
        return FrameFieldSpec(
          order: plan.order,
          name: plan.name,
          kind: FieldKind.sequence,
          codec: _codecOf(placeholder, path, requireFixed: true),
          condition: placeholder.condition,
        );
      case Kind.timestamp:
        return FrameFieldSpec(
          order: plan.order,
          name: plan.name,
          kind: FieldKind.timestamp,
          codec: _codecOf(placeholder, path),
          timestampUnit: placeholder.unit,
          condition: placeholder.condition,
        );
      case Kind.length:
        return FrameFieldSpec(
          order: plan.order,
          name: plan.name,
          kind: FieldKind.length,
          codec: _codecOf(placeholder, path, requireFixed: true),
          length: _lengthSpec(plans, index, orders, placeholder),
          condition: placeholder.condition,
        );
      case Kind.checksum:
        return FrameFieldSpec(
          order: plan.order,
          name: plan.name,
          kind: FieldKind.checksum,
          checksum: _checksumSpec(orders, placeholder),
          condition: placeholder.condition,
        );
      case Kind.bitfield:
        return FrameFieldSpec(
          order: plan.order,
          name: plan.name,
          kind: FieldKind.bitField,
          bitField: BitFieldSpec(
            byteLength: _codecOf(placeholder, path, requireFixed: true).fixedByteLength!,
            endian: placeholder.codec!.endian,
            bits: [
              for (var i = 0; i < placeholder.parts.length; i++)
                BitFieldPartSpec(
                  order: (i + 1) * 10,
                  source: placeholder.parts[i].source,
                  property: placeholder.parts[i].source == BitFieldSource.property ? placeholder.parts[i].name : null,
                  variable: placeholder.parts[i].source == BitFieldSource.variable ? placeholder.parts[i].name : null,
                  value: placeholder.parts[i].value,
                  bitOffset: placeholder.parts[i].bitOffset,
                  bitLength: placeholder.parts[i].bitLength,
                  condition: placeholder.parts[i].condition,
                ),
            ],
          ),
          condition: placeholder.condition,
        );
      case Kind.match:
      case Kind.skip:
        throw templateError(path, placeholder.position, '响应专用字段');
    }
  }

  LengthSpec _lengthSpec(List<FieldPlan> plans, int index, Map<String, int> orders, FramePlaceholder placeholder) {
    final span = FrameSpan.parse(placeholder.span ?? defaults.lengthSpan, path: '$path.length');
    switch (span.kind) {
      case FrameSpanKind.packet:
        return LengthSpec(source: LengthSource.packet, adjust: placeholder.adjust);
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
          throw templateError(path, placeholder.position, 'length 的 body 范围为空，请用 span= 显式指定');
        }
        return LengthSpec(
          source: LengthSource.range,
          fromOrder: plans[from].order,
          toOrder: plans[to].order,
          adjust: placeholder.adjust,
        );
    }
  }

  ChecksumSpec _checksumSpec(Map<String, int> orders, FramePlaceholder placeholder) {
    final span = FrameSpan.parse(placeholder.span ?? defaults.checksumSpan, path: '$path.checksum');
    switch (span.kind) {
      case FrameSpanKind.packet:
        return ChecksumSpec(alg: placeholder.alg!, options: placeholder.options);
      case FrameSpanKind.field:
        final order = _orderOf(orders, span.name, placeholder);
        return ChecksumSpec(alg: placeholder.alg!, fromOrder: order, toOrder: order, options: placeholder.options);
      case FrameSpanKind.range:
        return ChecksumSpec(
          alg: placeholder.alg!,
          fromOrder: _orderOf(orders, span.from, placeholder),
          toOrder: _orderOf(orders, span.to, placeholder),
          options: placeholder.options,
        );
      case FrameSpanKind.body:
        throw templateError(path, placeholder.position, 'checksum 不支持 span=${FrameSpan.bodyTemplate}');
    }
  }

  int _orderOf(Map<String, int> orders, String? name, FramePlaceholder placeholder) {
    if (name == null || name.isEmpty) {
      throw templateError(path, placeholder.position, '跨度必须给出字段名');
    }
    final order = orders[name];
    if (order == null) {
      throw templateError(path, placeholder.position, '跨度引用了不存在的字段：$name');
    }
    return order;
  }
}

class ResponseCompiler {
  ResponseCompiler(this.nodes, this.path);

  final List<TemplateNode> nodes;
  final String path;

  PacketDecodeSpec compile({String? service, String? characteristic}) {
    final matches = <PacketMatchSpec>[];
    final values = <PacketNamedValueSpec>[];
    PacketValueSpec? value;
    ResponseChecksumSpec? checksum;

    var offset = 0;
    var offsetKnown = true;

    for (final node in nodes) {
      if (node is LiteralNode) {
        if (!offsetKnown) {
          throw templateError(path, node.position, '上一个字段长度不固定，后续字段必须显式给出 at=');
        }
        // 每个字面量段单独成为一个匹配锚点，写回模板时保持原有分组
        matches.add(PacketMatchSpec(offset: offset, hex: HexCodec.encode(node.bytes)));
        offset += node.bytes.length;
        continue;
      }
      final placeholder = (node as FieldNode).placeholder;
      final at = placeholder.at ?? (offsetKnown ? offset : null);

      switch (placeholder.kind) {
        case Kind.match:
          final at = placeholder.at;
          if (at == null) {
            throw templateError(path, placeholder.position, 'match 必须给出 at=');
          }
          final bytes = HexCodec.decode(placeholder.hex!);
          matches.add(PacketMatchSpec(offset: at, hex: placeholder.hex!, mask: placeholder.mask));
          if (at >= 0) {
            offset = at + bytes.length;
            offsetKnown = true;
          } else {
            offsetKnown = false;
          }
        case Kind.skip:
          final codec = _codecOf(placeholder, path, requireFixed: true);
          if (at == null) {
            throw templateError(path, placeholder.position, 'skip 必须能确定偏移');
          }
          _advance(at, codec.fixedByteLength!, (value, known) {
            offset = value;
            offsetKnown = known;
          });
        case Kind.value:
          if (value != null) {
            throw templateError(path, placeholder.position, '响应只能有一个主值');
          }
          final codec = _codecOf(placeholder, path);
          if (at == null) {
            throw templateError(path, placeholder.position, '响应字段必须能确定偏移');
          }
          value = PacketValueSpec(offset: at, codec: codec);
          _advance(at, codec.fixedByteLength, (next, known) {
            offset = next;
            offsetKnown = known;
          });
        case Kind.property:
          final codec = _codecOf(placeholder, path);
          if (at == null) {
            throw templateError(path, placeholder.position, '响应字段必须能确定偏移');
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
        case Kind.checksum:
          if (checksum != null) {
            throw templateError(path, placeholder.position, '响应只能有一个校验字段');
          }
          final alg = placeholder.alg!;
          if (at == null) {
            throw templateError(path, placeholder.position, '校验字段必须能确定偏移');
          }
          final length = placeholder.length == null
              ? alg.byteLength
              : parseSignedInt(placeholder.length!, FrameFieldOption.length.wire, placeholder.position);
          if (length != alg.byteLength) {
            throw templateError(
              path,
              placeholder.position,
              'length=$length 与 ${alg.wireName} 的 ${alg.byteLength} 字节不一致',
            );
          }
          checksum = ResponseChecksumSpec(
            alg: alg,
            start: placeholder.start == null
                ? 0
                : parseSignedInt(placeholder.start!, FrameFieldOption.start.wire, placeholder.position),
            end: placeholder.end == null
                ? null
                : switch (placeholder.end!) {
                    'beforeChecksum' => ResponseChecksumEnd.beforeChecksum,
                    final String text => parseSignedInt(text, FrameFieldOption.end.wire, placeholder.position),
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
          throw templateError(path, placeholder.position, '${placeholder.kind.wire} 不能用在响应模板里');
      }
    }
    if (matches.isEmpty && value == null && values.isEmpty) {
      throw templateError(path, 0, '响应模板至少要有一个匹配或取值段');
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

  void _advance(int at, int? width, void Function(int offset, bool known) apply) {
    if (at < 0 || width == null) {
      apply(0, false);
      return;
    }
    apply(at + width, true);
  }
}

WireCodecSpec _codecOf(FramePlaceholder placeholder, String path, {bool requireFixed = false}) {
  final codec = placeholder.codec;
  if (codec == null) {
    throw FormatException('$path: ${placeholder.kind.wire} 需要编码格式，例如 :u8');
  }
  if (requireFixed && codec.fixedByteLength == null) {
    throw FormatException('$path: 该字段必须是固定长度编码');
  }
  return codec;
}
