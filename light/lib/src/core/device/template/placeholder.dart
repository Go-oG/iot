import '../spec/checksum_spec.dart';
import '../spec/frame_condition_spec.dart';
import '../spec/wrie_codec_spec.dart';
import '../types.dart';
import 'bitpart.dart';
import 'kind.dart';

class FramePlaceholder {
  FramePlaceholder({
    required this.kind,
    required this.position,
    this.label,
    this.codec,
    this.codecText,
    this.span,
    this.start,
    this.end,
    this.length,
    this.adjust = 0,
    this.at,
    this.mask,
    this.hex,
    this.unit,
    this.alg,
    this.condition,
    this.parts = const [],
    this.options = const {},
  });

  final Kind kind;
  final int position;

  /// kind.property / kind.variable 的属性或变量名，其余类型的字段标签
  final String? label;
  final WireCodecSpec? codec;
  final String? codecText;

  /// length / checksum 的跨度写法
  final String? span;

  /// 响应校验字段的统计范围
  final String? start;
  final String? end;
  final String? length;

  /// length 的固定偏移
  final int adjust;

  /// 响应方向的绝对偏移，支持负数
  final int? at;
  final String? mask;
  final String? hex;
  final TimestampUnit? unit;
  final CheckSumAlg? alg;
  final FrameConditionSpec? condition;
  final List<BitPart> parts;

  /// 校验算法的额外参数
  final Map<String, dynamic> options;
}
