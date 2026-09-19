import 'dart:io';

import 'package:dio/dio.dart';

import 'client.dart';
import 'device_spec.dart';
import 'errors.dart';

class MijiaDeviceProperty {
  MijiaDeviceProperty.fromSpec(Map<String, dynamic> spec)
      : name = '${spec['name']}',
        description = '${spec['description'] ?? ''}',
        type = '${spec['type']}',
        rw = '${spec['rw']}',
        range = spec['range'] as List<dynamic>?,
        valueList = spec['value-list'] as List<dynamic>?,
        method = Map<String, dynamic>.from(spec['method'] as Map) {
    if (!supportedPropertyTypes.contains(type)) {
      throw ArgumentError.value(
        type,
        'type',
        '不支持的类型: $type, 可选类型: '
            '${supportedPropertyTypes.join(', ')}',
      );
    }
  }

  /// Property name from the spec, e.g. `brightness`.
  final String name;

  /// Human readable description.
  final String description;

  /// One of `bool`, `int`, `uint`, `float`, `string`.
  final String type;

  /// Access flags: `r`, `w` or `rw`.
  final String rw;

  /// Allowed `[min, max, step]`, when the spec declares one.
  final List<dynamic>? range;

  /// Enumerated values, when the spec declares them.
  final List<dynamic>? valueList;

  /// `{siid, piid}` used to address the property.
  final Map<String, dynamic> method;

  bool get readable => rw.contains('r');
  bool get writable => rw.contains('w');

  @override
  String toString() {
    final lines = <String>[
      '  $name: $description',
      '    valuetype: $type, rw: $rw, range: $range',
    ];
    for (final item in valueList ?? const <dynamic>[]) {
      final map = Map<String, dynamic>.from(item as Map);
      lines.add('    ${map['value']}: ${map['description']}');
    }
    return lines.join('\n');
  }
}

/// One callable device action.
class MijiaDeviceAction {
  MijiaDeviceAction.fromSpec(Map<String, dynamic> spec)
      : name = '${spec['name']}',
        description = '${spec['description'] ?? ''}',
        method = Map<String, dynamic>.from(spec['method'] as Map);

  /// Action name from the spec, e.g. `toggle`.
  final String name;

  /// Human readable description.
  final String description;

  /// `{siid, aiid}` used to invoke the action.
  final Map<String, dynamic> method;

  @override
  String toString() => '  $name: $description';
}

/// A device addressed by `did` or by name.
///
/// Construct with [MijiaDevice.create], which resolves the device and loads its
/// spec:
///
/// ```dart
/// final device = await MijiaDevice.create(api: api, devName: '台灯');
/// await device.set('brightness', 50);
/// print(await device.get('brightness'));
/// ```
///
/// [operator []] and [operator []=] are shorthands for [get] and [set], so
/// `device['brightness']` reads the same value.
class MijiaDevice {
  MijiaDevice._({
    required this.api,
    required this.did,
    required this.model,
    required this.name,
    required this.sleepTime,
    required this.properties,
    required this.actions,
  });

  /// Resolves [did] or [devName] and loads the device spec.
  ///
  /// Exactly one of [did] and [devName] must be given; when both are, [devName]
  /// is ignored, mirroring the Python client. [cacheDir] enables the on-disk
  /// spec cache and defaults to the directory holding `auth.json`.
  ///
  /// Throws [DeviceNotFoundException] when nothing matches,
  /// [MultipleDevicesFoundException] when several devices do,
  /// [GetDeviceInfoException] when the spec cannot be fetched, and
  /// [ArgumentError] when neither identifier is supplied.
  static Future<MijiaDevice> create({
    required MijiaApi api,
    String? did,
    String? devName,
    Duration sleepTime = const Duration(milliseconds: 500),
    Directory? cacheDir,
    Dio? specDio,
    String specBaseUrl = deviceSpecBaseUrl,
  }) async {
    if (did == null && devName == null) {
      throw ArgumentError('必须提供 did 或 dev_name 参数之一');
    }

    final devices = await api.getDevicesList();
    String? resolvedDid = did;
    String? resolvedModel;
    String? resolvedName = devName;

    if (did == null) {
      final matches = devices
          .map((d) => Map<String, dynamic>.from(d as Map))
          .where((d) => d['name'] == devName)
          .toList();
      if (matches.isEmpty) {
        throw DeviceNotFoundException('$devName');
      }
      if (matches.length > 1) {
        throw MultipleDevicesFoundException(
          "找到多个 dev_name 为 '$devName' 的设备，"
          '请使用 did 参数指定具体设备或者修改设备名称以区分',
        );
      }
      resolvedDid = '${matches.first['did']}';
      resolvedModel = '${matches.first['model']}';
    } else {
      final matches = devices
          .map((d) => Map<String, dynamic>.from(d as Map))
          .where((d) => d['did'] == did)
          .toList();
      if (matches.isEmpty) {
        throw DeviceNotFoundException(did);
      }
      if (matches.length > 1) {
        throw MultipleDevicesFoundException(
          "找到多个 did 为 '$did' 的设备，未预想的问题，"
          '欢迎提交 issue: https://github.com/Do1e/mijia-api/issues',
        );
      }
      resolvedName = matches.first['name'] as String?;
      resolvedModel = '${matches.first['model']}';
    }

    final info = await fetchDeviceInfo(
      resolvedModel,
      cacheDir: cacheDir,
      dio: specDio,
      baseUrl: specBaseUrl,
    );

    final properties = <String, MijiaDeviceProperty>{};
    for (final entry in (info['properties'] as List<dynamic>? ?? const [])) {
      final property = MijiaDeviceProperty.fromSpec(
        Map<String, dynamic>.from(entry as Map),
      );
      properties[property.name] = property;
      if (property.name.contains('-')) {
        properties[property.name.replaceAll('-', '_')] = property;
      }
    }

    final actions = <String, MijiaDeviceAction>{};
    for (final entry in (info['actions'] as List<dynamic>? ?? const [])) {
      final action = MijiaDeviceAction.fromSpec(
        Map<String, dynamic>.from(entry as Map),
      );
      actions[action.name] = action;
    }

    return MijiaDevice._(
      api: api,
      did: resolvedDid!,
      model: resolvedModel,
      name: resolvedName ?? '${info['name']}',
      sleepTime: sleepTime,
      properties: properties,
      actions: actions,
    );
  }

  final MijiaApi api;

  /// Device id.
  final String did;

  /// Spec model, e.g. `yeelink.light.lamp4`.
  final String model;

  /// Display name.
  final String name;

  /// Pause after each get/set/action, easing rate limits. Mirrors Python's
  /// `sleep_time`.
  final Duration sleepTime;

  /// Properties by name, including `-`→`_` aliases.
  final Map<String, MijiaDeviceProperty> properties;

  /// Actions by name.
  final Map<String, MijiaDeviceAction> actions;

  /// Reads property [name].
  ///
  /// Throws [ArgumentError] when the property is unknown or not readable, and
  /// [DeviceGetException] when the device reports a failure.
  Future<dynamic> get(String name) async {
    final property = _requireProperty(name);
    if (!property.readable) {
      throw ArgumentError('属性 $name 不可读取');
    }
    final result = await api.getDevicesProp(<String, dynamic>{
      ...property.method,
      'did': did,
    });
    final map = Map<String, dynamic>.from(result as Map);
    final code = _asInt(map['code']);
    if (code != 0) {
      throw DeviceGetException(this.name, name, code);
    }
    await Future<void>.delayed(sleepTime);
    return map['value'];
  }

  /// Writes [value] to property [name].
  ///
  /// [value] is coerced to the property's declared type and validated against
  /// its range and value list. Throws [ArgumentError] on any mismatch and
  /// [DeviceSetException] when the device reports a failure.
  ///
  /// A `code` of 1 means the gateway accepted the command without confirming
  /// it; that is reported through [MijiaApi.logger] rather than thrown, as in
  /// Python.
  Future<void> set(String name, dynamic value) async {
    final property = _requireProperty(name);
    if (!property.writable) {
      throw ArgumentError('属性 $name 不可写入');
    }

    final coerced = _coerce(property, name, value);
    final result = await api.setDevicesProp(<String, dynamic>{
      ...property.method,
      'did': did,
      'value': coerced,
    });
    final map = Map<String, dynamic>.from(result as Map);
    final code = _asInt(map['code']);
    if (code == 1) {
      api.logger?.call('网关已经接收指令，无法判断是否设置成功: '
          '${this.name} -> $name, 值: $coerced');
    } else if (code != 0) {
      throw DeviceSetException(this.name, name, code);
    }
    await Future<void>.delayed(sleepTime);
  }

  /// Shorthand for [get].
  Future<dynamic> operator [](String name) => get(name);

  /// Shorthand for [set]; `device['brightness'] = 50`.
  ///
  /// [set] is asynchronous and this operator cannot be, so failures are
  /// reported through [MijiaApi.logger] instead of thrown. Call [set] directly
  /// when the caller needs to handle them.
  void operator []=(String name, dynamic value) {
    set(name, value).catchError((Object error) {
      api.logger?.call('设置属性 $name 失败: $error');
    });
  }

  /// Invokes action [name].
  ///
  /// [value] is the positional argument list the action expects, if any.
  /// [params] adds or overrides request fields; a key that already exists in
  /// the spec method is rejected, matching the Python `**kwargs` guard.
  ///
  /// Throws [ArgumentError] for an unknown action or a conflicting key, and
  /// [DeviceActionException] when the device reports a failure.
  Future<void> runAction(
    String name, {
    List<dynamic>? value,
    Map<String, dynamic>? params,
  }) async {
    final action = actions[name];
    if (action == null) {
      throw ArgumentError(
        '不支持的动作: $name, 可用动作: ${actions.keys.toList()}',
      );
    }

    final method = <String, dynamic>{...action.method, 'did': did};
    if (value != null) method['value'] = value;
    params?.forEach((key, paramValue) {
      if (method.containsKey(key)) {
        throw ArgumentError(
          '无效的参数: $key. 请勿使用以下参数 (${method.keys.join(', ')})',
        );
      }
      method[key] = paramValue;
    });

    final result = await api.runAction(method);
    final map = Map<String, dynamic>.from(result as Map);
    final code = _asInt(map['code']);
    if (code == 1) {
      api.logger?.call('网关已经接收指令，无法判断是否执行成功: ${this.name} -> $name');
    } else if (code != 0) {
      throw DeviceActionException(this.name, name, code);
    }
    await Future<void>.delayed(sleepTime);
  }

  MijiaDeviceProperty _requireProperty(String name) {
    final property = properties[name];
    if (property == null) {
      throw ArgumentError(
        '不支持的属性: $name, 可用属性: ${properties.keys.toList()}',
      );
    }
    return property;
  }

  @override
  String toString() {
    final propLines = properties.entries
        .where((entry) => !entry.key.contains('_'))
        .map((entry) => '${entry.value}');
    final propText =
        propLines.isEmpty ? 'No properties available' : propLines.join('\n');
    final actionLines = actions.values.map((action) => '$action');
    final actionText =
        actionLines.isEmpty ? 'No actions available' : actionLines.join('\n');
    return '$name ($model)\n'
        'Properties:\n$propText\n'
        'Actions:\n$actionText';
  }

  // ---------------------------------------------------------------------------
  // Value coercion
  // ---------------------------------------------------------------------------

  static int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('$value') ?? 0;
  }

  /// Converges [value] on the shape the device expects, validating it against
  /// the spec, and mirrors the Python `set` coercion step for step.
  static dynamic _coerce(
    MijiaDeviceProperty property,
    String name,
    dynamic value,
  ) {
    dynamic coerced;

    switch (property.type) {
      case 'bool':
        if (value is bool) {
          coerced = value;
        } else if (value is String) {
          final lower = value.toLowerCase();
          if (lower == 'true') {
            coerced = true;
          } else if (lower == 'false') {
            coerced = false;
          } else if (value == '0' || value == '1') {
            coerced = value == '1';
          } else {
            throw ArgumentError('无效布尔值: $value');
          }
        } else if (value is int && (value == 0 || value == 1)) {
          coerced = value == 1;
        } else {
          throw ArgumentError('无效布尔值: $value');
        }

      case 'int':
      case 'uint':
        coerced = _toInt(value);
        final range = property.range;
        final asInt = coerced as int;
        if (range != null && range.isNotEmpty) {
          final min = _toDouble(range[0]);
          final max = _toDouble(range[1]);
          if (asInt < min || asInt > max) {
            throw ArgumentError('$asInt 超出数值范围, 应该在 $range 之间');
          }
          if (range.length >= 3) {
            final step = _toDouble(range[2]);
            if (step != 1 && (asInt - min) % step != 0) {
              throw ArgumentError(
                '无效的值: $asInt, 应该在范围 $range 内且步长为 ${range[2]}',
              );
            }
          }
        }

      case 'float':
        coerced = _toDouble(value);
        final range = property.range;
        final asDouble = coerced as double;
        if (range != null && range.isNotEmpty) {
          final min = _toDouble(range[0]);
          final max = _toDouble(range[1]);
          if (asDouble < min || asDouble > max) {
            throw ArgumentError('$asDouble 超出数值范围, 应该在 $range 之间');
          }
          if (range.length >= 3 && range[2] is int) {
            final step = range[2] as int;
            if ((asDouble - min).truncate() % step != 0) {
              throw ArgumentError(
                '无效的值: $asDouble, 应该在范围 $range 内且步长为 $step',
              );
            }
          }
        }

      case 'string':
        if (value is! String) {
          throw ArgumentError('无效字符串值: $value');
        }
        coerced = value;

      default:
        throw ArgumentError(
          '不支持的类型: ${property.type}, 可用类型: '
          '${supportedPropertyTypes.join(', ')}',
        );
    }

    final valueList = property.valueList;
    if (valueList != null && valueList.isNotEmpty) {
      final allowed = valueList
          .map((item) => Map<String, dynamic>.from(item as Map)['value'])
          .toList();
      if (!allowed.contains(coerced)) {
        throw ArgumentError('无效值: $coerced, 请使用 $valueList');
      }
    }
    return coerced;
  }

  /// Python's `int(value)`: numeric input truncates, strings parse.
  static int _toInt(dynamic value) {
    if (value is bool) return value ? 1 : 0;
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) {
      final parsed = int.tryParse(value.trim());
      if (parsed == null) {
        throw ArgumentError('无效的整数值: $value');
      }
      return parsed;
    }
    throw ArgumentError('无效的整数值: $value');
  }

  /// Python's `float(value)`.
  static double _toDouble(dynamic value) {
    if (value is bool) return value ? 1 : 0;
    if (value is num) return value.toDouble();
    if (value is String) {
      final parsed = double.tryParse(value.trim());
      if (parsed == null) {
        throw ArgumentError('无效的浮点值: $value');
      }
      return parsed;
    }
    throw ArgumentError('无效的浮点值: $value');
  }
}
