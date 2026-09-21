import 'package:light/src/core/device/template/parser.dart';
import 'package:light/src/core/device/util.dart';

import 'spec/packer_decode_spec.dart';
import 'template/frame_defaults.dart';
import 'template/packet_encode_pec.dart';
import 'types.dart';

// BLE operation
class BlePropertyOp {
  final OpType op;
  final String service;
  final String characteristic;
  final WriteMode? writeMode;
  final PacketEncodeSpec? request;
  final PacketDecodeSpec? response;
  final int? timeoutMs;

  const BlePropertyOp({
    required this.op,
    required this.service,
    required this.characteristic,
    this.writeMode,
    this.request,
    this.response,
    this.timeoutMs,
  });

  factory BlePropertyOp.fromJson(
    Map<String, dynamic> json,
    FrameDefaults frame, {
    String? defaultService,
    String? defaultCharacteristic,
  }) {
    final service = resolvedString(json['service'], 'service', defaultService);
    final characteristic = resolvedString(json['characteristic'], 'characteristic', defaultCharacteristic);
    final mode = json['mode'] ?? json['writeMode'];
    final result = BlePropertyOp(
      op: OpType.valueOf(stringOf(json['op'], 'op')),
      service: service,
      characteristic: characteristic,
      writeMode: mode == null ? null : WriteMode.valueOf(stringOf(mode, 'mode')),
      request: _encodeSpecFromJson(json['cmd'] ?? json['request'], frame),
      response: _decodeSpecFromJson(json['response'], service: service, characteristic: characteristic),
      timeoutMs: nullableInt(json['timeoutMs']),
    );
    if (result.timeoutMs != null && result.timeoutMs! <= 0) {
      throw FormatException('timeoutMs must be > 0');
    }
    if (result.writeMode != null && result.op != OpType.write) {
      throw FormatException('mode is only allowed for op=write');
    }
    return result;
  }

  Map<String, dynamic> toJson([
    FrameDefaults frame = const FrameDefaults(),
    String? defaultService,
    String? defaultCharacteristic,
  ]) => {
    'op': op.wireName,
    if (service != defaultService) 'service': service,
    if (characteristic != defaultCharacteristic) 'characteristic': characteristic,
    if (writeMode != null) 'mode': writeMode!.wireName,
    if (request != null) 'cmd': writeRequestTemplate(request!, defaults: frame),
    if (response != null) 'response': _responseToJson(response!, service, characteristic),
    if (timeoutMs != null) 'timeoutMs': timeoutMs,
  };
}

dynamic _responseToJson(PacketDecodeSpec response, String service, String characteristic) {
  final customTarget =
      (response.service != null && response.service != service) ||
      (response.characteristic != null && response.characteristic != characteristic);
  return customTarget ? response.toJson() : writeResponseTemplate(response);
}

PacketEncodeSpec? _encodeSpecFromJson(dynamic value, FrameDefaults frame) {
  if (value == null) return null;
  if (value is String) {
    if (value.trim().isEmpty) {
      throw FormatException('cmd must be a non-empty frame template');
    }
    return parseRequestTemplate(value, defaults: frame, path: 'cmd');
  }
  if (value is Map) {
    return PacketEncodeSpec.fromJson(mapOf(value), frame);
  }
  throw FormatException('request/cmd must be a string or object');
}

PacketDecodeSpec? _decodeSpecFromJson(dynamic value, {String? service, String? characteristic}) {
  if (value == null) return null;
  if (value is String) {
    if (value.trim().isEmpty) {
      throw FormatException('response must be a non-empty frame template');
    }
    return parseResponseTemplate(value, service: service, characteristic: characteristic, path: 'response');
  }
  if (value is Map) {
    return PacketDecodeSpec.fromJson(mapOf(value), defaultService: service, defaultCharacteristic: characteristic);
  }
  throw FormatException('response must be a string or object');
}
