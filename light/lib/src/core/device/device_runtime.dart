import 'dart:typed_data';

import 'code/packet_coder.dart';
import 'code/value_validator.dart';
import 'device_definition.dart';
import 'models.dart';
import 'spec/packer_decode_spec.dart';

class DeviceRuntime {
  final DeviceDefinition definition;

  const DeviceRuntime(this.definition);

  Uint8List encodeWrite(
      String propertyId,
      Object? value, {
        Map<String, Object?> propertyState = const {},
        Map<String, Object?> variables = const {},
        int sequence = 0,
        DateTime? timestamp,
      }) {
    final property = definition.property(propertyId);
    final operation = property.write;
    if (operation == null) {
      throw StateError('Property $propertyId is not writable');
    }
    final request = operation.request;
    if (request == null) {
      throw StateError('Property $propertyId write operation has no request frame');
    }

    ValueValidator.validate(value, property.value, path: propertyId);

    return PacketEncoder.encode(
      request,
      PacketEncodeContext(
        value: value,
        properties: propertyState,
        variables: variables,
        sequence: sequence,
        timestamp: timestamp,
      ),
    );
  }

  Uint8List? encodeReadRequest(
      String propertyId, {
        Map<String, Object?> propertyState = const {},
        Map<String, Object?> variables = const {},
        int sequence = 0,
        DateTime? timestamp,
      }) {
    final property = definition.property(propertyId);
    final operation = property.read;
    if (operation == null) {
      throw StateError('Property $propertyId is not readable');
    }
    if (operation.request == null) return null;

    return PacketEncoder.encode(
      operation.request!,
      PacketEncodeContext(
        value: null,
        properties: propertyState,
        variables: variables,
        sequence: sequence,
        timestamp: timestamp,
      ),
    );
  }

  Object? decodeRead(String propertyId, Uint8List packet) {
    final property = definition.property(propertyId);
    final response = property.read?.response;
    if (response == null) {
      throw StateError('Property $propertyId has no read response definition');
    }
    final result = PacketDecoder.decode(response, packet);
    // response.values 与 response.value 的区分必须依赖定义，不能依赖解码结果的类型
    if (response.isMultiValue) {
      _validatePatch(_asPatch(propertyId, response, result));
    } else if (result != null) {
      ValueValidator.validate(result, property.value, path: propertyId);
    }
    return result;
  }

  Object? decodeNotify(String propertyId, Uint8List packet) {
    final property = definition.property(propertyId);
    final response = property.notify?.response;
    if (response == null) {
      throw StateError('Property $propertyId has no notify response definition');
    }
    final result = PacketDecoder.decode(response, packet);
    if (response.isMultiValue) {
      _validatePatch(_asPatch(propertyId, response, result));
    } else if (result != null) {
      ValueValidator.validate(result, property.value, path: propertyId);
    }
    return result;
  }

  /// 无论 response 使用单 value 还是 values，都统一转换成状态增量
  Map<String, Object?> decodeNotifyPatch(String propertyId, Uint8List packet) {
    final property = definition.property(propertyId);
    final response = property.notify?.response;
    if (response == null) {
      throw StateError('Property $propertyId has no notify response definition');
    }

    final result = PacketDecoder.decode(response, packet);
    final patch = _asPatch(propertyId, response, result);
    _validatePatch(patch);
    return patch;
  }

  /// 根据 service + characteristic + response.match 自动寻找通知解析规则。
  /// 同一个 characteristic 可以承载多种 packet，因此返回 List。
  List<DecodedNotification> decodeNotifications(String service, String characteristic, Uint8List packet) {
    final result = <DecodedNotification>[];

    for (final entry in definition.properties.entries) {
      final operation = entry.value.notify;
      final response = operation?.response;
      if (operation == null || response == null) continue;

      final responseService = response.service ?? operation.service;
      final responseCharacteristic = response.characteristic ?? operation.characteristic;

      if (!_uuidEquals(service, responseService) || !_uuidEquals(characteristic, responseCharacteristic)) {
        continue;
      }
      if (!PacketDecoder.matches(response, packet)) continue;

      final decoded = PacketDecoder.decode(response, packet);
      final patch = _asPatch(entry.key, response, decoded);
      _validatePatch(patch);
      result.add(DecodedNotification(sourceProperty: entry.key, values: patch));
    }

    return result;
  }

  /// 多值响应直接作为增量，单值响应包装成 {sourceProperty: value}
  Map<String, Object?> _asPatch(String propertyId, PacketDecodeSpec response, Object? decoded) {
    if (!response.isMultiValue) {
      return {propertyId: decoded};
    }
    if (decoded is! Map<String, Object?>) {
      throw FormatException('Property $propertyId response.values did not decode to a map');
    }
    return decoded;
  }

  void _validatePatch(Map<String, Object?> patch) {
    for (final entry in patch.entries) {
      final property = definition.properties[entry.key];
      if (property == null) {
        throw FormatException('Decoded unknown property: ${entry.key}');
      }
      ValueValidator.validate(entry.value, property.value, path: entry.key);
    }
  }

  static bool _uuidEquals(String a, String b) {
    String normalize(String value) => value.replaceAll('-', '').toUpperCase();
    return normalize(a) == normalize(b);
  }
}
