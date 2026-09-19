import '../core/device/device.dart';

Map<String, Object?> objectOf(Object? value, String path) {
  if (value is Map<String, Object?>) return value;
  throw FormatException('$path 必须是 JSON 对象');
}

List<Object?> listOf(Object? value, String path) {
  if (value is List<Object?>) return value;
  throw FormatException('$path 必须是数组');
}

String stringOf(Object? value, String path) {
  if (value is String && value.trim().isNotEmpty) return value;
  throw FormatException('$path 必须是非空字符串');
}

bool boolOf(Object? value, String path) {
  if (value is bool) return value;
  throw FormatException('$path 必须是布尔值');
}

double numberOf(Object? value, String path, num min, num max) {
  if (value is num && value.isFinite && value >= min && value <= max) return value.toDouble();
  throw FormatException('$path 必须是 $min 到 $max 之间的数值');
}

int intOf(Object? value, String path, int min, int max) {
  final number = numberOf(value, path, min, max);
  if (number == number.truncateToDouble()) return number.toInt();
  throw FormatException('$path 必须是整数');
}

BleServiceDesc serviceOf(Object? value, String path) {
  final json = objectOf(value, path);
  final characteristics = listOf(json['characteristicList'], '$path.characteristicList');
  return BleServiceDesc(
    uuid: stringOf(json['uuid'], '$path.uuid'),
    name: stringOf(json['name'], '$path.name'),
    characteristicList: List.unmodifiable([
      for (var index = 0; index < characteristics.length; index++)
        characteristicOf(characteristics[index], '$path.characteristicList[$index]'),
    ]),
  );
}

CharacteristicDesc characteristicOf(Object? value, String path) {
  final json = objectOf(value, path);
  return CharacteristicDesc(uuid: stringOf(json['uuid'], '$path.uuid'), name: stringOf(json['name'], '$path.name'));
}
