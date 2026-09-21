
import 'dart:convert';

import 'package:light/src/core/device/template/bitpart.dart';

import 'ble_operation.dart';
import 'device_property.dart';
import 'devie_match.dart';
import 'spec/frame_condition_spec.dart';
import 'spec/frame_field_spec.dart';
import 'spec/packer_decode_spec.dart';
import 'template/frame_defaults.dart';
import 'types.dart';
import 'util.dart';

class DeviceDefinition {
  final String id;
  final String name;
  final List<DeviceMatchRule> match;
  final Map<String, DeviceProperty> properties;

  /// 设备级 BLE 默认值，属性操作没有声明时继承
  final String? service;
  final String? characteristic;

  /// 帧级默认值：裸写 ${length:u8} / ${crc16modbus} 时使用的默认跨度
  final FrameDefaults frame;

  const DeviceDefinition({
    required this.id,
    required this.name,
    required this.properties,
    this.match = const [],
    this.service,
    this.characteristic,
    this.frame = const FrameDefaults(),
  });

  factory DeviceDefinition.fromJson(Map<String, dynamic> json) {
    final frame = json['frame'] == null ? const FrameDefaults() : FrameDefaults.fromJson(mapOf(json['frame']));
    final propertyJson = mapOf(json['properties']);
    final service = nullableString(json['service']) ?? nullableString(propertyJson['service']);
    final characteristic = nullableString(json['characteristic']) ?? nullableString(propertyJson['characteristic']);
    final properties = <String, DeviceProperty>{};
    for (final entry in propertyJson.entries) {
      if (entry.key == 'service' || entry.key == 'characteristic') {
        if (entry.value is! String) {
          throw FormatException('${entry.key} must be a string');
        }
        continue;
      }
      properties[entry.key] = DeviceProperty.fromJson(
        mapOf(entry.value),
        frame,
        service: service,
        characteristic: characteristic,
      );
    }

    final result = DeviceDefinition(
      id: stringOf(json['id'], 'id'),
      name: stringOf(json['name'], 'name'),
      match: mapList(json['match'], DeviceMatchRule.fromJson),
      properties: properties,
      service: service,
      characteristic: characteristic,
      frame: frame,
    );
    result.validateDefinition();
    return result;
  }

  String toJsonString() => jsonEncode(toJson());

  DeviceProperty property(String propertyId) {
    final value = properties[propertyId];
    if (value == null) {
      throw StateError('Property not found: $propertyId');
    }
    return value;
  }

  /// 校验属性之间的引用以及每种能力自身的完整性
  void validateDefinition() {
    if (id.isEmpty) {
      throw FormatException('Device id must not be empty');
    }
    if (properties.isEmpty) {
      throw FormatException('Device $id must define at least one property');
    }

    for (final entry in properties.entries) {
      final propertyId = entry.key;
      final property = entry.value;
      final read = property.read;
      final write = property.write;
      final notify = property.notify;

      if (read != null) {
        if (read.op == OpType.subscribe) {
          throw FormatException('Property $propertyId read operation cannot be subscribe');
        }
        if (read.response == null) {
          throw FormatException('Property $propertyId read operation requires response');
        }
      }
      if (write != null) {
        if (write.op != OpType.write) {
          throw FormatException('Property $propertyId write operation must use op=write');
        }
        if (write.request == null) {
          throw FormatException('Property $propertyId write operation requires request');
        }
      }
      if (notify != null) {
        if (notify.op != OpType.subscribe) {
          throw FormatException('Property $propertyId notify operation must use op=subscribe');
        }
        if (notify.response == null) {
          throw FormatException('Property $propertyId notify operation requires response');
        }
      }

      for (final operation in <BlePropertyOp?>[read, write, notify]) {
        if (operation == null) continue;
        for (final field in operation.request?.fields ?? const <FrameFieldSpec>[]) {
          _validateFramePropertyReferences(propertyId, field);
        }
        for (final value in operation.response?.values ?? const <PacketNamedValueSpec>[]) {
          if (!properties.containsKey(value.property)) {
            throw FormatException(
              'Property $propertyId response references unknown property '
              '${value.property}',
            );
          }
        }
      }
    }
  }

  void _validateFramePropertyReferences(String ownerProperty, FrameFieldSpec field) {
    void requireProperty(String? id, String where) {
      if (id != null && !properties.containsKey(id)) {
        throw FormatException('Property $ownerProperty $where references unknown property $id');
      }
    }

    if (field.kind == FieldKind.property) {
      requireProperty(field.property, 'frame field(order=${field.order})');
    }
    requireProperty(
      field.condition?.source == ConditionSource.property ? field.condition?.property : null,
      'condition(order=${field.order})',
    );
    if (field.kind == FieldKind.bitField) {
      for (final part in field.bitField!.bits) {
        if (part.source == BitFieldSource.property) {
          requireProperty(part.property, 'bitField(order=${field.order}, part=${part.order})');
        }
        requireProperty(
          part.condition?.source == ConditionSource.property ? part.condition?.property : null,
          'bitField condition(order=${field.order}, part=${part.order})',
        );
      }
    }
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (match.isNotEmpty) 'match': [for (final rule in match) rule.toJson()],
    if (!frame.isDefault) 'frame': frame.toJson(),
    'properties': {
      if (service != null) 'service': service,
      if (characteristic != null) 'characteristic': characteristic,
      for (final entry in properties.entries) entry.key: entry.value.toJson(frame, service, characteristic),
    },
  };
}
