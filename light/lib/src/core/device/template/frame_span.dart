
/// 跨度的类型
enum FrameSpanKind {
  /// 整帧
  packet('packet'),

  /// length 字段之后到最后一个业务字段
  body('body'),

  /// 单个字段
  field('field'),

  /// 具名闭区间，写成 a..b
  range('range');

  const FrameSpanKind(this.wireName);

  final String wireName;

  bool matches(String value) => switch (this) {
    FrameSpanKind.packet => value == 'all' || value == 'packet',
    FrameSpanKind.body => value == 'body',
    FrameSpanKind.field => value == 'field',
    FrameSpanKind.range => value == 'range',
  };
}

/// 长度与校验的统计范围
class FrameSpan {
  const FrameSpan._({required this.kind, this.name, this.from, this.to});

  static const String packetTemplate = 'all';
  static const String bodyTemplate = 'body';
  static const String fieldTemplate = 'field';

  const FrameSpan.packet() : this._(kind: FrameSpanKind.packet);

  const FrameSpan.body() : this._(kind: FrameSpanKind.body);

  const FrameSpan.field(String name) : this._(kind: FrameSpanKind.field, name: name);

  const FrameSpan.range(String from, String to) : this._(kind: FrameSpanKind.range, from: from, to: to);

  final FrameSpanKind kind;
  final String? name;
  final String? from;
  final String? to;

  /// 帧模板里的写法
  String get template => switch (kind) {
    FrameSpanKind.packet => packetTemplate,
    FrameSpanKind.body => bodyTemplate,
    FrameSpanKind.field => '$fieldTemplate($name)',
    FrameSpanKind.range => '$from..$to',
  };

  static FrameSpan parse(String text, {required String path}) {
    final body = text.trim();
    for (final kind in [FrameSpanKind.packet, FrameSpanKind.body]) {
      if (kind.matches(body)) return FrameSpan._(kind: kind);
    }
    if (body.startsWith('$fieldTemplate(') && body.endsWith(')')) {
      final name = body.substring(fieldTemplate.length + 1, body.length - 1).trim();
      if (name.isEmpty) {
        throw FormatException('$path: $fieldTemplate() 必须给出字段名');
      }
      return FrameSpan.field(name);
    }
    final index = body.indexOf('..');
    if (index > 0) {
      return FrameSpan.range(body.substring(0, index).trim(), body.substring(index + 2).trim());
    }
    throw FormatException('$path: 无法解析的跨度：$text');
  }

  @override
  bool operator ==(Object other) =>
      other is FrameSpan && other.kind == kind && other.name == name && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(kind, name, from, to);

  @override
  String toString() => template;
}
