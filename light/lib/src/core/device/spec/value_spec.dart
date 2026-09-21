
import '../types.dart';
import '../util.dart';

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
    final type = ValueType.valueOf(stringOf(json['type'], 'type'));
    final objectProperties = <String, ValueSpec>{};
    final propertiesJson = nullableMap(json['properties']);
    if (propertiesJson != null) {
      for (final entry in propertiesJson.entries) {
        objectProperties[entry.key] = ValueSpec.fromJson(mapOf(entry.value));
      }
    }

    final result = ValueSpec(
      type: type,
      unit: nullableString(json['unit']),
      nullable: json['nullable'] as bool? ?? false,
      defaultValue: json['default'],
      hasDefault: json.containsKey('default'),
      constraints: json['constraints'] == null ? null : ValueConstraints.fromJson(mapOf(json['constraints'])),
      values: mapList(json['values'], EnumValueSpec.fromJson),
      items: json['items'] == null ? null : ValueSpec.fromJson(mapOf(json['items'])),
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
      throw FormatException('values is only allowed for enum value, got ${type.wireName}');
    }
    if (type == ValueType.array && items == null) {
      throw FormatException('array value must define items');
    }
    if (type != ValueType.array && items != null) {
      throw FormatException('items is only allowed for array value, got ${type.wireName}');
    }
    if (type == ValueType.object && properties.isEmpty) {
      throw FormatException('object value must define properties');
    }
    if (type != ValueType.object && properties.isNotEmpty) {
      throw FormatException('properties is only allowed for object value, got ${type.wireName}');
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

  Map<String, dynamic> toJson() => {
    'type': type.wireName,
    if (unit != null) 'unit': unit,
    if (nullable) 'nullable': true,
    if (hasDefault || defaultValue != null) 'default': defaultValue,
    if (constraints != null) 'constraints': constraints!.toJson(),
    if (values.isNotEmpty) 'values': [for (final item in values) item.toJson()],
    if (items != null) 'items': items!.toJson(),
    if (properties.isNotEmpty) 'properties': {for (final entry in properties.entries) entry.key: entry.value.toJson()},
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
      minLength: nullableInt(json['minLength']),
      maxLength: nullableInt(json['maxLength']),
      minItems: nullableInt(json['minItems']),
      maxItems: nullableInt(json['maxItems']),
      pattern: nullableString(json['pattern']),
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
    if ((minLength != null && minLength! < 0) || (maxLength != null && maxLength! < 0)) {
      throw FormatException('constraints length must not be negative');
    }
    if (minLength != null && maxLength != null && minLength! > maxLength!) {
      throw FormatException('constraints minLength=$minLength must not exceed maxLength=$maxLength');
    }
    if ((minItems != null && minItems! < 0) || (maxItems != null && maxItems! < 0)) {
      throw FormatException('constraints item count must not be negative');
    }
    if (minItems != null && maxItems != null && minItems! > maxItems!) {
      throw FormatException('constraints minItems=$minItems must not exceed maxItems=$maxItems');
    }
    if (pattern != null) {
      try {
        RegExp(pattern!);
      } on FormatException catch (e) {
        throw FormatException('invalid constraints pattern: ${e.message}');
      }
    }
  }

  Map<String, dynamic> toJson() => {
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

  const EnumValueSpec({required this.value, required this.label, this.description});

  factory EnumValueSpec.fromJson(Map<String, dynamic> json) {
    final value = json['value'];
    if (value == null) {
      throw FormatException('enum value must define a non-null value');
    }
    return EnumValueSpec(
      value: value,
      label: stringOf(json['label'], 'values[].label'),
      description: nullableString(json['description']),
    );
  }

  Map<String, dynamic> toJson() => {
    'value': value,
    'label': label,
    if (description != null) 'description': description,
  };
}
