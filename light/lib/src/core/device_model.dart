import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'frame_template.dart';
/// Device Model
///
/// 设计约定：
/// 1. properties 的 type 是逻辑数据类型；codec.format 是线上的二进制类型
/// 2. read/write/notify 是否存在决定属性能力，不额外使用 access 字段
/// 3. permissions 是角色权限，不代表属性能力
/// 4. request.fields 的数组位置不参与帧语义，最终顺序只由 order 决定
/// 5. 所有 fields 在 JSON 解析后会按 order 排序，并拒绝重复 order
/// 6. 推荐 order 使用 10、20、30...，方便后续在中间插入字段
/// 7. checksum 的范围使用 fromOrder/toOrder 描述，不依赖最终 byte offset
/// 8. length 可以引用 packet、某个 field，或者一个 order 范围
/// 9. condition 在编码前求值；未激活字段不占长度，也不参与 checksum
/// 10. bitField.bits、object.fields、response.values 同样使用 order
/// 11. variable 用于 transactionId/sessionId/nonce 等运行时动态值
/// 12. response.values 支持一帧同时更新多个 property

/// 逻辑数据类型。wireName 是 JSON 中的规范写法，aliases 是兼容写法
enum ValueType {
  boolean('bool', {'bool', 'boolean'}),
  integer('int', {'int', 'integer'}),
  decimal('double', {'double', 'decimal'}),
  string('string', {'string', 'str'}),
  enumeration('enum', {'enum', 'enumeration'}),
  array('array', {'array', 'list'}),
  object('object', {'object', 'obj'});

  final String wireName;

  final Set<String> aliases;

  const ValueType(this.wireName, this.aliases);

  static ValueType valueOf(String value) {
    for (final v in values) {
      if (v.wireName == value || v.aliases.contains(value)) {
        return v;
      }
    }
    throw FormatException('Unsupported value type: $value');
  }
}

/// BLE 操作类型
enum OpType {
  read('read', {'r', 'read'}),
  write('write', {'w', 'write'}),
  subscribe('subscribe', {'subs', 'subscribe'});

  final String wireName;

  final Set<String> aliases;

  const OpType(this.wireName, this.aliases);

  static OpType valueOf(String value) {
    for (final v in values) {
      if (v.wireName == value || v.aliases.contains(value)) {
        return v;
      }
    }
    throw FormatException('Unsupported operation type: $value');
  }
}

/// 写入方式
enum WriteMode {
  withResponse('withResponse'),
  withoutResponse('withoutResponse');

  final String wireName;

  const WriteMode(this.wireName);

  static WriteMode valueOf(String value) {
    for (final v in values) {
      if (v.wireName == value) {
        return v;
      }
    }
    throw FormatException('Unsupported write mode: $value');
  }
}

/// 请求帧字段类型
enum FieldKind {
  constant('constant'),
  value('value'),
  property('property'),
  variable('variable'),
  bitField('bitField'),
  length('length'),
  sequence('sequence'),
  timestamp('timestamp'),
  checksum('checksum');

  final String wireName;

  const FieldKind(this.wireName);

  static FieldKind valueOf(String value) {
    for (final v in values) {
      if (v.wireName == value) {
        return v;
      }
    }
    throw FormatException('Unsupported field kind: $value');
  }
}

/// 大小端
enum DataEndian {
  big('big'),
  little('little');

  final String wireName;

  const DataEndian(this.wireName);

  bool get isBig => this == big;

  bool get isLittle => this == little;

  /// 未声明时按 big 处理
  static DataEndian valueOf(String? value) {
    if (value == null || value.isEmpty) {
      return big;
    }
    for (final v in values) {
      if (v.wireName == value) {
        return v;
      }
    }
    throw FormatException('Unsupported endian: $value');
  }
}

/// 长度前缀占用的字节宽度
enum LengthPrefix {
  uint8(1, {'u8'}),
  uint16(2, {'u16'}),
  uint32(4, {'u32'});

  final int byteLength;

  /// 帧定义里的规范写法是 name，aliases 是兼容写法
  final Set<String> aliases;

  const LengthPrefix(this.byteLength, this.aliases);

  bool matches(String value) => name == value || aliases.contains(value);

  static LengthPrefix valueOf(String value) {
    for (final v in values) {
      if (v.matches(value)) {
        return v;
      }
    }
    throw FormatException('Unsupported lengthPrefix: $value');
  }
}

// -----------------------------------------------------------------------------
// JSON helpers
// -----------------------------------------------------------------------------
Map<String, dynamic> _map(dynamic value) {
  return Map<String, dynamic>.from(value as Map);
}

Map<String, dynamic>? _nullableMap(dynamic value) {
  if (value == null) return null;
  return _map(value);
}

/// 解析对象数组，元素为 null 时按空数组处理
List<T> _mapList<T>(dynamic value, T Function(Map<String, dynamic>) fromJson) {
  if (value == null) return const [];
  return (value as List).map((e) => fromJson(_map(e))).toList(growable: false);
}

/// 解析整型，兼容 1.0 这类浮点写法
int _int(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  throw FormatException('Expected integer, got: $value');
}

int? _nullableInt(dynamic value) => value == null ? null : _int(value);

String _string(dynamic value, String name) {
  if (value is String && value.isNotEmpty) return value;
  throw FormatException('Expected non-empty string for $name, got: $value');
}

String? _nullableString(dynamic value) =>
    value == null ? null : value as String;

// -----------------------------------------------------------------------------
// Device model
// -----------------------------------------------------------------------------
class DeviceModel {
  final String id;
  final String name;
  final List<DeviceMatchRule> match;
  final Map<String, DevicePropertyModel> properties;

  /// 帧级默认值：裸写 ${length:u8} / ${crc16modbus} 时使用的默认跨度
  final FrameDefaults frame;

  const DeviceModel({
    required this.id,
    required this.name,
    required this.properties,
    this.match = const [],
    this.frame = const FrameDefaults(),
  });

  factory DeviceModel.fromJson(Map<String, dynamic> json) {
    final frame = json['frame'] == null
        ? const FrameDefaults()
        : FrameDefaults.fromJson(_map(json['frame']));
    final propertyJson = _map(json['properties']);
    final properties = <String, DevicePropertyModel>{};
    for (final entry in propertyJson.entries) {
      properties[entry.key] = DevicePropertyModel.fromJson(
        _map(entry.value),
        frame,
      );
    }

    final result = DeviceModel(
      id: _string(json['id'], 'id'),
      name: _string(json['name'], 'name'),
      match: _mapList(json['match'], DeviceMatchRule.fromJson),
      properties: properties,
      frame: frame,
    );
    result.validateDefinition();
    return result;
  }

  factory DeviceModel.fromJsonString(String source) {
    return DeviceModel.fromJson(_map(jsonDecode(source)));
  }

  String toJsonString() => jsonEncode(toJson());

  DevicePropertyModel property(String propertyId) {
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
          throw FormatException(
            'Property $propertyId read operation cannot be subscribe',
          );
        }
        if (read.response == null) {
          throw FormatException(
            'Property $propertyId read operation requires response',
          );
        }
      }
      if (write != null) {
        if (write.op != OpType.write) {
          throw FormatException(
            'Property $propertyId write operation must use op=write',
          );
        }
        if (write.request == null) {
          throw FormatException(
            'Property $propertyId write operation requires request',
          );
        }
      }
      if (notify != null) {
        if (notify.op != OpType.subscribe) {
          throw FormatException(
            'Property $propertyId notify operation must use op=subscribe',
          );
        }
        if (notify.response == null) {
          throw FormatException(
            'Property $propertyId notify operation requires response',
          );
        }
      }

      for (final operation in <BlePropertyOperation?>[read, write, notify]) {
        if (operation == null) continue;
        for (final field
        in operation.request?.fields ?? const <FrameFieldSpec>[]) {
          _validateFramePropertyReferences(propertyId, field);
        }
        for (final value
        in operation.response?.values ?? const <PacketNamedValueSpec>[]) {
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

  void _validateFramePropertyReferences(String ownerProperty,
      FrameFieldSpec field,) {
    void requireProperty(String? id, String where) {
      if (id != null && !properties.containsKey(id)) {
        throw FormatException(
          'Property $ownerProperty $where references unknown property $id',
        );
      }
    }

    if (field.kind == FieldKind.property) {
      requireProperty(field.property, 'frame field(order=${field.order})');
    }
    requireProperty(
      field.condition?.source == ConditionSource.property
          ? field.condition?.property
          : null,
      'condition(order=${field.order})',
    );
    if (field.kind == FieldKind.bitField) {
      for (final part in field.bitField!.bits) {
        if (part.source == BitFieldSource.property) {
          requireProperty(
            part.property,
            'bitField(order=${field.order}, part=${part.order})',
          );
        }
        requireProperty(
          part.condition?.source == ConditionSource.property
              ? part.condition?.property
              : null,
          'bitField condition(order=${field.order}, part=${part.order})',
        );
      }
    }
  }

  Map<String, dynamic> toJson() =>
      {
        'id': id,
        'name': name,
        if (match.isNotEmpty) 'match': [for (final rule in match) rule.toJson()],
        if (!frame.isDefault) 'frame': frame.toJson(),
        'properties': {
          for (final entry in properties.entries)
            entry.key: entry.value.toJson(frame),
        },
      };
}

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
      type: DeviceMatchType.valueOf(_string(json['type'], 'match.type')),
      value: _string(json['value'], 'match.value'),
      mask: _nullableString(json['mask']),
    );
    // mask 参与按位比较时长度必须与匹配值一致
    if (result.mask != null &&
        HexCodec
            .decode(result.mask!)
            .length !=
            HexCodec
                .decode(result.value)
                .length) {
      throw FormatException(
        'match mask length must equal value length: ${result.value}',
      );
    }
    return result;
  }

  Map<String, dynamic> toJson() =>
      {
        'type': type.wireName,
        'value': value,
        if (mask != null) 'mask': mask,
      };
}

class DevicePropertyModel {
  final String name;
  final String? description;
  final ValueSpec value;
  final UiSpec? ui;
  final PermissionSpec? permissions;
  final BlePropertyOperation? read;
  final BlePropertyOperation? write;
  final BlePropertyOperation? notify;

  const DevicePropertyModel({
    required this.value,
    required this.name,
    this.description,
    this.ui,
    this.permissions,
    this.read,
    this.write,
    this.notify,
  });

  factory DevicePropertyModel.fromJson(
    Map<String, dynamic> json,
    FrameDefaults frame,
  ) {
    return DevicePropertyModel(
      name: json['name'] as String,
      description: _nullableString(json['description']),
      value: ValueSpec.fromJson(json),
      ui: json['ui'] == null ? null : UiSpec.fromJson(_map(json['ui'])),
      permissions: json['permissions'] == null
          ? null
          : PermissionSpec.fromJson(_map(json['permissions'])),
      read: json['read'] == null
          ? null
          : BlePropertyOperation.fromJson(_map(json['read']), frame),
      write: json['write'] == null
          ? null
          : BlePropertyOperation.fromJson(_map(json['write']), frame),
      notify: json['notify'] == null
          ? null
          : BlePropertyOperation.fromJson(_map(json['notify']), frame),
    );
  }

  bool get canRead => read != null;

  bool get canWrite => write != null;

  bool get canNotify => notify != null;

  bool canRoleRead(Role role) =>
      canRead && (permissions?.allowsRead(role) ?? true);

  bool canRoleWrite(Role role) =>
      canWrite && (permissions?.allowsWrite(role) ?? true);

  bool canRoleNotify(Role role) =>
      canNotify && (permissions?.allowsNotify(role) ?? true);

  Map<String, dynamic> toJson([FrameDefaults frame = const FrameDefaults()]) =>
      {'name': name,
        if (description != null) 'description': description,
        ...value.toJson(),
        if (ui != null) 'ui': ui!.toJson(),
        if (permissions != null) 'permissions': permissions!.toJson(),
        if (read != null) 'read': read!.toJson(frame),
        if (write != null) 'write': write!.toJson(frame),
        if (notify != null) 'notify': notify!.toJson(frame),
      };
}

class ValueSpec {
  final ValueType type;
  final String? unit;
  final bool nullable;
  final Object? defaultValue;
  final bool hasDefault;
  final ValueConstraints? constraints;
  final List<EnumValueSpec> values;
  final ValueSpec? items;
  final Map<String, ValueSpec> properties;

  const ValueSpec({
    required this.type,
    this.unit,
    this.nullable = false,
    this.defaultValue,
    this.hasDefault = false,
    this.constraints,
    this.values = const [],
    this.items,
    this.properties = const {},
  });

  factory ValueSpec.fromJson(Map<String, dynamic> json) {
    final type = ValueType.valueOf(_string(json['type'], 'type'));
    final objectProperties = <String, ValueSpec>{};
    final propertiesJson = _nullableMap(json['properties']);
    if (propertiesJson != null) {
      for (final entry in propertiesJson.entries) {
        objectProperties[entry.key] = ValueSpec.fromJson(_map(entry.value));
      }
    }

    final result = ValueSpec(
      type: type,
      unit: _nullableString(json['unit']),
      nullable: json['nullable'] as bool? ?? false,
      defaultValue: json['default'],
      hasDefault: json.containsKey('default'),
      constraints: json['constraints'] == null
          ? null
          : ValueConstraints.fromJson(_map(json['constraints'])),
      values: _mapList(json['values'], EnumValueSpec.fromJson),
      items: json['items'] == null
          ? null
          : ValueSpec.fromJson(_map(json['items'])),
      properties: objectProperties,
    );

    result.validateDefinition();
    return result;
  }

  /// 校验类型与附属定义是否自洽
  void validateDefinition() {
    if (type == ValueType.enumeration && values.isEmpty) {
      throw FormatException('enum value must define values');
    }
    if (type != ValueType.enumeration && values.isNotEmpty) {
      throw FormatException(
        'values is only allowed for enum value, got ${type.wireName}',
      );
    }
    if (type == ValueType.array && items == null) {
      throw FormatException('array value must define items');
    }
    if (type != ValueType.array && items != null) {
      throw FormatException(
        'items is only allowed for array value, got ${type.wireName}',
      );
    }
    if (type == ValueType.object && properties.isEmpty) {
      throw FormatException('object value must define properties');
    }
    if (type != ValueType.object && properties.isNotEmpty) {
      throw FormatException(
        'properties is only allowed for object value, got ${type.wireName}',
      );
    }
    if (type == ValueType.enumeration) {
      final seen = <Object?>{};
      for (final item in values) {
        if (!seen.add(item.value)) {
          throw FormatException('duplicate enum value: ${item.value}');
        }
      }
    }
    constraints?.validate();
  }

  Map<String, dynamic> toJson() =>
      {
        'type': type.wireName,
        if (unit != null) 'unit': unit,
        if (nullable) 'nullable': true,
        if (hasDefault || defaultValue != null) 'default': defaultValue,
        if (constraints != null) 'constraints': constraints!.toJson(),
        if (values.isNotEmpty) 'values': [for (final item in values) item.toJson()],
        if (items != null) 'items': items!.toJson(),
        if (properties.isNotEmpty)
          'properties': {
            for (final entry in properties.entries) entry.key: entry.value.toJson(),
          },
      };
}

class ValueConstraints {
  final num? min;
  final num? max;
  final num? step;
  final int? minLength;
  final int? maxLength;
  final int? minItems;
  final int? maxItems;
  final String? pattern;

  const ValueConstraints({
    this.min,
    this.max,
    this.step,
    this.minLength,
    this.maxLength,
    this.minItems,
    this.maxItems,
    this.pattern,
  });

  factory ValueConstraints.fromJson(Map<String, dynamic> json) {
    final result = ValueConstraints(
      min: json['min'] as num?,
      max: json['max'] as num?,
      step: json['step'] as num?,
      minLength: _nullableInt(json['minLength']),
      maxLength: _nullableInt(json['maxLength']),
      minItems: _nullableInt(json['minItems']),
      maxItems: _nullableInt(json['maxItems']),
      pattern: _nullableString(json['pattern']),
    );
    result.validate();
    return result;
  }

  /// 校验约束本身是否矛盾
  void validate() {
    if (min != null && max != null && min! > max!) {
      throw FormatException('constraints min=$min must not exceed max=$max');
    }
    if (step != null && step! <= 0) {
      throw FormatException('constraints step must be > 0');
    }
    if ((minLength != null && minLength! < 0) ||
        (maxLength != null && maxLength! < 0)) {
      throw FormatException('constraints length must not be negative');
    }
    if (minLength != null && maxLength != null && minLength! > maxLength!) {
      throw FormatException(
        'constraints minLength=$minLength must not exceed maxLength=$maxLength',
      );
    }
    if ((minItems != null && minItems! < 0) ||
        (maxItems != null && maxItems! < 0)) {
      throw FormatException('constraints item count must not be negative');
    }
    if (minItems != null && maxItems != null && minItems! > maxItems!) {
      throw FormatException(
        'constraints minItems=$minItems must not exceed maxItems=$maxItems',
      );
    }
    if (pattern != null) {
      try {
        RegExp(pattern!);
      } on FormatException catch (e) {
        throw FormatException('invalid constraints pattern: ${e.message}');
      }
    }
  }

  Map<String, dynamic> toJson() =>
      {
        if (min != null) 'min': min,
        if (max != null) 'max': max,
        if (step != null) 'step': step,
        if (minLength != null) 'minLength': minLength,
        if (maxLength != null) 'maxLength': maxLength,
        if (minItems != null) 'minItems': minItems,
        if (maxItems != null) 'maxItems': maxItems,
        if (pattern != null) 'pattern': pattern,
      };
}

class EnumValueSpec {
  final Object value;
  final String label;
  final String? description;

  const EnumValueSpec({
    required this.value,
    required this.label,
    this.description,
  });

  factory EnumValueSpec.fromJson(Map<String, dynamic> json) {
    final value = json['value'];
    if (value == null) {
      throw FormatException('enum value must define a non-null value');
    }
    return EnumValueSpec(
      value: value,
      label: _string(json['label'], 'values[].label'),
      description: _nullableString(json['description']),
    );
  }

  Map<String, dynamic> toJson() =>
      {
        'value': value,
        'label': label,
        if (description != null) 'description': description,
      };
}

/// UI 渲染器类型
enum UiRenderer {
  toggle('switch'),
  slider('slider'),
  input('input'),
  stepper('stepper'),
  segmented('segmented'),
  color('color'),
  scheduleList('scheduleList'),
  hexEditor('hexEditor'),
  hidden('hidden');

  final String wireName;

  const UiRenderer(this.wireName);

  static UiRenderer valueOf(String value) {
    for (final v in values) {
      if (v.wireName == value) {
        return v;
      }
    }
    throw FormatException('Unsupported ui renderer: $value');
  }
}

class UiSpec {
  final UiRenderer renderer;
  final Map<String, dynamic> config;

  const UiSpec({required this.renderer, this.config = const {}});

  factory UiSpec.fromJson(Map<String, dynamic> json) {
    return UiSpec(
      renderer: UiRenderer.valueOf(_string(json['renderer'], 'ui.renderer')),
      config: json['config'] == null ? const {} : _map(json['config']),
    );
  }

  Map<String, dynamic> toJson() =>
      {
        'renderer': renderer.wireName,
        if (config.isNotEmpty) 'config': config,
      };
}

/// 角色，* 表示任意角色
enum Role {
  all('*'),
  user('user'),
  admin('admin'),
  factory('factory');

  final String wireName;

  const Role(this.wireName);

  static Role valueOf(String value) {
    for (final v in values) {
      if (v.wireName == value) {
        return v;
      }
    }
    throw FormatException('Unsupported role: $value');
  }
}

class PermissionSpec {
  final List<Role>? read;
  final List<Role>? write;
  final List<Role>? notify;

  const PermissionSpec({this.read, this.write, this.notify});

  factory PermissionSpec.fromJson(Map<String, dynamic> json) {
    return PermissionSpec(
      read: _roleList(json['read']),
      write: _roleList(json['write']),
      notify: _roleList(json['notify']),
    );
  }

  bool allowsRead(Role role) => _allows(read, role);

  bool allowsWrite(Role role) => _allows(write, role);

  bool allowsNotify(Role role) => _allows(notify, role);

  bool _allows(List<Role>? roles, Role role) {
    if (roles == null) return true;
    return roles.contains(Role.all) || roles.contains(role);
  }

  Map<String, dynamic> toJson() =>
      {
        if (read != null) 'read': [for (final role in read!) role.wireName],
        if (write != null) 'write': [for (final role in write!) role.wireName],
        if (notify != null) 'notify': [for (final role in notify!) role.wireName],
      };
}

List<Role>? _roleList(dynamic value) {
  if (value == null) return null;
  final roles = (value as List)
      .map((e) => Role.valueOf(e.toString()))
      .toList(growable: false);
  if (roles.isEmpty) {
    throw FormatException('permission role list must not be empty');
  }
  if (roles
      .toSet()
      .length != roles.length) {
    throw FormatException('permission role list contains duplicates');
  }
  return roles;
}

// -----------------------------------------------------------------------------
// BLE operation
// -----------------------------------------------------------------------------
class BlePropertyOperation {
  final OpType op;
  final String service;
  final String characteristic;
  final WriteMode? writeMode;
  final PacketEncodeSpec? request;
  final PacketDecodeSpec? response;
  final int? timeoutMs;

  const BlePropertyOperation({
    required this.op,
    required this.service,
    required this.characteristic,
    this.writeMode,
    this.request,
    this.response,
    this.timeoutMs,
  });

  factory BlePropertyOperation.fromJson(
    Map<String, dynamic> json,
    FrameDefaults frame,
  ) {
    final result = BlePropertyOperation(
      op: OpType.valueOf(_string(json['op'], 'op')),
      service: _string(json['service'], 'service'),
      characteristic: _string(json['characteristic'], 'characteristic'),
      writeMode: json['writeMode'] == null
          ? null
          : WriteMode.valueOf(_string(json['writeMode'], 'writeMode')),
      request: json['request'] == null
          ? null
          : PacketEncodeSpec.fromJson(_map(json['request']), frame),
      response: json['response'] == null
          ? null
          : PacketDecodeSpec.fromJson(_map(json['response'])),
      timeoutMs: _nullableInt(json['timeoutMs']),
    );
    if (result.timeoutMs != null && result.timeoutMs! <= 0) {
      throw FormatException('timeoutMs must be > 0');
    }
    if (result.writeMode != null && result.op != OpType.write) {
      throw FormatException('writeMode is only allowed for op=write');
    }
    return result;
  }

  Map<String, dynamic> toJson([FrameDefaults frame = const FrameDefaults()]) =>
      {
        'op': op.wireName,
        'service': service,
        'characteristic': characteristic,
        if (writeMode != null) 'writeMode': writeMode!.wireName,
        if (request != null) 'request': request!.toJson(frame),
        if (response != null) 'response': response!.toJson(),
        if (timeoutMs != null) 'timeoutMs': timeoutMs,
      };
}

// -----------------------------------------------------------------------------
// Request frame definition
// -----------------------------------------------------------------------------
class PacketEncodeSpec {
  /// 已按 order 升序排列。
  final List<FrameFieldSpec> fields;

  PacketEncodeSpec({required List<FrameFieldSpec> fields})
      : fields = _prepareFrameFields(fields);

  factory PacketEncodeSpec.fromJson(
    Map<String, dynamic> json,
    FrameDefaults frame,
  ) {
    final template = json['template'];
    if (template is! String || template.trim().isEmpty) {
      throw FormatException('request must define a frame template');
    }
    return FrameTemplate.parseRequest(
      template,
      defaults: frame,
      path: 'request.template',
    );
  }

  Map<String, dynamic> toJson([FrameDefaults frame = const FrameDefaults()]) =>
      {
        'template': FrameTemplate.writeRequest(this, defaults: frame),
      };
}

List<FrameFieldSpec> _prepareFrameFields(List<FrameFieldSpec> input) {
  final fields = List<FrameFieldSpec>.of(input)
    ..sort((a, b) => a.order.compareTo(b.order));
  final orders = <int>{};
  for (final field in fields) {
    if (field.order < 0) {
      throw FormatException('Frame field order must be >= 0: ${field.order}');
    }
    if (!orders.add(field.order)) {
      throw FormatException('Duplicate frame field order: ${field.order}');
    }
    field.validate();
  }

  // 第二阶段验证跨字段引用。order 是帧定义的稳定标识，不依赖 JSON 数组位置。
  for (final field in fields) {
    if (field.kind == FieldKind.length) {
      final length = field.length!;
      if (length.source == LengthSource.field &&
          length.fieldOrder == field.order) {
        throw FormatException(
          'length field(order=${field.order}) cannot reference itself',
        );
      }
      if (length.source == LengthSource.field &&
          !orders.contains(length.fieldOrder)) {
        throw FormatException(
          'length field(order=${field.order}) references unknown '
              'fieldOrder=${length.fieldOrder}',
        );
      }
      if (length.source == LengthSource.range) {
        final hasField = fields.any(
              (candidate) =>
          candidate.order >= length.fromOrder! &&
              candidate.order <= length.toOrder!,
        );
        if (!hasField) {
          throw FormatException(
            'length field(order=${field.order}) references empty range '
                '${length.fromOrder}..${length.toOrder}',
          );
        }
      }
    }

    if (field.kind == FieldKind.checksum) {
      final checksum = field.checksum!;
      if (checksum.fromOrder != null && !orders.contains(checksum.fromOrder)) {
        throw FormatException(
          'checksum field(order=${field.order}) references unknown '
              'fromOrder=${checksum.fromOrder}',
        );
      }
      if (checksum.fromOrder != null &&
          checksum.toOrder != null &&
          checksum.fromOrder! > checksum.toOrder!) {
        throw FormatException(
          'checksum field(order=${field.order}) has invalid range '
              '${checksum.fromOrder}..${checksum.toOrder}',
        );
      }
      if (checksum.toOrder != null && checksum.toOrder! >= field.order) {
        throw FormatException(
          'checksum field(order=${field.order}) cannot depend on itself '
              'or a later field: toOrder=${checksum.toOrder}',
        );
      }
    }
  }

  return List<FrameFieldSpec>.unmodifiable(fields);
}

/// 条件取值来源
enum ConditionSource {
  value('value'),
  property('property'),
  variable('variable'),
  sequence('sequence');

  final String wireName;

  const ConditionSource(this.wireName);

  static ConditionSource valueOf(String value) {
    for (final v in values) {
      if (v.wireName == value) {
        return v;
      }
    }
    throw FormatException('Unsupported condition source: $value');
  }
}

/// 条件比较运算符
enum ConditionOperator {
  eq('eq'),
  ne('ne'),
  gt('gt'),
  gte('gte'),
  lt('lt'),
  lte('lte'),
  isIn('in'),
  notIn('notIn'),
  exists('exists'),
  notExists('notExists'),
  bitSet('bitSet'),
  bitClear('bitClear');

  final String wireName;

  const ConditionOperator(this.wireName);

  static ConditionOperator valueOf(String value) {
    for (final v in values) {
      if (v.wireName == value) {
        return v;
      }
    }
    throw FormatException('Unsupported condition operator: $value');
  }
}

class FrameConditionSpec {
  final ConditionSource source;

  /// source=property
  final String? property;

  /// source=variable
  final String? variable;

  final ConditionOperator operator;

  final Object? value;
  final List<Object?> values;
  final int? mask;

  const FrameConditionSpec({
    required this.source,
    required this.operator,
    this.property,
    this.variable,
    this.value,
    this.values = const [],
    this.mask,
  });

  /// 校验来源与运算符所需的参数是否齐全
  void validate() {
    switch (source) {
      case ConditionSource.value:
      case ConditionSource.sequence:
        break;
      case ConditionSource.property:
        if (property == null || property!.isEmpty) {
          throw FormatException('condition source=property requires property');
        }
        break;
      case ConditionSource.variable:
        if (variable == null || variable!.isEmpty) {
          throw FormatException('condition source=variable requires variable');
        }
        break;
    }

    switch (operator) {
      case ConditionOperator.eq:
      case ConditionOperator.ne:
      case ConditionOperator.gt:
      case ConditionOperator.gte:
      case ConditionOperator.lt:
      case ConditionOperator.lte:
        break;
      case ConditionOperator.isIn:
      case ConditionOperator.notIn:
        if (values.isEmpty) {
          throw FormatException(
            'condition operator=${operator.wireName} requires values',
          );
        }
        break;
      case ConditionOperator.exists:
      case ConditionOperator.notExists:
        break;
      case ConditionOperator.bitSet:
      case ConditionOperator.bitClear:
        if (mask == null || mask! <= 0) {
          throw FormatException(
            'condition operator=${operator.wireName} requires mask > 0',
          );
        }
        break;
    }
  }

  bool evaluate(PacketEncodeContext context) {
    final exists = switch (source) {
      ConditionSource.value => true,
      ConditionSource.sequence => true,
      ConditionSource.property => context.properties.containsKey(property),
      ConditionSource.variable => context.variables.containsKey(variable),
    };

    if (operator == ConditionOperator.exists) return exists;
    if (operator == ConditionOperator.notExists) return !exists;
    if (!exists) return false;

    final actual = switch (source) {
      ConditionSource.value => context.value,
      ConditionSource.sequence => context.sequence,
      ConditionSource.property => context.properties[property],
      ConditionSource.variable => context.variables[variable],
    };

    switch (operator) {
      case ConditionOperator.eq:
        return actual == value;
      case ConditionOperator.ne:
        return actual != value;
      case ConditionOperator.gt:
        return _compareNumber(actual, value) > 0;
      case ConditionOperator.gte:
        return _compareNumber(actual, value) >= 0;
      case ConditionOperator.lt:
        return _compareNumber(actual, value) < 0;
      case ConditionOperator.lte:
        return _compareNumber(actual, value) <= 0;
      case ConditionOperator.isIn:
        return values.contains(actual);
      case ConditionOperator.notIn:
        return !values.contains(actual);
      case ConditionOperator.bitSet:
        if (actual is! num) {
          throw StateError('bitSet condition requires numeric actual value');
        }
        return (actual.toInt() & mask!) != 0;
      case ConditionOperator.bitClear:
        if (actual is! num) {
          throw StateError('bitClear condition requires numeric actual value');
        }
        return (actual.toInt() & mask!) == 0;
      case ConditionOperator.exists:
      case ConditionOperator.notExists:
        throw StateError(
          'Unreachable condition operator: ${operator.wireName}',
        );
    }
  }

  static int _compareNumber(Object? a, Object? b) {
    if (a is! num || b is! num) {
      throw StateError('Numeric condition requires num values: $a, $b');
    }
    return a.toDouble().compareTo(b.toDouble());
  }

}

class BitFieldSpec {
  /// 位域最终占用的字节数。
  final int byteLength;

  /// 只影响最终多字节序列化。
  /// bitOffset 始终从数值最低位开始计数，0 表示 bit0。
  final DataEndian endian;

  /// 已按 order 排序。
  final List<BitFieldPartSpec> bits;

  BitFieldSpec({
    required this.byteLength,
    this.endian = DataEndian.big,
    required List<BitFieldPartSpec> bits,
  }) : bits = _prepareBitFieldParts(bits) {
    if (byteLength <= 0 || byteLength > 8) {
      throw FormatException('bitField byteLength must be 1..8');
    }
    if (bits.isEmpty) {
      throw FormatException('bitField must define at least one part');
    }
    _validateRange();
  }

  void _validateRange() {
    final occupied = <int>{};
    final maxBits = byteLength * 8;
    for (final part in bits) {
      if (part.bitOffset < 0 || part.bitLength <= 0) {
        throw FormatException(
          'Invalid bitField part order=${part.order}: '
              'offset=${part.bitOffset}, length=${part.bitLength}',
        );
      }
      if (part.bitOffset + part.bitLength > maxBits) {
        throw FormatException(
          'bitField part order=${part.order} exceeds $maxBits bits',
        );
      }
      for (
      var bit = part.bitOffset;
      bit < part.bitOffset + part.bitLength;
      bit++
      ) {
        if (!occupied.add(bit)) {
          throw FormatException('bitField bit overlap at bit=$bit');
        }
      }
    }
  }

}

/// 位域取值来源
enum BitFieldSource {
  constant('constant'),
  value('value'),
  property('property'),
  variable('variable'),
  sequence('sequence');

  final String wireName;

  const BitFieldSource(this.wireName);

  static BitFieldSource valueOf(String value) {
    for (final v in values) {
      if (v.wireName == value) {
        return v;
      }
    }
    throw FormatException('Unsupported bitField source: $value');
  }
}

class BitFieldPartSpec {
  final int order;

  final BitFieldSource source;

  final String? property;
  final String? variable;
  final int? value;

  final int bitOffset;
  final int bitLength;

  /// 条件不成立时，该位段按 0 处理。
  final FrameConditionSpec? condition;

  const BitFieldPartSpec({
    required this.order,
    required this.source,
    required this.bitOffset,
    required this.bitLength,
    this.property,
    this.variable,
    this.value,
    this.condition,
  });

  void validate() {
    if (order < 0) {
      throw FormatException('bitField part order must be >= 0: $order');
    }
    switch (source) {
      case BitFieldSource.constant:
        if (value == null) {
          throw FormatException('bitField constant requires value');
        }
        break;
      case BitFieldSource.value:
      case BitFieldSource.sequence:
        break;
      case BitFieldSource.property:
        if (property == null || property!.isEmpty) {
          throw FormatException('bitField property source requires property');
        }
        break;
      case BitFieldSource.variable:
        if (variable == null || variable!.isEmpty) {
          throw FormatException('bitField variable source requires variable');
        }
        break;
    }
  }

}

List<BitFieldPartSpec> _prepareBitFieldParts(List<BitFieldPartSpec> input) {
  final parts = List<BitFieldPartSpec>.of(input)
    ..sort((a, b) => a.order.compareTo(b.order));
  final orders = <int>{};
  for (final part in parts) {
    if (!orders.add(part.order)) {
      throw FormatException('Duplicate bitField part order: ${part.order}');
    }
  }
  return List<BitFieldPartSpec>.unmodifiable(parts);
}

/// 时间戳单位
enum TimestampUnit {
  seconds('seconds'),
  milliseconds('milliseconds');

  final String wireName;

  const TimestampUnit(this.wireName);

  static TimestampUnit valueOf(String value) {
    for (final v in values) {
      if (v.wireName == value) {
        return v;
      }
    }
    throw FormatException('Unsupported timestampUnit: $value');
  }
}

class FrameFieldSpec {
  final int order;
  final FieldKind kind;

  /// 字段名，供 length / checksum 的跨度引用，模板里的 `${property.mode:u8}` 等
  /// 名字会写在这里
  final String? name;

  /// 当条件不成立时，整个字段不参与帧、length 和 checksum。
  final FrameConditionSpec? condition;

  /// constant
  final String? hex;

  /// property
  final String? property;

  /// variable
  final String? variable;

  /// value/property/variable/length/sequence/timestamp
  final WireCodecSpec? codec;

  /// bitField
  final BitFieldSpec? bitField;

  /// length
  final LengthSpec? length;

  /// timestamp
  final TimestampUnit? timestampUnit;

  /// checksum
  final ChecksumSpec? checksum;

  const FrameFieldSpec({
    required this.order,
    required this.kind,
    this.name,
    this.condition,
    this.hex,
    this.property,
    this.variable,
    this.codec,
    this.bitField,
    this.length,
    this.timestampUnit,
    this.checksum,
  });

  /// 校验字段类型所需的参数是否齐全
  void validate() {
    switch (kind) {
      case FieldKind.constant:
        if (hex == null || hex!.isEmpty) {
          throw FormatException('constant field(order=$order) requires hex');
        }
        HexCodec.decode(hex!);
        break;
      case FieldKind.value:
        if (codec == null) {
          throw FormatException('value field(order=$order) requires codec');
        }
        break;
      case FieldKind.property:
        if (property == null || property!.isEmpty || codec == null) {
          throw FormatException(
            'property field(order=$order) requires property and codec',
          );
        }
        break;
      case FieldKind.variable:
        if (variable == null || variable!.isEmpty || codec == null) {
          throw FormatException(
            'variable field(order=$order) requires variable and codec',
          );
        }
        break;
      case FieldKind.bitField:
        if (bitField == null) {
          throw FormatException(
            'bitField field(order=$order) requires bitField',
          );
        }
        break;
      case FieldKind.length:
        if (length == null || codec == null) {
          throw FormatException(
            'length field(order=$order) requires length and codec',
          );
        }
        if (codec!.fixedByteLength == null) {
          throw FormatException(
            'length field(order=$order) codec must have fixed byte length',
          );
        }
        break;
      case FieldKind.sequence:
        if (codec == null || codec!.fixedByteLength == null) {
          throw FormatException(
            'sequence field(order=$order) requires fixed-length codec',
          );
        }
        break;
      case FieldKind.timestamp:
        if (codec == null ||
            (codec!.format != ValueFormat.uint32 &&
                codec!.format != ValueFormat.uint64)) {
          throw FormatException(
            'timestamp field(order=$order) requires uint32/uint64 codec',
          );
        }
        break;
      case FieldKind.checksum:
        if (checksum == null) {
          throw FormatException(
            'checksum field(order=$order) requires checksum',
          );
        }
        break;
    }
  }

}

/// 长度字段的计算来源
enum LengthSource {
  packet('packet'),
  field('field'),
  range('range');

  final String wireName;

  const LengthSource(this.wireName);

  static LengthSource valueOf(String value) {
    for (final v in values) {
      if (v.wireName == value) {
        return v;
      }
    }
    throw FormatException('Unsupported length source: $value');
  }
}

class LengthSpec {
  /// packet 表示整帧字节数（含 length 字段与 checksum 字段自身）
  final LengthSource source;

  /// source=field
  final int? fieldOrder;

  /// source=range
  final int? fromOrder;
  final int? toOrder;

  /// 某些协议 length = 实际长度 + 固定值
  final int adjust;

  const LengthSpec({
    required this.source,
    this.fieldOrder,
    this.fromOrder,
    this.toOrder,
    this.adjust = 0,
  });

  /// 校验来源与 order 参数是否自洽
  void validate() {
    switch (source) {
      case LengthSource.packet:
        break;
      case LengthSource.field:
        if (fieldOrder == null) {
          throw FormatException('length source=field requires fieldOrder');
        }
        break;
      case LengthSource.range:
        if (fromOrder == null || toOrder == null || fromOrder! > toOrder!) {
          throw FormatException(
            'length source=range requires valid fromOrder/toOrder',
          );
        }
        break;
    }
  }

}

enum CheckSumAlg {
  sum8('sum8', {'checksum8'}),
  xor8('xor8', {}),
  crc8('crc8', {}),
  crc16('crc16', {}),
  crc16Modbus('crc16Modbus', {'modbus', 'crc16-modbus'}),
  crc16CcittFalse('crc16CcittFalse', {'ccitt', 'crc16-ccitt'}),
  crc32('crc32', {});

  final String wireName;

  /// 帧模板里的兼容写法
  final Set<String> aliases;

  const CheckSumAlg(this.wireName, this.aliases);

  /// 大小写不敏感，帧模板里通常写成小写
  bool matches(String value) {
    final normalized = value.toLowerCase();
    return wireName.toLowerCase() == normalized ||
        aliases.contains(normalized);
  }

  /// 校验字节数
  int get byteLength =>
      switch (this) {
        CheckSumAlg.sum8 || CheckSumAlg.xor8 || CheckSumAlg.crc8 => 1,
        CheckSumAlg.crc16 ||
        CheckSumAlg.crc16Modbus ||
        CheckSumAlg.crc16CcittFalse => 2,
        CheckSumAlg.crc32 => 4,
      };

  static CheckSumAlg valueOf(String value) {
    for (final v in values) {
      if (v.matches(value)) {
        return v;
      }
    }
    throw FormatException('Unsupported checksum algorithm: $value');
  }
}

class ChecksumSpec {
  final CheckSumAlg alg;

  /// 请求帧中按 field order 选择校验范围
  final int? fromOrder;
  final int? toOrder;

  ///对 1-byte checksum 无影响
  final DataEndian endian;

  final Map<String, dynamic> options;

  const ChecksumSpec({
    required this.alg,
    this.fromOrder,
    this.toOrder,
    this.endian = DataEndian.big,
    this.options = const {},
  });

  int get byteLength => alg.byteLength;
}

// -----------------------------------------------------------------------------
// Response frame definition
// -----------------------------------------------------------------------------
class PacketDecodeSpec {
  final String? service;
  final String? characteristic;
  final List<PacketMatchSpec> match;

  /// 单值响应，兼容简单 property read/notify
  final PacketValueSpec? value;

  /// 一帧同时更新多个属性时使用。已按 order 排序
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

  factory PacketDecodeSpec.fromJson(Map<String, dynamic> json) {
    final template = json['template'];
    if (template is! String || template.trim().isEmpty) {
      throw FormatException('response must define a frame template');
    }
    return FrameTemplate.parseResponse(
      template,
      service: _nullableString(json['service']),
      characteristic: _nullableString(json['characteristic']),
      path: 'response.template',
    );
  }

  /// 一帧是否更新多个 property
  bool get isMultiValue => values.isNotEmpty;

  Map<String, dynamic> toJson() => {
    if (service != null) 'service': service,
    if (characteristic != null) 'characteristic': characteristic,
    'template': FrameTemplate.writeResponse(this),
  };
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

  const PacketValueSpec({
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

List<PacketNamedValueSpec> _prepareResponseValues(List<PacketNamedValueSpec> input,) {
  final values = List<PacketNamedValueSpec>.of(input)
    ..sort((a, b) => a.order.compareTo(b.order));
  final orders = <int>{};
  final properties = <String>{};
  for (final value in values) {
    if (value.order < 0 || !orders.add(value.order)) {
      throw FormatException(
        'Duplicate/invalid response value order: ${value.order}',
      );
    }
    if (value.property.isEmpty || !properties.add(value.property)) {
      throw FormatException(
        'Duplicate/invalid response property: ${value.property}',
      );
    }
  }
  return List<PacketNamedValueSpec>.unmodifiable(values);
}

/// 响应校验范围的结束位置
enum ResponseChecksumEnd {
  beforeChecksum('beforeChecksum');

  final String wireName;

  const ResponseChecksumEnd(this.wireName);

  static ResponseChecksumEnd valueOf(String value) {
    for (final v in values) {
      if (v.wireName == value) {
        return v;
      }
    }
    throw FormatException('Unsupported response checksum end: $value');
  }
}

class ResponseChecksumSpec {
  final CheckSumAlg alg;
  final int start;

  /// 结束位置：int 表示独占结束偏移（支持负数）
  /// ResponseChecksumEnd.beforeChecksum 表示到校验字段开始处
  /// null 等价于 beforeChecksum
  final Object? end;

  /// 支持负数，-1 表示最后一个 byte
  final int offset;
  final int length;
  final DataEndian endian;
  final Map<String, dynamic> options;

  const ResponseChecksumSpec({
    required this.alg,
    required this.offset,
    required this.length,
    this.start = 0,
    this.end,
    this.endian = DataEndian.big,
    this.options = const {},
  });

  /// 校验字节数必须与算法一致
  void validate() {
    if (length <= 0) {
      throw FormatException('response checksum length must be > 0');
    }
    if (length != alg.byteLength) {
      throw FormatException(
        'response checksum length=$length does not match '
            '${alg.wireName} (${alg.byteLength} bytes)',
      );
    }
  }
}

/// 帧内的二进制编码格式
///
/// wireName 是帧模板里的规范写法，aliases 是兼容写法
enum ValueFormat {
  bool8('bool8', {'bool'}),
  uint8('u8', {'uint8', 'byte'}),
  int8('i8', {'int8'}),
  uint16('u16', {'uint16'}),
  int16('i16', {'int16'}),
  uint32('u32', {'uint32'}),
  int32('i32', {'int32'}),
  uint64('u64', {'uint64'}),
  int64('i64', {'int64'}),
  float32('f32', {'float32'}),
  float64('f64', {'float64'}),
  utf8('utf8', {'utf-8'}),
  ascii('ascii', {}),
  bytes('bytes', {'byte[]'}),
  array('array', {'list'}),
  object('object', {'obj'});

  const ValueFormat(this.wireName, this.aliases);

  final String wireName;
  final Set<String> aliases;

  bool matches(String value) => wireName == value || aliases.contains(value);

  static ValueFormat valueOf(String value) {
    for (final v in values) {
      if (v.matches(value)) {
        return v;
      }
    }
    throw FormatException('Unsupported wire format: $value');
  }
}

// -----------------------------------------------------------------------------
// Wire codec
// -----------------------------------------------------------------------------
class WireCodecSpec {
  final ValueFormat format;
  final DataEndian endian;

  /// logical = raw * scale + offset
  final double scale;
  final double offset;

  /// string/bytes 可以使用固定长度。
  final int? fixedLength;

  /// string: 前缀表示 byte 长度。
  /// array: 前缀表示 item 数量。
  final LengthPrefix? lengthPrefix;

  final int trueValue;
  final int falseValue;

  /// array
  final WireCodecSpec? item;

  /// object，解析后已经按 order 排序。
  final List<WireObjectFieldSpec> fields;

  final Map<String, dynamic> options;

  WireCodecSpec({
    required this.format,
    this.endian = DataEndian.big,
    this.scale = 1.0,
    this.offset = 0.0,
    this.fixedLength,
    this.lengthPrefix,
    this.trueValue = 1,
    this.falseValue = 0,
    this.item,
    List<WireObjectFieldSpec> fields = const [],
    this.options = const {},
  }) : fields = _prepareObjectFields(fields);

  /// 校验编码参数的适用范围
  void validate() {
    if (scale == 0) {
      throw FormatException('codec scale must not be 0');
    }
    if (fixedLength != null && fixedLength! <= 0) {
      throw FormatException('codec fixedLength must be > 0');
    }
    if (format == ValueFormat.array && item == null) {
      throw FormatException('array codec requires item');
    }
    if (format != ValueFormat.array && item != null) {
      throw FormatException(
        'item is only allowed for array codec, got ${format.name}',
      );
    }
    if (format == ValueFormat.object && fields.isEmpty) {
      throw FormatException('object codec requires fields');
    }
    if (format != ValueFormat.object && fields.isNotEmpty) {
      throw FormatException(
        'fields is only allowed for object codec, got ${format.name}',
      );
    }
    if (lengthPrefix != null && format == ValueFormat.bool8) {
      throw FormatException('bool8 codec does not support lengthPrefix');
    }
    if (format == ValueFormat.array && item!.fixedByteLength == null) {
      throw FormatException('array codec requires fixed-size item codec');
    }
    if (format == ValueFormat.object && fixedLength == null) {
      for (final field in fields) {
        if (field.codec.fixedByteLength == null) {
          throw FormatException(
            'object codec requires fixed-size field codec: ${field.name}',
          );
        }
      }
    }
  }

  int? get fixedByteLength {
    switch (format) {
      case ValueFormat.bool8:
      case ValueFormat.uint8:
      case ValueFormat.int8:
        return 1;
      case ValueFormat.uint16:
      case ValueFormat.int16:
        return 2;
      case ValueFormat.uint32:
      case ValueFormat.int32:
      case ValueFormat.float32:
        return 4;
      case ValueFormat.uint64:
      case ValueFormat.int64:
      case ValueFormat.float64:
        return 8;
      case ValueFormat.utf8:
      case ValueFormat.ascii:
      case ValueFormat.bytes:
        if (lengthPrefix != null) return null;
        return fixedLength;
      case ValueFormat.object:
        if (lengthPrefix != null) return null;
        var total = 0;
        for (final field in fields) {
          final size = field.codec.fixedByteLength;
          if (size == null) return null;
          total += size;
        }
        return total;
      case ValueFormat.array:
        return null;
    }
  }

}

class WireObjectFieldSpec {
  final int order;
  final String name;
  final WireCodecSpec codec;

  const WireObjectFieldSpec({
    required this.order,
    required this.name,
    required this.codec,
  });

}

List<WireObjectFieldSpec> _prepareObjectFields(List<WireObjectFieldSpec> input,) {
  final fields = List<WireObjectFieldSpec>.of(input)
    ..sort((a, b) => a.order.compareTo(b.order));
  final orders = <int>{};
  for (final field in fields) {
    if (!orders.add(field.order)) {
      throw FormatException('Duplicate object field order: ${field.order}');
    }
  }
  return List<WireObjectFieldSpec>.unmodifiable(fields);
}

// -----------------------------------------------------------------------------
// Runtime encode context
// -----------------------------------------------------------------------------
class PacketEncodeContext {
  /// 当前被写入的 property 新值
  final Object? value;

  /// 当前设备其它 property 的已知状态，供 kind=property 使用。
  final Map<String, Object?> properties;

  /// 会话级或调用级动态变量，例如 transactionId、sessionId、nonce。
  final Map<String, Object?> variables;

  /// 由调用方维护的请求序号。
  final int sequence;

  final DateTime timestamp;

  PacketEncodeContext({
    required this.value,
    this.properties = const {},
    this.variables = const {},
    this.sequence = 0,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

// -----------------------------------------------------------------------------
// Packet encoder
// -----------------------------------------------------------------------------
class PacketEncoder {
  const PacketEncoder._();

  static Uint8List encode(PacketEncodeSpec spec, PacketEncodeContext context) {
    // condition 在任何长度/CRC 计算之前求值。未激活字段等同于不存在。
    final activeFields = spec.fields
        .where((field) => field.condition?.evaluate(context) ?? true)
        .toList(growable: false);

    final segments = <int, Uint8List>{};
    final widths = <int, int>{};

    // Phase 1: 编码所有非 length/checksum 字段，并确定活动字段宽度。
    for (final field in activeFields) {
      switch (field.kind) {
        case FieldKind.constant:
          final bytes = Uint8List.fromList(HexCodec.decode(field.hex!));
          segments[field.order] = bytes;
          widths[field.order] = bytes.length;
          break;

        case FieldKind.value:
          final bytes = WireCodec.encode(context.value, field.codec!);
          segments[field.order] = bytes;
          widths[field.order] = bytes.length;
          break;

        case FieldKind.property:
          if (!context.properties.containsKey(field.property)) {
            throw StateError(
              'Property state not found for frame field: ${field.property}',
            );
          }
          final bytes = WireCodec.encode(
            context.properties[field.property],
            field.codec!,
          );
          segments[field.order] = bytes;
          widths[field.order] = bytes.length;
          break;

        case FieldKind.variable:
          if (!context.variables.containsKey(field.variable)) {
            throw StateError(
              'Runtime variable not found for frame field: ${field.variable}',
            );
          }
          final bytes = WireCodec.encode(
            context.variables[field.variable],
            field.codec!,
          );
          segments[field.order] = bytes;
          widths[field.order] = bytes.length;
          break;

        case FieldKind.bitField:
          final bytes = _encodeBitField(field.bitField!, context);
          segments[field.order] = bytes;
          widths[field.order] = bytes.length;
          break;

        case FieldKind.sequence:
          final bytes = WireCodec.encode(context.sequence, field.codec!);
          segments[field.order] = bytes;
          widths[field.order] = bytes.length;
          break;

        case FieldKind.timestamp:
          final unit = field.timestampUnit ?? TimestampUnit.milliseconds;
          final timestampValue = switch (unit) {
            TimestampUnit.seconds =>
            context.timestamp.millisecondsSinceEpoch ~/ 1000,
            TimestampUnit.milliseconds =>
            context.timestamp.millisecondsSinceEpoch,
          };
          final bytes = WireCodec.encode(timestampValue, field.codec!);
          segments[field.order] = bytes;
          widths[field.order] = bytes.length;
          break;

        case FieldKind.length:
          widths[field.order] = field.codec!.fixedByteLength!;
          break;

        case FieldKind.checksum:
          widths[field.order] = field.checksum!.byteLength;
          break;
      }
    }

    // Phase 2: 解析 length。packet/range 仅统计实际激活字段。
    for (final field in activeFields) {
      if (field.kind != FieldKind.length) continue;
      final length = _resolveLength(field.length!, widths);
      final bytes = WireCodec.encode(length, field.codec!);
      if (bytes.length != widths[field.order]) {
        throw StateError(
          'Length field(order=${field.order}) encoded width changed unexpectedly',
        );
      }
      segments[field.order] = bytes;
    }

    // Phase 3: checksum 只能依赖其之前已经解析完成的活动字段。
    for (final field in activeFields) {
      if (field.kind != FieldKind.checksum) continue;

      final checksum = field.checksum!;
      final input = BytesBuilder(copy: false);

      final fromOrder = checksum.fromOrder;
      for (final candidate in activeFields) {
        // fromOrder/toOrder 都是闭区间；未指定 fromOrder 表示从帧首开始
        // 未指定 toOrder 表示范围到本校验字段之前
        if (fromOrder != null && candidate.order < fromOrder) continue;
        if (candidate.order > (checksum.toOrder ?? field.order - 1)) continue;

        final data = segments[candidate.order];
        if (data == null) {
          throw StateError(
            'Checksum(order=${field.order}) references unresolved field '
                'order=${candidate.order}',
          );
        }
        input.add(data);
      }

      final bytes = ChecksumCodec.calculate(
        checksum.alg,
        input.takeBytes(),
        endian: checksum.endian,
        options: checksum.options,
      );

      if (bytes.length != checksum.byteLength) {
        throw StateError(
          'Checksum ${checksum.alg.wireName} returned invalid byte length',
        );
      }
      segments[field.order] = bytes;
    }

    // Phase 4: 最终帧严格按 order 输出，未激活字段完全不输出。
    final result = BytesBuilder(copy: false);
    for (final field in activeFields) {
      final bytes = segments[field.order];
      if (bytes == null) {
        throw StateError('Frame field unresolved: order=${field.order}');
      }
      result.add(bytes);
    }
    return result.takeBytes();
  }

  static Uint8List _encodeBitField(BitFieldSpec spec,
      PacketEncodeContext context,) {
    var aggregate = 0;

    for (final part in spec.bits) {
      if (!(part.condition?.evaluate(context) ?? true)) {
        continue;
      }

      final raw = switch (part.source) {
        BitFieldSource.constant => part.value,
        BitFieldSource.value => context.value,
        BitFieldSource.sequence => context.sequence,
        BitFieldSource.property =>
        context.properties.containsKey(part.property)
            ? context.properties[part.property]
            : throw StateError(
          'Property state not found for bitField: ${part.property}',
        ),
        BitFieldSource.variable =>
        context.variables.containsKey(part.variable)
            ? context.variables[part.variable]
            : throw StateError(
          'Runtime variable not found for bitField: ${part.variable}',
        ),
      };

      final value = _toBitInt(raw);
      final maxValue = (1 << part.bitLength) - 1;
      if (value < 0 || value > maxValue) {
        throw RangeError(
          'bitField part(order=${part.order}) value=$value does not fit '
              '${part.bitLength} bits',
        );
      }

      aggregate |= value << part.bitOffset;
    }

    final result = Uint8List(spec.byteLength);
    for (var i = 0; i < spec.byteLength; i++) {
      final byte = (aggregate >> (i * 8)) & 0xFF;
      final index = spec.endian.isLittle ? i : spec.byteLength - 1 - i;
      result[index] = byte;
    }
    return result;
  }

  static int _toBitInt(Object? value) {
    if (value is bool) return value ? 1 : 0;
    if (value is num) return value.toInt();
    throw ArgumentError('bitField source requires bool/num, got $value');
  }

  static int _resolveLength(LengthSpec spec, Map<int, int> widths) {
    int value;
    switch (spec.source) {
      case LengthSource.packet:
        value = widths.values.fold<int>(0, (sum, item) => sum + item);
        break;
      case LengthSource.field:
      // 被 condition 排除的字段长度视为 0。
        value = widths[spec.fieldOrder] ?? 0;
        break;
      case LengthSource.range:
        value = 0;
        for (final entry in widths.entries) {
          if (entry.key >= spec.fromOrder! && entry.key <= spec.toOrder!) {
            value += entry.value;
          }
        }
        break;
    }
    return value + spec.adjust;
  }
}

// -----------------------------------------------------------------------------
// Packet decoder
// -----------------------------------------------------------------------------
class PacketDecoder {
  const PacketDecoder._();

  static bool matches(PacketDecodeSpec spec, Uint8List packet) {
    for (final match in spec.match) {
      final expected = HexCodec.decode(match.hex);
      final mask = match.mask == null ? null : HexCodec.decode(match.mask!);
      final offset = _normalizeOffset(match.offset, packet.length);
      if (offset < 0 || offset + expected.length > packet.length) {
        return false;
      }
      for (var i = 0; i < expected.length; i++) {
        final actualByte = packet[offset + i];
        final expectedByte = expected[i];
        if (mask == null) {
          if (actualByte != expectedByte) return false;
        } else {
          final bitMask = mask[i];
          if ((actualByte & bitMask) != (expectedByte & bitMask)) return false;
        }
      }
    }
    return true;
  }

  static Object? decode(PacketDecodeSpec spec, Uint8List packet) {
    _verifyPacket(spec, packet);

    if (spec.value != null) {
      return _decodeValue(spec.value!, packet);
    }
    if (spec.values.isNotEmpty) {
      return _decodeNamedValues(spec.values, packet);
    }
    return null;
  }

  static Map<String, Object?> decodeValues(PacketDecodeSpec spec,
      Uint8List packet,) {
    _verifyPacket(spec, packet);
    if (spec.values.isEmpty) {
      throw StateError('Response definition does not contain values');
    }
    return _decodeNamedValues(spec.values, packet);
  }

  static void _verifyPacket(PacketDecodeSpec spec, Uint8List packet) {
    if (!matches(spec, packet)) {
      throw FormatException('Packet does not match response definition');
    }
    if (spec.checksum != null) {
      _verifyChecksum(spec.checksum!, packet);
    }
  }

  static Object? _decodeValue(PacketValueSpec value, Uint8List packet) {
    final start = _normalizeOffset(value.offset, packet.length);
    if (start < 0 || start > packet.length) {
      throw RangeError('Invalid response value offset: ${value.offset}');
    }

    final length =
        value.length ?? value.codec.fixedByteLength ?? (packet.length - start);
    final end = start + length;
    if (end > packet.length) {
      throw RangeError('Response value exceeds packet length');
    }

    return WireCodec.decode(
      Uint8List.sublistView(packet, start, end),
      value.codec,
    );
  }

  static Map<String, Object?> _decodeNamedValues(List<PacketNamedValueSpec> values,
      Uint8List packet,) {
    final result = <String, Object?>{};
    for (final value in values) {
      final start = _normalizeOffset(value.offset, packet.length);
      if (start < 0 || start > packet.length) {
        throw RangeError(
          'Invalid response value offset for ${value.property}: ${value.offset}',
        );
      }
      final length =
          value.length ??
              value.codec.fixedByteLength ??
              (packet.length - start);
      final end = start + length;
      if (end > packet.length) {
        throw RangeError(
          'Response value ${value.property} exceeds packet length',
        );
      }
      result[value.property] = WireCodec.decode(
        Uint8List.sublistView(packet, start, end),
        value.codec,
      );
    }
    return result;
  }

  static void _verifyChecksum(ResponseChecksumSpec spec, Uint8List packet) {
    final checksumOffset = _normalizeOffset(spec.offset, packet.length);
    if (checksumOffset < 0 || checksumOffset + spec.length > packet.length) {
      throw RangeError('Invalid checksum offset/length');
    }

    final end = switch (spec.end) {
      null => checksumOffset,
      ResponseChecksumEnd.beforeChecksum => checksumOffset,
      int value => _normalizeExclusiveOffset(value, packet.length),
      _ =>
      throw FormatException(
        'Unsupported response checksum end: ${spec.end}',
      ),
    };

    final start = _normalizeOffset(spec.start, packet.length);
    if (start < 0 || end < start || end > packet.length) {
      throw RangeError('Invalid response checksum data range');
    }

    final actual = Uint8List.sublistView(
      packet,
      checksumOffset,
      checksumOffset + spec.length,
    );
    final expected = ChecksumCodec.calculate(
      spec.alg,
      Uint8List.sublistView(packet, start, end),
      endian: spec.endian,
      options: spec.options,
    );

    if (!_bytesEqual(actual, expected)) {
      throw FormatException(
        'Checksum mismatch: actual=${HexCodec.encode(actual)}, '
            'expected=${HexCodec.encode(expected)}',
      );
    }
  }
}

int _normalizeOffset(int offset, int length) {
  return offset >= 0 ? offset : length + offset;
}

int _normalizeExclusiveOffset(int offset, int length) {
  return offset >= 0 ? offset : length + offset;
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// -----------------------------------------------------------------------------
// Wire encode/decode implementation
// -----------------------------------------------------------------------------
class WireCodec {
  const WireCodec._();

  static Uint8List encode(Object? logicalValue, WireCodecSpec spec) {
    switch (spec.format) {
      case ValueFormat.bool8:
        if (logicalValue is! bool) {
          throw ArgumentError('bool8 requires bool, got $logicalValue');
        }
        return Uint8List.fromList([
          logicalValue ? spec.trueValue : spec.falseValue,
        ]);

      case ValueFormat.uint8:
        return _encodeInteger(
          _toRawInt(logicalValue, spec),
          1,
          false,
          spec.endian,
        );
      case ValueFormat.int8:
        return _encodeInteger(
          _toRawInt(logicalValue, spec),
          1,
          true,
          spec.endian,
        );
      case ValueFormat.uint16:
        return _encodeInteger(
          _toRawInt(logicalValue, spec),
          2,
          false,
          spec.endian,
        );
      case ValueFormat.int16:
        return _encodeInteger(
          _toRawInt(logicalValue, spec),
          2,
          true,
          spec.endian,
        );
      case ValueFormat.uint32:
        return _encodeInteger(
          _toRawInt(logicalValue, spec),
          4,
          false,
          spec.endian,
        );
      case ValueFormat.int32:
        return _encodeInteger(
          _toRawInt(logicalValue, spec),
          4,
          true,
          spec.endian,
        );
      case ValueFormat.uint64:
        return _encodeInteger(
          _toRawInt(logicalValue, spec),
          8,
          false,
          spec.endian,
        );
      case ValueFormat.int64:
        return _encodeInteger(
          _toRawInt(logicalValue, spec),
          8,
          true,
          spec.endian,
        );

      case ValueFormat.float32:
        return _encodeFloat(_toRawDouble(logicalValue, spec), 4, spec.endian);
      case ValueFormat.float64:
        return _encodeFloat(_toRawDouble(logicalValue, spec), 8, spec.endian);

      case ValueFormat.utf8:
        if (logicalValue is! String) {
          throw ArgumentError('utf8 requires String');
        }
        return _encodeText(utf8.encode(logicalValue), spec);

      case ValueFormat.ascii:
        if (logicalValue is! String) {
          throw ArgumentError('ascii requires String');
        }
        return _encodeText(ascii.encode(logicalValue), spec);

      case ValueFormat.bytes:
        return _encodeBytesValue(logicalValue, spec);

      case ValueFormat.array:
        if (logicalValue is! List) {
          throw ArgumentError('array codec requires List');
        }
        if (spec.item == null) {
          throw StateError('array codec requires item');
        }
        final builder = BytesBuilder(copy: false);
        if (spec.lengthPrefix != null) {
          builder.add(
            _encodeLengthPrefix(logicalValue.length, spec.lengthPrefix!),
          );
        }
        for (final item in logicalValue) {
          builder.add(encode(item, spec.item!));
        }
        return builder.takeBytes();

      case ValueFormat.object:
        if (logicalValue is! Map) {
          throw ArgumentError('object codec requires Map');
        }
        final builder = BytesBuilder(copy: false);
        for (final field in spec.fields) {
          if (!logicalValue.containsKey(field.name)) {
            throw StateError('object field missing: ${field.name}');
          }
          builder.add(encode(logicalValue[field.name], field.codec));
        }
        final bytes = builder.takeBytes();
        return _applyFixedLength(bytes, spec.fixedLength);
    }
  }

  static Object? decode(Uint8List bytes, WireCodecSpec spec) {
    switch (spec.format) {
      case ValueFormat.bool8:
        if (bytes.isEmpty) throw FormatException('bool8 requires 1 byte');
        final value = bytes[0];
        if (value == spec.trueValue) return true;
        if (value == spec.falseValue) return false;
        throw FormatException('Invalid bool8 value: $value');

      case ValueFormat.uint8:
        return _fromRawNumber(
          _decodeInteger(bytes, 1, false, spec.endian),
          spec,
        );
      case ValueFormat.int8:
        return _fromRawNumber(
          _decodeInteger(bytes, 1, true, spec.endian),
          spec,
        );
      case ValueFormat.uint16:
        return _fromRawNumber(
          _decodeInteger(bytes, 2, false, spec.endian),
          spec,
        );
      case ValueFormat.int16:
        return _fromRawNumber(
          _decodeInteger(bytes, 2, true, spec.endian),
          spec,
        );
      case ValueFormat.uint32:
        return _fromRawNumber(
          _decodeInteger(bytes, 4, false, spec.endian),
          spec,
        );
      case ValueFormat.int32:
        return _fromRawNumber(
          _decodeInteger(bytes, 4, true, spec.endian),
          spec,
        );
      case ValueFormat.uint64:
        return _fromRawNumber(
          _decodeInteger(bytes, 8, false, spec.endian),
          spec,
        );
      case ValueFormat.int64:
        return _fromRawNumber(
          _decodeInteger(bytes, 8, true, spec.endian),
          spec,
        );

      case ValueFormat.float32:
        return _fromRawNumber(_decodeFloat(bytes, 4, spec.endian), spec);
      case ValueFormat.float64:
        return _fromRawNumber(_decodeFloat(bytes, 8, spec.endian), spec);

      case ValueFormat.utf8:
        final payload = _stripLengthPrefix(bytes, spec);
        return utf8.decode(payload);

      case ValueFormat.ascii:
        final payload = _stripLengthPrefix(bytes, spec);
        return ascii.decode(payload);

      case ValueFormat.bytes:
        return Uint8List.fromList(_stripLengthPrefix(bytes, spec));

      case ValueFormat.array:
        if (spec.item == null) {
          throw StateError('array codec requires item');
        }
        final prefix = _readLengthPrefix(bytes, spec.lengthPrefix);
        final itemSize = spec.item!.fixedByteLength;
        if (itemSize == null) {
          throw UnsupportedError(
            'array decode currently requires fixed-size item codec',
          );
        }
        final count =
            prefix.count ?? ((bytes.length - prefix.bytesUsed) ~/ itemSize);
        final result = <Object?>[];
        var offset = prefix.bytesUsed;
        for (var i = 0; i < count; i++) {
          final end = offset + itemSize;
          if (end > bytes.length) {
            throw FormatException('array packet truncated');
          }
          result.add(
            decode(Uint8List.sublistView(bytes, offset, end), spec.item!),
          );
          offset = end;
        }
        return result;

      case ValueFormat.object:
        final result = <String, Object?>{};
        var offset = 0;
        for (final field in spec.fields) {
          final size = field.codec.fixedByteLength;
          if (size == null) {
            throw UnsupportedError(
              'object decode requires fixed-size child codecs',
            );
          }
          final end = offset + size;
          if (end > bytes.length) {
            throw FormatException('object packet truncated');
          }
          result[field.name] = decode(
            Uint8List.sublistView(bytes, offset, end),
            field.codec,
          );
          offset = end;
        }
        return result;
    }
  }

  static int _toRawInt(Object? value, WireCodecSpec spec) {
    if (value is! num) {
      throw ArgumentError('${spec.format} requires num, got $value');
    }
    final raw = (value.toDouble() - spec.offset) / spec.scale;
    final rounded = raw.round();
    if ((raw - rounded).abs() > 0.000001) {
      throw ArgumentError(
        'Logical value $value cannot be represented exactly by ${spec.format} '
            'with scale=${spec.scale}, offset=${spec.offset}',
      );
    }
    return rounded;
  }

  static double _toRawDouble(Object? value, WireCodecSpec spec) {
    if (value is! num) {
      throw ArgumentError('${spec.format} requires num, got $value');
    }
    return (value.toDouble() - spec.offset) / spec.scale;
  }

  static Object _fromRawNumber(num raw, WireCodecSpec spec) {
    final value = raw.toDouble() * spec.scale + spec.offset;
    if (value.isFinite && (value - value.roundToDouble()).abs() < 0.000000001) {
      return value.toInt();
    }
    return value;
  }

  static Uint8List _encodeInteger(int value,
      int bytes,
      bool signed,
      DataEndian endian,) {
    final data = ByteData(bytes);
    final e = endian.isLittle ? Endian.little : Endian.big;
    switch ((bytes, signed)) {
      case (1, false):
        data.setUint8(0, value);
        break;
      case (1, true):
        data.setInt8(0, value);
        break;
      case (2, false):
        data.setUint16(0, value, e);
        break;
      case (2, true):
        data.setInt16(0, value, e);
        break;
      case (4, false):
        data.setUint32(0, value, e);
        break;
      case (4, true):
        data.setInt32(0, value, e);
        break;
      case (8, false):
        data.setUint64(0, value, e);
        break;
      case (8, true):
        data.setInt64(0, value, e);
        break;
      default:
        throw UnsupportedError('Unsupported integer width: $bytes');
    }
    return data.buffer.asUint8List();
  }

  static int _decodeInteger(Uint8List bytes,
      int width,
      bool signed,
      DataEndian endian,) {
    if (bytes.length < width) {
      throw FormatException('Need $width bytes, got ${bytes.length}');
    }
    final data = ByteData.sublistView(bytes, 0, width);
    final e = endian.isLittle ? Endian.little : Endian.big;
    return switch ((width, signed)) {
      (1, false) => data.getUint8(0),
      (1, true) => data.getInt8(0),
      (2, false) => data.getUint16(0, e),
      (2, true) => data.getInt16(0, e),
      (4, false) => data.getUint32(0, e),
      (4, true) => data.getInt32(0, e),
      (8, false) => data.getUint64(0, e),
      (8, true) => data.getInt64(0, e),
      _ => throw UnsupportedError('Unsupported integer width: $width'),
    };
  }

  static Uint8List _encodeFloat(double value, int bytes, DataEndian endian) {
    final data = ByteData(bytes);
    final e = endian.isLittle ? Endian.little : Endian.big;
    if (bytes == 4) {
      data.setFloat32(0, value, e);
    } else if (bytes == 8) {
      data.setFloat64(0, value, e);
    } else {
      throw UnsupportedError('Unsupported float width: $bytes');
    }
    return data.buffer.asUint8List();
  }

  static double _decodeFloat(Uint8List bytes, int width, DataEndian endian) {
    if (bytes.length < width) {
      throw FormatException('Need $width bytes, got ${bytes.length}');
    }
    final data = ByteData.sublistView(bytes, 0, width);
    final e = endian.isLittle ? Endian.little : Endian.big;
    return width == 4 ? data.getFloat32(0, e) : data.getFloat64(0, e);
  }

  static Uint8List _encodeText(List<int> textBytes, WireCodecSpec spec) {
    final payload = _applyFixedLength(
      Uint8List.fromList(textBytes),
      spec.fixedLength,
    );
    if (spec.lengthPrefix == null) return payload;
    final builder = BytesBuilder(copy: false)
      ..add(_encodeLengthPrefix(textBytes.length, spec.lengthPrefix!))..add(payload);
    return builder.takeBytes();
  }

  static Uint8List _encodeBytesValue(Object? value, WireCodecSpec spec) {
    late Uint8List bytes;
    if (value is Uint8List) {
      bytes = value;
    } else if (value is List<int>) {
      bytes = Uint8List.fromList(value);
    } else if (value is String) {
      bytes = Uint8List.fromList(HexCodec.decode(value));
    } else {
      throw ArgumentError(
        'bytes codec requires Uint8List/List<int>/hex String',
      );
    }
    bytes = _applyFixedLength(bytes, spec.fixedLength);
    if (spec.lengthPrefix == null) return bytes;
    final builder = BytesBuilder(copy: false)
      ..add(_encodeLengthPrefix(bytes.length, spec.lengthPrefix!))..add(bytes);
    return builder.takeBytes();
  }

  static Uint8List _applyFixedLength(Uint8List bytes, int? fixedLength) {
    if (fixedLength == null) return bytes;
    if (bytes.length > fixedLength) {
      throw ArgumentError(
        'Encoded data length ${bytes.length} exceeds fixedLength=$fixedLength',
      );
    }
    if (bytes.length == fixedLength) return bytes;
    final result = Uint8List(fixedLength);
    result.setRange(0, bytes.length, bytes);
    return result;
  }

  static List<int> _stripLengthPrefix(Uint8List bytes, WireCodecSpec spec) {
    if (spec.lengthPrefix == null) {
      if (spec.fixedLength == null) return bytes;
      var end = math.min(spec.fixedLength!, bytes.length);
      while (end > 0 && bytes[end - 1] == 0) {
        end--;
      }
      return bytes.sublist(0, end);
    }
    final prefix = _readLengthPrefix(bytes, spec.lengthPrefix);
    final count = prefix.count!;
    final start = prefix.bytesUsed;
    final end = start + count;
    if (end > bytes.length) {
      throw FormatException('Length-prefixed data truncated');
    }
    return bytes.sublist(start, end);
  }

  static Uint8List _encodeLengthPrefix(int value, LengthPrefix format) {
    return _encodeInteger(value, format.byteLength, false, DataEndian.big);
  }

  static _PrefixRead _readLengthPrefix(Uint8List bytes, LengthPrefix? format) {
    if (format == null) return const _PrefixRead(null, 0);
    if (bytes.length < format.byteLength) {
      throw FormatException('Length prefix truncated: ${format.name}');
    }
    return _PrefixRead(
      _decodeInteger(bytes, format.byteLength, false, DataEndian.big),
      format.byteLength,
    );
  }
}

class _PrefixRead {
  final int? count;
  final int bytesUsed;

  const _PrefixRead(this.count, this.bytesUsed);
}

// -----------------------------------------------------------------------------
// Checksum
// -----------------------------------------------------------------------------
class ChecksumCodec {
  const ChecksumCodec._();

  static Uint8List calculate(CheckSumAlg algorithm,
      Uint8List data, {
        DataEndian endian = DataEndian.big,
        Map<String, dynamic> options = const {},
      }) {
    switch (algorithm) {
      case CheckSumAlg.sum8:
        var sum = 0;
        for (final value in data) {
          sum = (sum + value) & 0xFF;
        }
        return Uint8List.fromList([sum]);

      case CheckSumAlg.xor8:
        var value = 0;
        for (final byte in data) {
          value ^= byte;
        }
        return Uint8List.fromList([value & 0xFF]);

      case CheckSumAlg.crc8:
        return _encodeChecksumInt(
          _crcGeneric(
            data,
            width: 8,
            polynomial: (options['polynomial'] as int?) ?? 0x07,
            init: (options['init'] as int?) ?? 0x00,
            xorOut: (options['xorOut'] as int?) ?? 0x00,
            reflectIn: options['reflectIn'] as bool? ?? false,
            reflectOut: options['reflectOut'] as bool? ?? false,
          ),
          1,
          endian,
        );

      case CheckSumAlg.crc16:
        return _encodeChecksumInt(
          _crcGeneric(
            data,
            width: 16,
            polynomial: (options['polynomial'] as int?) ?? 0x1021,
            init: (options['init'] as int?) ?? 0xFFFF,
            xorOut: (options['xorOut'] as int?) ?? 0x0000,
            reflectIn: options['reflectIn'] as bool? ?? false,
            reflectOut: options['reflectOut'] as bool? ?? false,
          ),
          2,
          endian,
        );

      case CheckSumAlg.crc16Modbus:
        return _encodeChecksumInt(_crc16Modbus(data), 2, endian);

      case CheckSumAlg.crc16CcittFalse:
        return _encodeChecksumInt(_crc16CcittFalse(data), 2, endian);

      case CheckSumAlg.crc32:
        return _encodeChecksumInt(_crc32(data), 4, endian);
    }
  }

  static int _crcGeneric(Uint8List data, {
    required int width,
    required int polynomial,
    required int init,
    required int xorOut,
    required bool reflectIn,
    required bool reflectOut,
  }) {
    if (width <= 0 || width > 32) {
      throw ArgumentError('Generic CRC width must be 1..32');
    }
    final mask = width == 32 ? 0xFFFFFFFF : (1 << width) - 1;
    final topBit = 1 << (width - 1);
    var crc = init & mask;

    for (final originalByte in data) {
      final byte = reflectIn ? _reflectBits(originalByte, 8) : originalByte;
      crc ^= byte << (width - 8);
      for (var i = 0; i < 8; i++) {
        crc = (crc & topBit) != 0
            ? ((crc << 1) ^ polynomial) & mask
            : (crc << 1) & mask;
      }
    }

    if (reflectOut) {
      crc = _reflectBits(crc, width);
    }
    return (crc ^ xorOut) & mask;
  }

  static int _reflectBits(int value, int width) {
    var result = 0;
    for (var i = 0; i < width; i++) {
      if ((value & (1 << i)) != 0) {
        result |= 1 << (width - 1 - i);
      }
    }
    return result;
  }

  static int _crc16Modbus(Uint8List data) {
    var crc = 0xFFFF;
    for (final byte in data) {
      crc ^= byte;
      for (var i = 0; i < 8; i++) {
        if ((crc & 0x0001) != 0) {
          crc = (crc >> 1) ^ 0xA001;
        } else {
          crc >>= 1;
        }
      }
    }
    return crc & 0xFFFF;
  }

  static int _crc16CcittFalse(Uint8List data) {
    var crc = 0xFFFF;
    for (final byte in data) {
      crc ^= byte << 8;
      for (var i = 0; i < 8; i++) {
        if ((crc & 0x8000) != 0) {
          crc = ((crc << 1) ^ 0x1021) & 0xFFFF;
        } else {
          crc = (crc << 1) & 0xFFFF;
        }
      }
    }
    return crc & 0xFFFF;
  }

  static int _crc32(Uint8List data) {
    var crc = 0xFFFFFFFF;
    for (final byte in data) {
      crc ^= byte;
      for (var i = 0; i < 8; i++) {
        crc = (crc & 1) != 0 ? ((crc >> 1) ^ 0xEDB88320) : (crc >> 1);
      }
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  static Uint8List _encodeChecksumInt(int value,
      int length,
      DataEndian endian,) {
    final result = Uint8List(length);
    if (endian.isLittle) {
      for (var i = 0; i < length; i++) {
        result[i] = (value >> (8 * i)) & 0xFF;
      }
    } else {
      for (var i = 0; i < length; i++) {
        result[length - 1 - i] = (value >> (8 * i)) & 0xFF;
      }
    }
    return result;
  }
}

class HexCodec {
  const HexCodec._();

  static List<int> decode(String value) {
    final normalized = value
        .replaceAll(' ', '')
        .replaceAll(':', '')
        .replaceAll('-', '')
        .replaceAll('0x', '')
        .replaceAll('0X', '');

    if (normalized.length.isOdd) {
      throw FormatException('Hex string length must be even: $value');
    }

    final result = <int>[];
    for (var i = 0; i < normalized.length; i += 2) {
      result.add(int.parse(normalized.substring(i, i + 2), radix: 16));
    }
    return result;
  }

  static String encode(List<int> bytes) {
    final buffer = StringBuffer();
    for (final value in bytes) {
      buffer.write(value.toRadixString(16).padLeft(2, '0').toUpperCase());
    }
    return buffer.toString();
  }
}

class ValueValidator {
  const ValueValidator._();

  static void validate(Object? value, ValueSpec spec, {String path = 'value'}) {
    if (value == null) {
      if (spec.nullable) return;
      throw ArgumentError('$path cannot be null');
    }

    switch (spec.type) {
      case ValueType.boolean:
        if (value is! bool) {
          throw ArgumentError('$path must be bool, got ${value.runtimeType}');
        }
        break;

      case ValueType.integer:
        if (value is! int) {
          throw ArgumentError('$path must be int, got ${value.runtimeType}');
        }
        _validateNumber(value, spec.constraints, path);
        break;

      case ValueType.decimal:
        if (value is! num) {
          throw ArgumentError('$path must be num, got ${value.runtimeType}');
        }
        _validateNumber(value, spec.constraints, path);
        break;

      case ValueType.string:
        if (value is! String) {
          throw ArgumentError('$path must be String, got ${value.runtimeType}');
        }
        _validateString(value, spec.constraints, path);
        break;

      case ValueType.enumeration:
        if (!spec.values.any((item) => item.value == value)) {
          throw ArgumentError('$path has unsupported enum value: $value');
        }
        break;

      case ValueType.array:
        if (value is! List) {
          throw ArgumentError('$path must be List, got ${value.runtimeType}');
        }
        final constraints = spec.constraints;
        if (constraints?.minItems != null &&
            value.length < constraints!.minItems!) {
          throw RangeError(
            '$path requires at least ${constraints.minItems} items',
          );
        }
        if (constraints?.maxItems != null &&
            value.length > constraints!.maxItems!) {
          throw RangeError(
            '$path allows at most ${constraints.maxItems} items',
          );
        }
        for (var i = 0; i < value.length; i++) {
          validate(value[i], spec.items!, path: '$path[$i]');
        }
        break;

      case ValueType.object:
        if (value is! Map) {
          throw ArgumentError('$path must be Map, got ${value.runtimeType}');
        }
        for (final entry in spec.properties.entries) {
          if (!value.containsKey(entry.key)) {
            throw ArgumentError('$path missing field: ${entry.key}');
          }
          validate(value[entry.key], entry.value, path: '$path.${entry.key}');
        }
        break;
    }
  }

  static void _validateNumber(num value,
      ValueConstraints? constraints,
      String path,) {
    if (constraints == null) return;
    if (constraints.min != null && value < constraints.min!) {
      throw RangeError('$path=$value < min=${constraints.min}');
    }
    if (constraints.max != null && value > constraints.max!) {
      throw RangeError('$path=$value > max=${constraints.max}');
    }
    final step = constraints.step;
    if (step != null && step > 0) {
      final base = constraints.min?.toDouble() ?? 0.0;
      final q = (value.toDouble() - base) / step.toDouble();
      if ((q - q.roundToDouble()).abs() > 0.0000001) {
        throw ArgumentError('$path=$value does not satisfy step=$step');
      }
    }
  }

  static void _validateString(String value,
      ValueConstraints? constraints,
      String path,) {
    if (constraints == null) return;
    if (constraints.minLength != null &&
        value.length < constraints.minLength!) {
      throw RangeError('$path is shorter than ${constraints.minLength}');
    }
    if (constraints.maxLength != null &&
        value.length > constraints.maxLength!) {
      throw RangeError('$path is longer than ${constraints.maxLength}');
    }
    if (constraints.pattern != null &&
        !RegExp(constraints.pattern!).hasMatch(value)) {
      throw ArgumentError(
        '$path does not match pattern ${constraints.pattern}',
      );
    }
  }
}

// -----------------------------------------------------------------------------
// Facade：业务层直接通过它操作属性，不需要理解帧结构
// -----------------------------------------------------------------------------
class DecodedNotification {
  /// 用哪个 property.notify 规则命中的
  final String sourceProperty;

  /// 本帧带来的状态增量
  /// 一帧可以更新多个 property
  final Map<String, Object?> values;

  const DecodedNotification({
    required this.sourceProperty,
    required this.values,
  });
}

class DeviceModelRuntime {
  final DeviceModel model;

  const DeviceModelRuntime(this.model);

  Uint8List encodeWrite(String propertyId,
      Object? value, {
        Map<String, Object?> propertyState = const {},
        Map<String, Object?> variables = const {},
        int sequence = 0,
        DateTime? timestamp,
      }) {
    final property = model.property(propertyId);
    final operation = property.write;
    if (operation == null) {
      throw StateError('Property $propertyId is not writable');
    }
    final request = operation.request;
    if (request == null) {
      throw StateError(
        'Property $propertyId write operation has no request frame',
      );
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

  Uint8List? encodeReadRequest(String propertyId, {
    Map<String, Object?> propertyState = const {},
    Map<String, Object?> variables = const {},
    int sequence = 0,
    DateTime? timestamp,
  }) {
    final property = model.property(propertyId);
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
    final property = model.property(propertyId);
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
    final property = model.property(propertyId);
    final response = property.notify?.response;
    if (response == null) {
      throw StateError(
        'Property $propertyId has no notify response definition',
      );
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
    final property = model.property(propertyId);
    final response = property.notify?.response;
    if (response == null) {
      throw StateError(
        'Property $propertyId has no notify response definition',
      );
    }

    final result = PacketDecoder.decode(response, packet);
    final patch = _asPatch(propertyId, response, result);
    _validatePatch(patch);
    return patch;
  }

  /// 根据 service + characteristic + response.match 自动寻找通知解析规则。
  /// 同一个 characteristic 可以承载多种 packet，因此返回 List。
  List<DecodedNotification> decodeNotifications(String service,
      String characteristic,
      Uint8List packet,) {
    final result = <DecodedNotification>[];

    for (final entry in model.properties.entries) {
      final operation = entry.value.notify;
      final response = operation?.response;
      if (operation == null || response == null) continue;

      final responseService = response.service ?? operation.service;
      final responseCharacteristic =
          response.characteristic ?? operation.characteristic;

      if (!_uuidEquals(service, responseService) ||
          !_uuidEquals(characteristic, responseCharacteristic)) {
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
  Map<String, Object?> _asPatch(String propertyId,
      PacketDecodeSpec response,
      Object? decoded,) {
    if (!response.isMultiValue) {
      return {propertyId: decoded};
    }
    if (decoded is! Map<String, Object?>) {
      throw FormatException(
        'Property $propertyId response.values did not decode to a map',
      );
    }
    return decoded;
  }

  void _validatePatch(Map<String, Object?> patch) {
    for (final entry in patch.entries) {
      final property = model.properties[entry.key];
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
