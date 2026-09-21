// Response frame definition
import '../code/hex_codec.dart';
import '../template/parser.dart';
import '../template/writer.dart';
import '../util.dart';
import 'response_checksum_spec.dart';
import 'wrie_codec_spec.dart';

class PacketDecodeSpec {
  final String? service;
  final String? characteristic;
  final List<PacketMatchSpec> match;

  /// 单值响应，兼容简单 property read/notify
  final PacketValueSpec? value;

  /// 一帧同时更新多个属性时使用
  final List<PacketNamedValueSpec> values;
  final ResponseChecksumSpec? checksum;

  PacketDecodeSpec({
    this.service,
    this.characteristic,
    this.match = const [],
    this.value,
    List<PacketNamedValueSpec> values = const [],
    this.checksum,
  }) : values = _prepareResponseValues(values) {
    if (value != null && this.values.isNotEmpty) {
      throw FormatException('response cannot define both value and values');
    }
  }

  factory PacketDecodeSpec.fromJson(
    Map<String, dynamic> json, {
    String? defaultService,
    String? defaultCharacteristic,
  }) {
    final template = json['template'] ?? json['response'];
    if (template is! String || template.trim().isEmpty) {
      throw FormatException('response must define a frame template');
    }
    return parseResponseTemplate(
      template,
      service: nullableString(json['service']) ?? defaultService,
      characteristic: nullableString(json['characteristic']) ?? defaultCharacteristic,
      path: 'response.template',
    );
  }

  /// 一帧是否更新多个 property
  bool get isMultiValue => values.isNotEmpty;

  Map<String, dynamic> toJson() => {
    if (service != null) 'service': service,
    if (characteristic != null) 'characteristic': characteristic,
    'template': writeResponseTemplate(this),
  };
}

/// 解码结构 → 规范模板
String writeResponseTemplate(PacketDecodeSpec spec) {
  return ResponseWriter(spec).write();
}

class PacketMatchSpec {
  final int offset;
  final String hex;

  /// 可选按位 mask。mask 中为 1 的 bit 才参与匹配。
  final String? mask;

  const PacketMatchSpec({required this.offset, required this.hex, this.mask});

  /// mask 长度必须与匹配值一致
  void validate() {
    if (mask != null && HexCodec.decode(mask!).length != HexCodec.decode(hex).length) {
      throw FormatException('response match mask length must equal hex length');
    }
  }
}

class PacketValueSpec {
  final int offset;
  final int? length;
  final WireCodecSpec codec;

  const PacketValueSpec({required this.offset, required this.codec, this.length});

  void validate() {
    if (length != null && length! <= 0) {
      throw FormatException('response value length must be > 0');
    }
  }
}

class PacketNamedValueSpec {
  final int order;
  final String property;
  final int offset;
  final int? length;
  final WireCodecSpec codec;

  const PacketNamedValueSpec({
    required this.order,
    required this.property,
    required this.offset,
    required this.codec,
    this.length,
  });

  void validate() {
    if (length != null && length! <= 0) {
      throw FormatException('response value length must be > 0');
    }
  }
}

List<PacketNamedValueSpec> _prepareResponseValues(List<PacketNamedValueSpec> input) {
  final values = List<PacketNamedValueSpec>.of(input)..sort((a, b) => a.order.compareTo(b.order));
  final orders = <int>{};
  final properties = <String>{};
  for (final value in values) {
    if (value.order < 0 || !orders.add(value.order)) {
      throw FormatException('Duplicate/invalid response value order: ${value.order}');
    }
    if (value.property.isEmpty || !properties.add(value.property)) {
      throw FormatException('Duplicate/invalid response property: ${value.property}');
    }
  }
  return List<PacketNamedValueSpec>.unmodifiable(values);
}
