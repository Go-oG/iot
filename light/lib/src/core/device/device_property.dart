import 'package:light/src/core/device/template/frame_defaults.dart';

import 'ble_operation.dart';
import 'spec/permission_spec.dart';
import 'spec/ui_spec.dart';
import 'spec/value_spec.dart';
import 'util.dart';

class DeviceProperty {
  final String name;
  final String? description;
  final ValueSpec value;
  final UiSpec? ui;
  final PermissionSpec? permissions;
  final BlePropertyOp? read;
  final BlePropertyOp? write;
  final BlePropertyOp? notify;

  const DeviceProperty({
    required this.value,
    required this.name,
    this.description,
    this.ui,
    this.permissions,
    this.read,
    this.write,
    this.notify,
  });

  factory DeviceProperty.fromJson(
    Map<String, dynamic> json,
    FrameDefaults frame, {
    String? service,
    String? characteristic,
  }) {
    final propertyService = nullableString(json['service']) ?? service;
    final propertyCharacteristic = nullableString(json['characteristic']) ?? characteristic;
    return DeviceProperty(
      name: json['name'] as String,
      description: nullableString(json['description']),
      value: ValueSpec.fromJson(json),
      ui: json['ui'] == null ? null : UiSpec.fromJson(mapOf(json['ui'])),
      permissions: json['permissions'] == null ? null : PermissionSpec.fromJson(mapOf(json['permissions'])),
      read: json['read'] == null
          ? null
          : BlePropertyOp.fromJson(
              mapOf(json['read']),
              frame,
              defaultService: propertyService,
              defaultCharacteristic: propertyCharacteristic,
            ),
      write: json['write'] == null
          ? null
          : BlePropertyOp.fromJson(
              mapOf(json['write']),
              frame,
              defaultService: propertyService,
              defaultCharacteristic: propertyCharacteristic,
            ),
      notify: json['notify'] == null
          ? null
          : BlePropertyOp.fromJson(
              mapOf(json['notify']),
              frame,
              defaultService: propertyService,
              defaultCharacteristic: propertyCharacteristic,
            ),
    );
  }

  bool get canRead => read != null;

  bool get canWrite => write != null;

  bool get canNotify => notify != null;

  bool canRoleRead(Role role) => canRead && (permissions?.allowsRead(role) ?? true);

  bool canRoleWrite(Role role) => canWrite && (permissions?.allowsWrite(role) ?? true);

  bool canRoleNotify(Role role) => canNotify && (permissions?.allowsNotify(role) ?? true);

  Map<String, dynamic> toJson([FrameDefaults frame = const FrameDefaults(), String? service, String? characteristic]) =>
      {
        'name': name,
        if (description != null) 'description': description,
        ...value.toJson(),
        if (ui != null) 'ui': ui!.toJson(),
        if (permissions != null) 'permissions': permissions!.toJson(),
        if (read != null) 'read': read!.toJson(frame, service, characteristic),
        if (write != null) 'write': write!.toJson(frame, service, characteristic),
        if (notify != null) 'notify': notify!.toJson(frame, service, characteristic),
      };
}
