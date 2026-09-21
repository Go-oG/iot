import '../code/packet_coder.dart';
import '../types.dart';

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
          throw FormatException('condition operator=${operator.wireName} requires values');
        }
        break;
      case ConditionOperator.exists:
      case ConditionOperator.notExists:
        break;
      case ConditionOperator.bitSet:
      case ConditionOperator.bitClear:
        if (mask == null || mask! <= 0) {
          throw FormatException('condition operator=${operator.wireName} requires mask > 0');
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
        throw StateError('Unreachable condition operator: ${operator.wireName}');
    }
  }

  static int _compareNumber(Object? a, Object? b) {
    if (a is! num || b is! num) {
      throw StateError('Numeric condition requires num values: $a, $b');
    }
    return a.toDouble().compareTo(b.toDouble());
  }
}
