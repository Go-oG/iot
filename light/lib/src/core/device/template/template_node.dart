import 'placeholder.dart';

sealed class TemplateNode {
  const TemplateNode(this.position);

  /// 模板内的字符位置，用于错误提示
  final int position;
}

/// 一段字面量字节
class LiteralNode extends TemplateNode {
  const LiteralNode(this.bytes, super.position);

  final List<int> bytes;
}

/// 一个 ${...} 占位符
class FieldNode extends TemplateNode {
  const FieldNode(this.placeholder, super.position);

  final FramePlaceholder placeholder;
}
