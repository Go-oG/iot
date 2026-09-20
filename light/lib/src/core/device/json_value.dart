/// 递归冻结 JSON 值，避免调用方修改已校验的模型或设备上报
Object? freezeThingValue(Object? value) {
  if (value is Map<String, Object?>) {
    return Map<String, Object?>.unmodifiable({
      for (final entry in value.entries)
        entry.key: freezeThingValue(entry.value),
    });
  }
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(freezeThingValue));
  }
  return value;
}

/// JSON 对象不依赖键顺序，整数与等值小数按相同数值比较
bool sameThingValue(Object? left, Object? right) {
  if (left is Map && right is Map) {
    return left.length == right.length &&
        left.keys.every(
          (key) =>
              right.containsKey(key) && sameThingValue(left[key], right[key]),
        );
  }
  if (left is List && right is List) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (!sameThingValue(left[index], right[index])) return false;
    }
    return true;
  }
  return left == right;
}
