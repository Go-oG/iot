// Request frame definition

import '../spec/frame_field_spec.dart';
import '../spec/length_spec.dart';
import 'frame_defaults.dart';
import 'parser.dart';
import 'compiler.dart';
import 'writer.dart';

class PacketEncodeSpec {
  final List<FrameFieldSpec> fields;

  PacketEncodeSpec({required List<FrameFieldSpec> fields}) : fields = _prepareFrameFields(fields);

  factory PacketEncodeSpec.fromJson(Map<String, dynamic> json, FrameDefaults frame) {
    return PacketEncodeSpec.fromTemplate(json['template'] ?? json['cmd'], defaults: frame, path: 'cmd');
  }

  factory PacketEncodeSpec.fromTemplate(
    dynamic template, {
    FrameDefaults defaults = const FrameDefaults(),
    String path = 'cmd',
  }) {
    if (template is! String || template.trim().isEmpty) {
      throw FormatException('$path must define a frame template');
    }
    return parseRequestTemplate(template, defaults: defaults, path: path);
  }

  Map<String, dynamic> toJson([FrameDefaults frame = const FrameDefaults()]) => {
    'template': writeRequestTemplate(this, defaults: frame),
  };
}

List<FrameFieldSpec> _prepareFrameFields(List<FrameFieldSpec> input) {
  final fields = List<FrameFieldSpec>.of(input)..sort((a, b) => a.order.compareTo(b.order));
  final orders = <int>{};
  for (final field in fields) {
    if (field.order < 0) {
      throw FormatException('Frame field order must be >= 0: ${field.order}');
    }
    if (!orders.add(field.order)) {
      throw FormatException('Duplicate frame field order: ${field.order}');
    }
    field.validate();
  }

  // 第二阶段验证跨字段引用。order 是帧定义的稳定标识，不依赖 JSON 数组位置。
  for (final field in fields) {
    if (field.kind == FieldKind.length) {
      final length = field.length!;
      if (length.source == LengthSource.field && length.fieldOrder == field.order) {
        throw FormatException('length field(order=${field.order}) cannot reference itself');
      }
      if (length.source == LengthSource.field && !orders.contains(length.fieldOrder)) {
        throw FormatException(
          'length field(order=${field.order}) references unknown '
          'fieldOrder=${length.fieldOrder}',
        );
      }
      if (length.source == LengthSource.range) {
        final hasField = fields.any(
          (candidate) => candidate.order >= length.fromOrder! && candidate.order <= length.toOrder!,
        );
        if (!hasField) {
          throw FormatException(
            'length field(order=${field.order}) references empty range '
            '${length.fromOrder}..${length.toOrder}',
          );
        }
      }
    }

    if (field.kind == FieldKind.checksum) {
      final checksum = field.checksum!;
      if (checksum.fromOrder != null && !orders.contains(checksum.fromOrder)) {
        throw FormatException(
          'checksum field(order=${field.order}) references unknown '
          'fromOrder=${checksum.fromOrder}',
        );
      }
      if (checksum.fromOrder != null && checksum.toOrder != null && checksum.fromOrder! > checksum.toOrder!) {
        throw FormatException(
          'checksum field(order=${field.order}) has invalid range '
          '${checksum.fromOrder}..${checksum.toOrder}',
        );
      }
      if (checksum.toOrder != null && checksum.toOrder! >= field.order) {
        throw FormatException(
          'checksum field(order=${field.order}) cannot depend on itself '
          'or a later field: toOrder=${checksum.toOrder}',
        );
      }
    }
  }

  return List<FrameFieldSpec>.unmodifiable(fields);
}

/// 请求方向：字面量是常量，占位符按出现顺序决定 order，跨度按名字引用
/// 响应方向：字面量自动成为匹配锚点，占位符用 at= 表示绝对偏移
/// 请求帧模板 → 运行时编码结构
PacketEncodeSpec parseRequestTemplate(
  String source, {
  FrameDefaults defaults = const FrameDefaults(),
  String path = 'frame',
}) {
  final nodes = TemplateParser(source, path).parse();
  return RequestCompiler(nodes, defaults, path).compile();
}

/// 编码结构 → 规范模板，用于模型序列化、编辑器与迁移
String writeRequestTemplate(PacketEncodeSpec spec, {FrameDefaults defaults = const FrameDefaults()}) {
  return RequestWriter(spec.fields, defaults).write();
}
