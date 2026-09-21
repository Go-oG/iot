import '../spec/value_spec.dart';
import '../types.dart';

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

      case ValueType.double:
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
        if (constraints?.minItems != null && value.length < constraints!.minItems!) {
          throw RangeError('$path requires at least ${constraints.minItems} items');
        }
        if (constraints?.maxItems != null && value.length > constraints!.maxItems!) {
          throw RangeError('$path allows at most ${constraints.maxItems} items');
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

  static void _validateNumber(num value, ValueConstraints? constraints, String path) {
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

  static void _validateString(String value, ValueConstraints? constraints, String path) {
    if (constraints == null) return;
    if (constraints.minLength != null && value.length < constraints.minLength!) {
      throw RangeError('$path is shorter than ${constraints.minLength}');
    }
    if (constraints.maxLength != null && value.length > constraints.maxLength!) {
      throw RangeError('$path is longer than ${constraints.maxLength}');
    }
    if (constraints.pattern != null && !RegExp(constraints.pattern!).hasMatch(value)) {
      throw ArgumentError('$path does not match pattern ${constraints.pattern}');
    }
  }
}
