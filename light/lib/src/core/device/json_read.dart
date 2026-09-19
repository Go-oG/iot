/// 配置解析的公共取值函数
///
/// 所有错误都带字段路径，例如 `functions[1].status.red`，
/// 便于在编辑器和日志中直接定位配置问题。
library;

Map<String, Object?> readObject(Object? value, String path) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) return value.cast<String, Object?>();
  throw FormatException('$path 必须是 JSON 对象');
}

List<Object?> readList(Object? value, String path) {
  if (value is List<Object?>) return value;
  if (value is List) return value.cast<Object?>();
  throw FormatException('$path 必须是数组');
}

String readString(Object? value, String path) {
  if (value is String && value.trim().isNotEmpty) return value;
  throw FormatException('$path 必须是非空字符串');
}

bool readBool(Object? value, String path) {
  if (value is bool) return value;
  throw FormatException('$path 必须是布尔值');
}

int readInteger(Object? value, String path, int min, int max) {
  final number = readNumber(value, path, min, max);
  if (number == number.truncateToDouble()) return number.toInt();
  throw FormatException('$path 必须是整数');
}

double readNumber(Object? value, String path, num min, num max) {
  if (value is num && value.isFinite && value >= min && value <= max) {
    return value.toDouble();
  }
  throw FormatException('$path 必须是 $min 到 $max 之间的数值');
}

/// 读取可选的布尔值，缺失时返回 [fallback]
bool optionalBool(
  Map<String, Object?> json,
  String key,
  String path, {
  required bool fallback,
}) {
  final value = json[key];
  if (value == null) return fallback;
  return readBool(value, '$path.$key');
}

/// 读取可选的整数，缺失时返回 [fallback]
int optionalInteger(
  Map<String, Object?> json,
  String key,
  String path, {
  required int fallback,
  required int min,
  required int max,
}) {
  final value = json[key];
  if (value == null) return fallback;
  return readInteger(value, '$path.$key', min, max);
}

/// 读取可选的字符串，缺失时返回 [fallback]；显式填写非法值同样报错
String optionalString(
  Map<String, Object?> json,
  String key,
  String path, {
  required String fallback,
}) {
  final value = json[key];
  if (value == null) return fallback;
  return readString(value, '$path.$key');
}

/// 把十六进制字符串解析成字节，允许空格与冒号分隔
List<int> readHexBytes(Object? value, String path) {
  final text = readString(value, path);
  final clean = text.replaceAll(RegExp(r'[\s:_-]'), '');
  if (clean.length.isOdd) throw FormatException('$path 的十六进制长度必须是偶数：$text');
  final bytes = <int>[];
  for (var index = 0; index < clean.length; index += 2) {
    final byte = int.tryParse(clean.substring(index, index + 2), radix: 16);
    if (byte == null) throw FormatException('$path 含非法十六进制字符：$text');
    bytes.add(byte);
  }
  if (bytes.isEmpty) throw FormatException('$path 不能为空');
  return bytes;
}

Map<String, Object?> optionalObject(
  Map<String, Object?> json,
  String key,
  String path,
) {
  final value = json[key];
  if (value == null) return const {};
  return readObject(value, '$path.$key');
}

List<Object?> optionalList(Map<String, Object?> json, String key, String path) {
  final value = json[key];
  if (value == null) return const [];
  return readList(value, '$path.$key');
}
