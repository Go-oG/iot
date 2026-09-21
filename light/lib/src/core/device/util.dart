/// 解析整型
int intOf(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) {
    return int.parse(value);
  }
  throw FormatException('Expected integer, got: $value');
}

double doubleOf(dynamic value) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  if (value is String) {
    return double.parse(value);
  }
  throw FormatException('Expected integer, got: $value');
}

Map<String, dynamic> mapOf(dynamic value) {
  return Map<String, dynamic>.from(value as Map);
}

Map<String, dynamic>? nullableMap(dynamic value) {
  if (value == null) return null;
  return mapOf(value);
}

/// 解析对象数组，元素为 null 时按空数组处理
List<T> mapList<T>(dynamic value, T Function(Map<String, dynamic>) fromJson) {
  if (value == null) return const [];
  return (value as List).map((e) => fromJson(mapOf(e))).toList(growable: false);
}

int? nullableInt(dynamic value) => value == null ? null : intOf(value);

String stringOf(dynamic value, String name) {
  if (value is String && value.isNotEmpty) return value;
  throw FormatException('Expected non-empty string for $name, got: $value');
}

String? nullableString(dynamic value) => value == null ? null : value as String;

String resolvedString(dynamic value, String name, String? fallback) {
  if (value == null) return stringOf(fallback, name);
  return stringOf(value, name);
}