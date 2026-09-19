/// 协议线格式取值的通用约定
///
/// 协议里出现的字符串取值一律先用枚举在代码内表达，只有真正拼装或解析
/// 协议 JSON 时才通过 [WireEnum.wire] 与线上文本互转。
abstract interface class WireEnum {
  /// 该取值在协议 JSON 中的文本形式
  String get wire;
}

/// 按线上文本查找枚举值，未知取值返回 null
T? wireValueOf<T extends WireEnum>(Iterable<T> values, Object? raw) {
  if (raw is! String) return null;
  for (final value in values) {
    if (value.wire == raw) return value;
  }
  return null;
}
