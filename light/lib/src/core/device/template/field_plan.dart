
// 请求帧编译
import 'kind.dart';
import 'placeholder.dart';

class FieldPlan {
  const FieldPlan({required this.order, required this.name, this.literal, this.placeholder});

  final int order;
  final String? name;
  final List<int>? literal;
  final FramePlaceholder? placeholder;

  bool get isLength => placeholder?.kind == Kind.length;

  bool get isChecksum => placeholder?.kind == Kind.checksum;
}
