import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:light/src/core/protocol/remote_protocol.dart';
import 'package:light/src/util/check.dart';

import '../../functions/base.dart';
import '../../functions/fan_speed.dart';
import '../../functions/light.dart';
import '../../functions/power.dart';
import '../../functions/temperature.dart';
import '../../functions/timer.dart';
import '../device.dart';
import '../function_type.dart';
import '../generic_codec.dart';

/// 参数和刷新结果均使用对应功能的 JSON 状态结构
typedef GenericDeviceExecutor =
    FutureOr<bool> Function(
      GenericDevice device,
      ConfigurableFunction functionType,
      Object value,
    );
typedef GenericDeviceRefresher =
    FutureOr<Object?> Function(
      GenericDevice device,
      ConfigurableFunction functionType,
    );
typedef GenericDeviceConnection = FutureOr<bool> Function(GenericDevice device);

/// 单个功能的编解码闭包，用于校验并写回设备上报的值
class _FunctionCodec {
  const _FunctionCodec(this.decode, this.encode, this.apply);

  final Object? Function(Object? value, String path) decode;
  final Object Function(Object value) encode;
  final void Function(Object value) apply;
}

/// 配置驱动的通用设备
///
/// 整机状态以功能类型为键，只有序列化配置时才转回协议字段名。
class GenericDevice extends Device<Map<ConfigurableFunction, Object>> {
  GenericDevice._({
    required this.id,
    required this.name,
    required this.macd,
    required this.codec,
    required this._services,
    required List<Object?> functions,
    this._execute,
    this._refresh,
    this._connect,
    this._disconnect,
  }) {
    status = const {};
    for (var index = 0; index < functions.length; index++) {
      final path = 'functions[$index]';
      final config = objectOf(functions[index], path);
      final type = readFunctionType(config['type'], '$path.type');
      if (_functions.containsKey(type)) {
        throw FormatException('$path.type 重复：${type.wire}');
      }
      switch (type) {
        case ConfigurableFunction.power:
          _add<bool>(
            type,
            config,
            path,
            boolOf,
            (value) => value,
            (execute, refresh) =>
                PowerFunction(executeCall: execute, refreshCall: refresh),
          );
        case ConfigurableFunction.light:
          _add<LightState>(
            type,
            config,
            path,
            _light,
            (value) => value.toJson(),
            (execute, refresh) =>
                LightFunction(executeCall: execute, refreshCall: refresh),
          );
        case ConfigurableFunction.temperature:
          _add<double>(
            type,
            config,
            path,
            (value, path) => numberOf(value, path, 20, 80),
            (value) => value,
            (execute, refresh) =>
                TemperatureFunction(executeCall: execute, refreshCall: refresh),
          );
        case ConfigurableFunction.fanSpeed:
          _add<FanSpeed>(
            type,
            config,
            path,
            _fanSpeed,
            (value) => value.wire,
            (execute, refresh) =>
                FanSpeedFunction(executeCall: execute, refreshCall: refresh),
          );
        case ConfigurableFunction.fanSpeedPercent:
          _add<int>(
            type,
            config,
            path,
            (value, path) => intOf(value, path, 0, 100),
            (value) => value,
            (execute, refresh) => FanSpeedFunction2(
              executeCall: execute,
              refreshCall: refresh,
            ),
          );
        case ConfigurableFunction.timer:
          _add<TimerConfig>(
            type,
            config,
            path,
            _timer,
            (value) => value.toJson(),
            (execute, refresh) =>
                TimerFunction(executeCall: execute, refreshCall: refresh),
          );
      }
    }
  }

  factory GenericDevice.fromJson(
    Map<String, Object?> json, {
    GenericDeviceExecutor? execute,
    GenericDeviceRefresher? refresh,
    GenericDeviceConnection? connect,
    GenericDeviceConnection? disconnect,
  }) {
    final id = stringOf(json['id'], 'id');
    final rawServices = listOf(json['bleServices'] ?? const [], 'bleServices');
    final services = List<BleServiceDesc>.unmodifiable(<BleServiceDesc>[
      for (var index = 0; index < rawServices.length; index++) serviceOf(rawServices[index], 'bleServices[$index]'),
    ]);
    return GenericDevice._(
      id: id,
      name: stringOf(json['name'], 'name'),
      macd: json.containsKey('macd') ? stringOf(json['macd'], 'macd') : id,
      codec: GenericCodec.fromJson(json, serviceFallbacks: [for (final service in services) service.uuid]),
      services: services,
      functions: listOf(json['functions'], 'functions'),
      execute: execute,
      refresh: refresh,
      connect: connect,
      disconnect: disconnect,
    );
  }

  factory GenericDevice.fromJsonString(
    String source, {
    GenericDeviceExecutor? execute,
    GenericDeviceRefresher? refresh,
    GenericDeviceConnection? connect,
    GenericDeviceConnection? disconnect,
  }) => GenericDevice.fromJson(
    objectOf(jsonDecode(source), 'device'),
    execute: execute,
    refresh: refresh,
    connect: connect,
    disconnect: disconnect,
  );

  @override
  final String id;
  @override
  final String name;
  @override
  final String macd;

  /// 设备配置中的字节层描述；没有声明命令时为空壳，只支持本地预览
  final GenericCodec codec;
  final List<BleServiceDesc> _services;
  final Map<ConfigurableFunction, DeviceFunction> _functions = {};
  final Map<ConfigurableFunction, _FunctionCodec> _codecs = {};
  final GenericDeviceExecutor? _execute;
  final GenericDeviceRefresher? _refresh;
  final GenericDeviceConnection? _connect;
  final GenericDeviceConnection? _disconnect;

  /// 是否具备远程读写能力
  bool get supportsRemoteControl => codec.supportsRemoteControl;

  /// 按功能类型取功能实例
  DeviceFunction? functionOf(ConfigurableFunction type) => _functions[type];

  /// 整机状态的协议 JSON，编码写命令时按它解析字段路径
  Map<String, Object?> statusJson() => {
    for (final entry in status.entries) entry.key.wire: entry.value,
  };

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'macd': macd,
    'bleServices': [
      for (final service in _services)
        {
          'uuid': service.uuid,
          'name': service.name,
          'characteristicList': [
            for (final characteristic in service.characteristicList)
              {'uuid': characteristic.uuid, 'name': characteristic.name},
          ],
        },
    ],
    // 字节层描述只在配置里声明过时写回，避免空配置被无谓撑大
    ...codec.toJson(),
    'functions': [
      for (final entry in _functions.entries)
        {
          'type': entry.key.wire,
          'status': status[entry.key],
          if (codec.writes[entry.key] != null) 'write': codec.writes[entry.key],
        },
    ],
  };

  @override
  Map<ConfigurableFunction, Object> onInit() => status;

  @override
  List<BleServiceDesc> bleServices() => _services;

  @override
  List<DeviceFunction> onSupportFunctions() => _functions.values.toList();

  @override
  Future<bool> onConnection() async {
    if (_execute == null) throw StateError('设备未配置执行回调');
    return await _connect?.call(this) ?? true;
  }

  @override
  Future<bool> onDisConnection() async => await _disconnect?.call(this) ?? true;

  void _add<T extends Object>(
    ConfigurableFunction type,
    Map<String, Object?> config,
    String path,
    T Function(Object? value, String path) decode,
    Object Function(T value) encode,
    ValueDeviceFunction<T> Function(
      FutureOr<bool> Function(Device device, T value) execute,
      FutureOr<bool> Function(Device device) refresh,
    )
    create,
  ) {
    late final ValueDeviceFunction<T> function;
    function = create(
      (_, value) async {
        if (!isConnection) throw StateError('请先连接设备');
        final payload = encode(value);
        decode(payload, '${type.wire}.status');
        final success = await _execute!(this, type, payload);
        if (success) _record(type, payload);
        return success;
      },
      (_) async {
        final refresh = _refresh;
        if (refresh == null) return false;
        if (!isConnection) throw StateError('请先连接设备');
        final value = await refresh(this, type);
        if (value == null) return false;
        final decoded = decode(value, '${type.wire}.status');
        _record(type, encode(decoded));
        function.status = decoded;
        return true;
      },
    );
    if (config.containsKey('status')) {
      function.status = decode(config['status'], '$path.status');
    }
    _functions[type] = function;
    _codecs[type] = _FunctionCodec(decode, (value) => encode(value as T), function.applyStatus);
    _record(type, encode(function.status));
  }

  /// 用设备上报的值更新功能状态
  ///
  /// 值按该功能声明的规则校验；非法值只丢弃这一项并返回 false，不污染已有状态。
  bool applyReported(ConfigurableFunction type, Object? value) {
    final codec = _codecs[type];
    if (codec == null) return false;
    try {
      final decoded = codec.decode(value, '${type.wire}.status');
      if (decoded == null) return false;
      codec.apply(decoded);
      _record(type, codec.encode(decoded));
      return true;
    } on FormatException {
      return false;
    } on TypeError {
      return false;
    }
  }

  /// 按设备上报的值批量更新，返回实际写入的功能类型
  List<ConfigurableFunction> applyReportedAll(
    Map<ConfigurableFunction, Object?> values,
  ) => [
    for (final entry in values.entries)
      if (applyReported(entry.key, entry.value)) entry.key,
  ];

  /// 记录初始值和执行或刷新成功后的值，独立于控件的拖动预览
  void _record(ConfigurableFunction type, Object value) =>
      status = Map.unmodifiable({...status, type: value});

  @override
  List<RemoteWriteStep> buildRemoteSteps(DeviceCommand command, Map<String, Object?> payload) {
    // TODO: implement buildRemoteSteps
    throw UnimplementedError();
  }

  @override
  RemoteDecodedFrame? decodeRemoteFrame(Uint8List bytes, {String? format}) {
    // TODO: implement decodeRemoteFrame
    throw UnimplementedError();
  }

  @override
  // TODO: implement remoteCharacteristic
  String get remoteCharacteristic => throw UnimplementedError();

  @override
  // TODO: implement remoteService
  String get remoteService => throw UnimplementedError();
}

FanSpeed _fanSpeed(Object? value, String path) {
  final speed = FanSpeed.valueOf(value);
  if (speed == null) {
    throw FormatException(
      '$path 必须是 ${FanSpeed.values.map((s) => s.wire).join(' 或 ')}',
    );
  }
  return speed;
}

LightState _light(Object? value, String path) {
  final json = objectOf(value, path);
  int channel(LightChannel key) =>
      intOf(json[key.wire], '$path.${key.wire}', 0, 100);
  return LightState(
    red: channel(LightChannel.red),
    green: channel(LightChannel.green),
    blue: channel(LightChannel.blue),
    white: channel(LightChannel.white),
    uv: channel(LightChannel.uv),
  );
}

TimerConfig _timer(Object? value, String path) {
  final json = objectOf(value, path);
  int integer(TimerField field, int min, int max) =>
      intOf(json[field.wire], '$path.${field.wire}', min, max);
  bool boolean(TimerField field) =>
      boolOf(json[field.wire], '$path.${field.wire}');
  return TimerConfig(
    index: integer(TimerField.slot, 1, 2),
    enabled: boolean(TimerField.enabled),
    startHour: integer(TimerField.startHour, 0, 23),
    startMinute: integer(TimerField.startMinute, 0, 59),
    endHour: integer(TimerField.endHour, 0, 23),
    endMinute: integer(TimerField.endMinute, 0, 59),
    sunriseSunsetEnabled: boolean(TimerField.sunriseSunsetEnabled),
    sunriseMinutes: integer(TimerField.sunriseMinutes, 0, 255),
    sunsetMinutes: integer(TimerField.sunsetMinutes, 0, 255),
  );
}
