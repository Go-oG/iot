import 'package:light/src/core/device/util.dart';

import 'code/hex_codec.dart';

/// 设备匹配规则类型
enum DeviceMatchType {
  serviceUuid('serviceUuid', {'service', 'serviceUUID'}),
  manufacturerDataPrefix('manufacturerDataPrefix', {'mfgDataPrefix'});

  final String wireName;

  final Set<String> aliases;

  const DeviceMatchType(this.wireName, this.aliases);

  static DeviceMatchType valueOf(String value) {
    for (final v in values) {
      if (v.wireName == value || v.aliases.contains(value)) {
        return v;
      }
    }
    throw FormatException('Unsupported device match type: $value');
  }
}

class DeviceMatchRule {
  final DeviceMatchType type;
  final String value;
  final String? mask;

  const DeviceMatchRule({required this.type, required this.value, this.mask});

  factory DeviceMatchRule.fromJson(Map<String, dynamic> json) {
    final result = DeviceMatchRule(
      type: DeviceMatchType.valueOf(stringOf(json['type'], 'match.type')),
      value: stringOf(json['value'], 'match.value'),
      mask: nullableString(json['mask']),
    );
    // mask 参与按位比较时长度必须与匹配值一致
    if (result.mask != null && HexCodec.decode(result.mask!).length != HexCodec.decode(result.value).length) {
      throw FormatException('match mask length must equal value length: ${result.value}');
    }
    return result;
  }

  Map<String, dynamic> toJson() => {'type': type.wireName, 'value': value, if (mask != null) 'mask': mask};
}
