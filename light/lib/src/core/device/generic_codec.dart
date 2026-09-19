import 'dart:typed_data';

import '../protocol/protocol.dart';
import 'checksum.dart';
import 'function_type.dart';
import 'json_read.dart';

/// 归一化后的目标特征
class GenericCharacteristic {
  const GenericCharacteristic({required this.service, required this.char});

  final String service;
  final String char;

  Map<String, Object?> toJson() => {'service': service, 'char': char};

  @override
  bool operator ==(Object other) =>
      other is GenericCharacteristic &&
      other.service == service &&
      other.char == char;

  @override
  int get hashCode => Object.hash(service, char);
}

/// 取值规则里的 `as`，决定状态值的 Dart 类型
enum WireValueKind implements WireEnum {
  boolean('bool'),
  integer('int'),
  enumeration('enum'),
  percent('percent');

  const WireValueKind(this.wire);

  @override
  final String wire;

  static WireValueKind? valueOf(Object? raw) => wireValueOf(values, raw);

  /// 枚举字面量在错误信息里的写法
  static String get choices => values.map((value) => value.wire).join('、');
}

/// 多字节数值的端序
enum ByteEndian implements WireEnum {
  big('big'),
  little('little');

  const ByteEndian(this.wire);

  @override
  final String wire;

  static ByteEndian? valueOf(Object? raw) => wireValueOf(values, raw);
}

/// 帧里的时间字段
enum ClockField implements WireEnum {
  hour('hour'),
  minute('minute'),
  second('second'),
  unix('unix');

  const ClockField(this.wire);

  @override
  final String wire;

  static ClockField? valueOf(Object? raw) => wireValueOf(values, raw);
}

/// 帧段或校验覆盖的范围
enum FrameSpan implements WireEnum {
  payload('payload'),
  frame('frame');

  const FrameSpan(this.wire);

  @override
  final String wire;

  static FrameSpan? valueOf(Object? raw) => wireValueOf(values, raw);
}

/// 帧段的种类，一个段只能声明其中一种
enum FrameSegmentKind implements WireEnum {
  constant('const'),
  command('command'),
  reserved('reserved'),
  length('length'),
  payload('payload'),
  crc('crc');

  const FrameSegmentKind(this.wire);

  @override
  final String wire;
}

/// 读命令的取值方式
enum GenericCommandSource implements WireEnum {
  /// 只消费设备推送的通知
  notify('notify'),

  /// 主动读取特征
  read('read');

  const GenericCommandSource(this.wire);

  @override
  final String wire;

  static GenericCommandSource? valueOf(Object? raw) =>
      wireValueOf(values, raw);
}

/// 读命令的返回类别
enum GenericCommandKind implements WireEnum {
  /// 设备状态
  state('state'),

  /// 操作确认
  ack('ack');

  const GenericCommandKind(this.wire);

  @override
  final String wire;

  static GenericCommandKind? valueOf(Object? raw) =>
      wireValueOf(values, raw);
}

/// 值的编码规则，对应设计文档 8.2 节
///
/// [as] 决定状态值的 Dart 类型：[WireValueKind.boolean]、[WireValueKind.enumeration]、
/// [WireValueKind.integer]、[WireValueKind.percent]。
/// 给定 [map] 时按显式映射编解码，否则按 [scale] / [offset] 线性换算。
class GenericValueSpec {
  const GenericValueSpec({
    required this.as,
    this.bytes = 1,
    this.endian = ByteEndian.big,
    this.min,
    this.max,
    this.scale = 1,
    this.offset = 0,
    this.map,
    this.reverse,
    this.fallback,
  });

  final WireValueKind as;
  final int bytes;
  final ByteEndian endian;
  final int? min;
  final int? max;
  final double scale;
  final double offset;

  /// 状态值 -> 十六进制字节串
  final Map<String, String>? map;

  /// 十六进制字节串（大写、无分隔） -> 状态值，解析时按 [as] 还原类型
  final Map<String, Object?>? reverse;

  /// 字段缺失时使用的值
  final Object? fallback;

  bool get isMapped => map != null;

  /// 把状态值编码成字节
  List<int> encode(Object? value) {
    final resolved = value ?? fallback;
    if (resolved == null) throw const FormatException('缺少编码所需的字段值');
    final mapping = map;
    if (mapping != null) {
      final key = mappingKey(resolved);
      final hex = mapping[key];
      if (hex == null) throw FormatException('取值不在映射范围内：$resolved');
      return readHexBytes(hex, 'map.$key');
    }
    if (as == WireValueKind.boolean) return [resolved == true ? 1 : 0];
    if (resolved is! num) {
      throw FormatException('${as.wire} 需要数值，实际是 ${resolved.runtimeType}');
    }
    if (as == WireValueKind.percent) {
      return [(resolved.toDouble().clamp(0, 100)).round()];
    }
    final scaled = ((resolved.toDouble() - offset) * scale).round();
    final low = min ?? 0;
    final high = max ?? (bytes >= 2 ? 65535 : 255);
    if (scaled < low || scaled > high) {
      throw FormatException('取值 $resolved 超出范围 $low~$high');
    }
    return toBytes(scaled, bytes, endian);
  }

  /// 把字节解析回状态值
  ///
  /// [range] 与编码方向一致，比较的是换算前的整数值；越界说明报文不属于该字段，
  /// 抛出异常而不写回状态。
  Object decode(List<int> bytes) {
    final mapping = reverse;
    if (mapping != null) {
      final key = hexKey(bytes);
      if (!mapping.containsKey(key)) throw FormatException('未定义的取值：$key');
      return mapping[key]!;
    }
    final raw = fromBytes(bytes, endian);
    if (min != null && max != null && (raw < min! || raw > max!)) {
      throw FormatException('解码值 $raw 超出范围 $min~$max');
    }
    if (as == WireValueKind.boolean) return raw != 0;
    if (as == WireValueKind.percent) return raw.clamp(0, 100);
    final value = raw / scale + offset;
    // 只保留整除的结果为整数，避免把真实的小数缩放抹平
    return isIntegral(scale) &&
            isIntegral(offset) &&
            value == value.roundToDouble()
        ? value.round()
        : value;
  }

  /// 映射表使用的键：布尔按 JSON 字面量书写，其余按字符串
  static String mappingKey(Object value) => '$value';

  static bool isIntegral(double value) => value == value.roundToDouble();

  /// 按端序把整数拆成字节
  static List<int> toBytes(int value, int bytes, ByteEndian endian) {
    final result = List<int>.filled(bytes, 0);
    for (var index = 0; index < bytes; index++) {
      final shift = endian == ByteEndian.little ? index : bytes - 1 - index;
      result[index] = (value >> (shift * 8)) & 0xFF;
    }
    return result;
  }

  /// 按端序把字节拼成整数
  static int fromBytes(List<int> bytes, ByteEndian endian) {
    var value = 0;
    for (var index = 0; index < bytes.length; index++) {
      final shift = endian == ByteEndian.little ? index : bytes.length - 1 - index;
      value |= (bytes[index] & 0xFF) << (shift * 8);
    }
    return value;
  }

  /// 映射表反查使用的键：大写、无分隔的十六进制
  static String hexKey(List<int> bytes) => bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();
}

/// 写命令负载里的一段
class GenericPayloadSegment {
  const GenericPayloadSegment({
    this.field,
    this.clock,
    this.constant,
    this.spec,
  });

  /// 取当前功能自身状态值时使用的特殊字段名
  static const String selfField = 'value';

  /// 整机状态中的字段路径，用协议字段名书写；省略表示当前功能自身的状态值
  final String? field;

  /// 取当前时间
  final ClockField? clock;
  final List<int>? constant;
  final GenericValueSpec? spec;

  Map<String, Object?> toJson() {
    if (constant != null) {
      return {
        'const': constant!
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join(),
      };
    }
    if (clock != null) return {'clock': clock!.wire};
    return {if (field != null) 'field': field, ..._specToJson(spec)};
  }
}

/// 读命令响应负载里的一项
class GenericFieldSegment {
  const GenericFieldSegment({
    required this.index,
    required this.length,
    this.target,
    this.spec,
  });

  /// 负载内起始偏移
  final int index;

  /// 读取字节数
  final int length;

  /// 写回哪个功能，省略表示只用于校验
  final ConfigurableFunction? target;
  final GenericValueSpec? spec;

  Map<String, Object?> toJson() => {
    'index': index,
    if (target != null) 'target': target!.wire,
    ..._specToJson(spec, decoding: true),
  };
}

/// 把取值规则序列化回配置
///
/// [decoding] 为真时输出读取方向的映射表（十六进制字节 -> 状态值），
/// 与 `fields` 的配置写法一致；否则输出写入方向的映射表。
Map<String, Object?> _specToJson(
  GenericValueSpec? spec, {
  bool decoding = false,
}) {
  if (spec == null) return const {};
  return {
    'as': spec.as.wire,
    if (spec.bytes != 1) 'bytes': spec.bytes,
    if (spec.endian != ByteEndian.big) 'endian': spec.endian.wire,
    if (spec.min != null || spec.max != null)
      'range': [spec.min ?? 0, spec.max ?? 65535],
    if (spec.scale != 1) 'scale': spec.scale,
    if (spec.offset != 0) 'offset': spec.offset,
    if (spec.map != null) 'map': decoding ? spec.reverse : spec.map,
    if (spec.fallback != null) 'default': spec.fallback,
  };
}

/// 一条命令：带 [payload] 表示可写，带 [fields] 或 [kind] 为 `ack` 表示可读
class GenericCommand {
  const GenericCommand({
    required this.name,
    required this.charName,
    required this.target,
    this.command,
    this.writeType = GatewayWriteType.withResponse,
    this.payload,
    this.fields,
    this.source = GenericCommandSource.notify,
    this.kind = GenericCommandKind.state,
    this.acceptLength,
  });

  final String name;

  /// 目标特征在 `chars` 中的名字，序列化时需要保留
  final String charName;
  final GenericCharacteristic target;

  /// 命令字节，帧含命令段时必填
  final int? command;
  final GatewayWriteType writeType;
  final List<GenericPayloadSegment>? payload;
  final List<GenericFieldSegment>? fields;

  /// 读命令的取值方式
  final GenericCommandSource source;
  final GenericCommandKind kind;

  /// `ack` 响应可接受的负载长度，长度不符视为设备拒绝
  final int? acceptLength;

  bool get isWrite => payload != null;

  bool get isRead => fields != null || kind == GenericCommandKind.ack;

  bool get acceptsWithoutResponse =>
      writeType == GatewayWriteType.withoutResponse;

  Map<String, Object?> toJson() => {
    'char': charName,
    if (command != null) 'command': command!.toRadixString(16).padLeft(2, '0'),
    if (writeType != GatewayWriteType.withResponse)
      'writeType': writeType.wire,
    if (payload != null)
      'payload': [for (final segment in payload!) segment.toJson()],
    if (fields != null) 'fields': [for (final field in fields!) field.toJson()],
    if (source != GenericCommandSource.notify) 'source': source.wire,
    if (kind != GenericCommandKind.state) 'kind': kind.wire,
    if (acceptLength != null) 'accept': {'length': acceptLength},
  };
}

// ============================================================================
// 帧
// ============================================================================

sealed class GenericFrameSegment {
  const GenericFrameSegment();
}

class _ConstSegment extends GenericFrameSegment {
  const _ConstSegment(this.bytes);
  final List<int> bytes;
}

class _CommandSegment extends GenericFrameSegment {
  const _CommandSegment();
}

class _LengthSegment extends GenericFrameSegment {
  const _LengthSegment({
    required this.of,
    this.bytes = 1,
    this.endian = ByteEndian.big,
    this.max,
  });
  final FrameSpan of;
  final int bytes;
  final ByteEndian endian;
  final int? max;
}

class _PayloadSegment extends GenericFrameSegment {
  const _PayloadSegment();
}

class _ChecksumSegment extends GenericFrameSegment {
  const _ChecksumSegment({
    required this.type,
    this.endian = ByteEndian.big,
    this.of = FrameSpan.frame,
  });
  final ChecksumKind type;
  final ByteEndian endian;
  final FrameSpan of;
}

/// 请求或响应报文的封包规则
class GenericFrame {
  const GenericFrame(this.segments);

  final List<GenericFrameSegment> segments;

  bool get usesCommand => segments.any((s) => s is _CommandSegment);

  bool get usesPayload => segments.any((s) => s is _PayloadSegment);

  /// 按段顺序拼出完整报文
  Uint8List encode({int? command, required List<int> payload}) {
    final out = <int>[];
    for (final segment in segments) {
      switch (segment) {
        case _ConstSegment(:final bytes):
          out.addAll(bytes);
        case _CommandSegment():
          if (command == null)
            throw const FormatException('帧包含命令段，但命令没有声明命令字节');
          out.add(command & 0xFF);
        case _LengthSegment(:final of, :final bytes, :final endian, :final max):
          final size = of == FrameSpan.payload ? payload.length : out.length;
          final limit = max ?? (bytes >= 2 ? 65535 : 255);
          if (size > limit) throw FormatException('长度 $size 超出 ${of.wire} 上限 $limit');
          out.addAll(GenericValueSpec.toBytes(size, bytes, endian));
        case _PayloadSegment():
          out.addAll(payload);
        case _ChecksumSegment(:final type, :final endian, :final of):
          final size = type.size;
          if (size == 0) break;
          final value = type.compute(
            of == FrameSpan.payload ? payload : out,
          );
          out.addAll(GenericValueSpec.toBytes(value, size, endian));
      }
    }
    return Uint8List.fromList(out);
  }

  Map<String, Object?> toJson() => {
    'segments': [
      for (final segment in segments)
        switch (segment) {
          _ConstSegment(:final bytes) => {
            FrameSegmentKind.constant.wire: _hex(bytes),
          },
          _CommandSegment() => {FrameSegmentKind.command.wire: true},
          _LengthSegment(:final of, :final bytes, :final endian) => {
            FrameSegmentKind.length.wire: {
              'of': of.wire,
              if (bytes != 1) 'bytes': bytes,
              if (endian != ByteEndian.big) 'endian': endian.wire,
            },
          },
          _PayloadSegment() => {FrameSegmentKind.payload.wire: true},
          _ChecksumSegment(:final type, :final endian, :final of) => {
            FrameSegmentKind.crc.wire: {
              'type': type.wire,
              if (endian != ByteEndian.big) 'endian': endian.wire,
              if (of != FrameSpan.frame) 'of': of.wire,
            },
          },
        },
    ],
  };

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// 响应帧解析出的原始内容
class GenericParsedFrame {
  const GenericParsedFrame({this.command, required this.payload});

  final int? command;
  final Uint8List payload;
}

/// 解析后的响应：命中的命令、类别与写回各功能的值
class GenericDecodedResponse {
  const GenericDecodedResponse({
    required this.commandName,
    required this.kind,
    required this.accepted,
    this.commandByte,
    this.values = const {},
  });

  final String commandName;
  final GenericCommandKind kind;

  /// `ack` 响应是否被接受；`state` 恒为 true
  final bool accepted;
  final int? commandByte;

  /// 功能类型 -> 解析出的状态值，只有带 `target` 的字段会出现在这里
  final Map<ConfigurableFunction, Object?> values;

  bool get isState => kind == GenericCommandKind.state;
}

// ============================================================================
// 编解码器
// ============================================================================

/// 设备配置里的字节层描述：特征表、封包规则与命令表
///
/// 只做纯编解码，不依赖 MQTT，便于独立测试。传输由 GenericDeviceSession 负责。
class GenericCodec {
  GenericCodec._({
    required this.chars,
    required this.frame,
    required this.response,
    required this.commands,
    required this.subscribe,
    required this.writes,
  });

  final Map<String, GenericCharacteristic> chars;
  final GenericFrame? frame;
  final GenericFrame? response;
  final Map<String, GenericCommand> commands;

  /// 需要订阅通知的特征名
  final List<String> subscribe;

  /// 功能类型 -> 写命令名
  final Map<ConfigurableFunction, String> writes;

  /// 解析配置中的字节层描述
  ///
  /// [serviceFallbacks] 是设备 `bleServices` 声明的服务 UUID，特征省略服务时按顺序取用。
  factory GenericCodec.fromJson(
    Map<String, Object?> json, {
    required List<String> serviceFallbacks,
  }) {
    final chars = _parseChars(json, serviceFallbacks);
    final frame = _parseFrame(json, 'frame');
    final response = _parseFrame(json, 'response');
    final types = _functionTypes(json);
    final commands = _parseCommands(json, chars);

    final writes = commands.values.any((c) => c.isWrite);
    // 省略 frame 表示负载原样写入，不做封包；显式声明了 frame 就必须留出负载位置
    if (frame != null && writes && !frame.usesPayload) {
      throw const FormatException('frame 缺少 payload 段，写命令无处安放负载');
    }
    if (response != null && !response.usesPayload) {
      throw const FormatException('response 缺少 payload 段，无法定位响应负载');
    }
    final needsCommand =
        (frame?.usesCommand ?? false) || (response?.usesCommand ?? false);
    for (final command in commands.values) {
      if (needsCommand && command.command == null) {
        throw FormatException('帧含命令段，命令 ${command.name} 必须声明 command');
      }
      if (!needsCommand && command.command != null) {
        throw FormatException('帧没有命令段，命令 ${command.name} 不应声明 command');
      }
      for (final field in command.fields ?? const <GenericFieldSegment>[]) {
        if (field.target != null && !types.contains(field.target)) {
          throw FormatException(
            'commands.${command.name} 的 target 指向未声明的功能：${field.target!.wire}',
          );
        }
      }
    }

    final subscribe = <String>[];
    final rawSubscribe = optionalList(json, 'subscribe', 'subscribe');
    for (var index = 0; index < rawSubscribe.length; index++) {
      final name = readString(rawSubscribe[index], 'subscribe[$index]');
      if (!chars.containsKey(name))
        throw FormatException('subscribe[$index] 引用了未定义的特征：$name');
      if (!subscribe.contains(name)) subscribe.add(name);
    }

    final bound = <ConfigurableFunction, String>{};
    final rawFunctions = optionalList(json, 'functions', 'functions');
    for (var index = 0; index < rawFunctions.length; index++) {
      final path = 'functions[$index]';
      final entry = readObject(rawFunctions[index], path);
      final type = readFunctionType(entry['type'], '$path.type');
      if (entry['write'] == null) continue;
      final target = readString(entry['write'], '$path.write');
      final command = commands[target];
      if (command == null)
        throw FormatException('$path.write 指向未定义的命令：$target');
      if (!command.isWrite)
        throw FormatException('$path.write 指向的命令没有 payload：$target');
      if (bound.containsKey(type))
        throw FormatException('$path.write 与功能 ${type.wire} 的绑定重复');
      bound[type] = target;
    }

    return GenericCodec._(
      chars: chars,
      frame: frame,
      response: response,
      commands: commands,
      subscribe: subscribe,
      writes: bound,
    );
  }

  /// 配置里声明的功能类型
  static Set<ConfigurableFunction> _functionTypes(Map<String, Object?> json) {
    final result = <ConfigurableFunction>{};
    final raw = optionalList(json, 'functions', 'functions');
    for (var index = 0; index < raw.length; index++) {
      final entry = readObject(raw[index], 'functions[$index]');
      final type = readFunctionType(entry['type'], 'functions[$index].type');
      result.add(type);
    }
    return result;
  }

  bool get supportsRemoteControl => commands.isNotEmpty && frame != null;

  bool get isDeclared => chars.isNotEmpty || commands.isNotEmpty;

  Map<String, Object?> toJson() => {
    if (chars.isNotEmpty)
      'chars': {
        for (final entry in chars.entries) entry.key: entry.value.toJson(),
      },
    if (frame != null) 'frame': frame!.toJson(),
    if (response != null) 'response': response!.toJson(),
    if (subscribe.isNotEmpty) 'subscribe': subscribe,
    if (commands.isNotEmpty)
      'commands': {
        for (final entry in commands.entries) entry.key: entry.value.toJson(),
      },
  };

  GenericCommand? writeCommandFor(ConfigurableFunction functionType) {
    final name = writes[functionType];
    return name == null ? null : commands[name];
  }

  /// 一组功能需要下发的写命令，按命令表声明顺序去重
  List<String> writeCommandsFor(Iterable<ConfigurableFunction> functionTypes) {
    final wanted = <String>{
      for (final type in functionTypes)
        if (writes[type] != null) writes[type]!,
    };
    if (wanted.isEmpty) return const [];
    return [
      for (final name in commands.keys)
        if (wanted.contains(name)) name,
    ];
  }

  /// 编码一条写命令
  ///
  /// [state] 是整机状态（功能类型 -> 值），字段路径按它解析；
  /// [value] 是当前功能自身的状态值，供 `{"field": "value"}` 使用。
  Uint8List encode(
    String commandName,
    Map<ConfigurableFunction, Object?> state, {
    Object? value,
    DateTime? now,
  }) {
    final command = commands[commandName];
    if (command == null) throw FormatException('未定义的命令：$commandName');
    final segments = command.payload;
    if (segments == null)
      throw FormatException('命令 $commandName 没有 payload，不能写入');
    final payload = <int>[];
    for (var index = 0; index < segments.length; index++) {
      final segment = segments[index];
      final path = 'commands.$commandName.payload[$index]';
      if (segment.constant != null) {
        payload.addAll(segment.constant!);
        continue;
      }
      if (segment.clock != null) {
        payload.addAll(
          _clockBytes(segment.clock!, path, now ?? DateTime.now()),
        );
        continue;
      }
      // 省略 field 或写 value 都表示当前功能自身的状态值
      final field = segment.field;
      final resolved = field == null || field == GenericPayloadSegment.selfField
          ? value
          : _resolvePath(state, field, '字段 $field 不在设备状态中');
      final spec = segment.spec ?? const GenericValueSpec(as: WireValueKind.integer);
      try {
        payload.addAll(spec.encode(resolved));
      } on FormatException catch (error) {
        throw FormatException('$path：${error.message}');
      }
    }
    final frame = this.frame;
    if (frame == null) return Uint8List.fromList(payload);
    return frame.encode(command: command.command, payload: payload);
  }

  /// 编码一条写命令并返回可直接放进 V1 `value` 字段的十六进制字符串
  String encodeHex(
    String commandName,
    Map<ConfigurableFunction, Object?> state, {
    Object? value,
    DateTime? now,
  }) => encode(
    commandName,
    state,
    value: value,
    now: now,
  ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// 解析响应报文；无法归属到任何命令时返回 null
  GenericDecodedResponse? decode(
    List<int> bytes, {
    String? commandName,
    String? charName,
  }) {
    final frame = response;
    int? commandByte;
    List<int> payload;
    if (frame == null) {
      payload = bytes;
    } else {
      final parsed = _decodeFrame(frame, bytes);
      if (parsed == null) return null;
      commandByte = parsed.command;
      payload = parsed.payload;
    }
    final command = commandByte != null
        ? _commandByByte(commandByte, charName)
        : (commandName != null
              ? commands[commandName]
              : _commandForChar(charName));
    if (command == null) return null;
    if (command.kind == GenericCommandKind.ack) {
      return GenericDecodedResponse(
        commandName: command.name,
        kind: GenericCommandKind.ack,
        accepted:
            command.acceptLength == null ||
            payload.length == command.acceptLength,
        commandByte: commandByte,
      );
    }
    final fields = command.fields;
    if (fields == null) return null;
    final values = <ConfigurableFunction, Object?>{};
    for (var index = 0; index < fields.length; index++) {
      final field = fields[index];
      final path = 'commands.${command.name}.fields[$index]';
      if (field.index + field.length > payload.length) {
        throw FormatException('$path 需要的字节超出负载长度：负载 ${payload.length} 字节');
      }
      final slice = payload.sublist(field.index, field.index + field.length);
      final spec = field.spec ?? const GenericValueSpec(as: WireValueKind.integer);
      Object decoded;
      try {
        decoded = spec.decode(slice);
      } on FormatException catch (error) {
        throw FormatException('$path：${error.message}');
      }
      if (field.target != null) values[field.target!] = decoded;
    }
    return GenericDecodedResponse(
      commandName: command.name,
      kind: GenericCommandKind.state,
      accepted: true,
      commandByte: commandByte,
      values: values,
    );
  }

  /// 按命令字节找可读命令；同一字节上的写命令不参与匹配
  GenericCommand? _commandByByte(int byte, String? charName) {
    for (final command in commands.values) {
      if (command.command != byte || !command.isRead) continue;
      if (charName == null || chars[charName] == command.target) return command;
    }
    return null;
  }

  GenericCommand? _commandForChar(String? charName) {
    if (charName == null) return null;
    final target = chars[charName];
    if (target == null) return null;
    for (final command in commands.values) {
      if (command.target == target &&
          command.isRead &&
          command.source == GenericCommandSource.notify)
        return command;
    }
    return null;
  }

  /// 需要主动读取的读命令
  List<String> get polledCommands => [
    for (final command in commands.values)
      if (command.isRead && command.source == GenericCommandSource.read)
        command.name,
  ];

  /// 按帧的段顺序解析报文，长度、常量与校验任一不符都返回 null
  static GenericParsedFrame? _decodeFrame(GenericFrame frame, List<int> raw) {
    final declared = _declaredPayloadLength(frame, raw);
    // 没有长度段时负载长度按剩余字节推断，必须扣掉其后跟着的校验字段
    final trailing = _trailingChecksumBytes(frame);
    var offset = 0;
    int? command;
    List<int>? payload;
    var seenPayload = false;
    for (final segment in frame.segments) {
      switch (segment) {
        case _ConstSegment(:final bytes):
          if (!_matches(raw, offset, bytes)) return null;
          offset += bytes.length;
        case _CommandSegment():
          if (offset >= raw.length) return null;
          command = raw[offset++];
        case _LengthSegment(:final bytes):
          if (offset + bytes > raw.length) return null;
          offset += bytes;
        case _PayloadSegment():
          seenPayload = true;
          final length = declared ?? (raw.length - offset - trailing);
          if (length < 0 || offset + length > raw.length) return null;
          payload = raw.sublist(offset, offset + length);
          offset += length;
        case _ChecksumSegment(:final type, :final endian, :final of):
          final size = type.size;
          if (size == 0) break;
          if (offset + size > raw.length) return null;
          final expected = type.compute(
            of == FrameSpan.payload
                ? (payload ?? const <int>[])
                : raw.sublist(0, offset),
          );
          final actual = GenericValueSpec.fromBytes(
            raw.sublist(offset, offset + size),
            endian,
          );
          if (expected != actual) return null;
          offset += size;
      }
    }
    if (!seenPayload) return null;
    return GenericParsedFrame(
      command: command,
      payload: Uint8List.fromList(payload ?? const []),
    );
  }

  /// 负载段之后所有校验字段占用的字节数之和
  static int _trailingChecksumBytes(GenericFrame frame) {
    var total = 0;
    var afterPayload = false;
    for (final segment in frame.segments) {
      if (segment is _PayloadSegment) {
        afterPayload = true;
      } else if (afterPayload && segment is _ChecksumSegment) {
        total += segment.type.size;
      }
    }
    return total;
  }

  /// 从长度段读出负载字节数；没有长度段时返回 null，表示按剩余字节处理
  static int? _declaredPayloadLength(GenericFrame frame, List<int> raw) {
    var cursor = 0;
    for (final segment in frame.segments) {
      switch (segment) {
        case _ConstSegment(:final bytes):
          cursor += bytes.length;
        case _CommandSegment():
          cursor += 1;
        case _LengthSegment(:final of, :final bytes, :final endian):
          if (of != FrameSpan.payload || cursor + bytes > raw.length) return null;
          return GenericValueSpec.fromBytes(
            raw.sublist(cursor, cursor + bytes),
            endian,
          );
        case _PayloadSegment():
          return null;
        case _ChecksumSegment():
          return null;
      }
    }
    return null;
  }

  static bool _matches(List<int> raw, int offset, List<int> expected) {
    if (offset + expected.length > raw.length) return false;
    for (var index = 0; index < expected.length; index++) {
      if (raw[offset + index] != expected[index]) return false;
    }
    return true;
  }

  static List<int> _clockBytes(ClockField clock, String path, DateTime now) {
    final utc = clock == ClockField.unix ? now.toUtc() : now;
    return switch (clock) {
      ClockField.hour => [utc.hour],
      ClockField.minute => [utc.minute],
      ClockField.second => [utc.second],
      ClockField.unix => [
        for (var shift = 24; shift >= 0; shift -= 8)
          ((utc.millisecondsSinceEpoch ~/ 1000) >> shift) & 0xFF,
      ],
    };
  }

  /// 按 `light.red` 这样的字段路径从整机状态取值
  ///
  /// 首段是功能类型，其余段是该功能状态对象里的协议字段名。
  static Object? _resolvePath(
    Map<ConfigurableFunction, Object?> state,
    String field,
    String message,
  ) {
    final parts = field.split('.');
    final function = ConfigurableFunction.valueOf(parts.first);
    if (function == null || !state.containsKey(function)) {
      throw FormatException('$message：$field');
    }
    Object? current = state[function];
    for (final part in parts.skip(1)) {
      if (current is! Map) throw FormatException('$message：$field');
      if (!current.containsKey(part)) throw FormatException('$message：$field');
      current = current[part];
    }
    return current;
  }

  // --------------------------------------------------------------------------
  // 解析
  // --------------------------------------------------------------------------

  static Map<String, GenericCharacteristic> _parseChars(
    Map<String, Object?> json,
    List<String> serviceFallbacks,
  ) {
    final raw = optionalObject(json, 'chars', 'chars');
    final result = <String, GenericCharacteristic>{};
    for (final entry in raw.entries) {
      final path = 'chars.${entry.key}';
      final value = readObject(entry.value, path);
      final char = readString(value['char'], '$path.char');
      final service = value['service'] == null
          ? (serviceFallbacks.isEmpty
                ? throw FormatException(
                    '$path 省略了 service，但设备没有 bleServices 可回退',
                  )
                : serviceFallbacks.first)
          : readString(value['service'], '$path.service');
      result[entry.key] = GenericCharacteristic(
        service: _normalizeUuid(service, '$path.service'),
        char: _normalizeUuid(char, '$path.char'),
      );
    }
    return result;
  }

  static GenericFrame? _parseFrame(Map<String, Object?> json, String key) {
    final raw = json[key];
    if (raw == null) return null;
    final object = readObject(raw, key);
    final segments = optionalList(object, 'segments', key);
    if (segments.isEmpty) throw FormatException('$key.segments 不能为空');
    final parsed = <GenericFrameSegment>[];
    var commandCount = 0, payloadCount = 0;
    for (var index = 0; index < segments.length; index++) {
      final path = '$key.segments[$index]';
      final segment = readObject(segments[index], path);
      final kinds = FrameSegmentKind.values
          .where((kind) => segment.containsKey(kind.wire))
          .toList();
      if (kinds.length != 1) throw FormatException('$path 必须且只能声明一种段');
      final kind = kinds.single;
      final value = segment[kind.wire];
      switch (kind) {
        case FrameSegmentKind.constant:
        case FrameSegmentKind.reserved:
          parsed.add(_ConstSegment(readHexBytes(value, '$path.${kind.wire}')));
        case FrameSegmentKind.command:
          if (value != true) throw FormatException('$path.command 必须是 true');
          if (++commandCount > 1)
            throw FormatException('$key 最多只能有一个 command 段');
          parsed.add(const _CommandSegment());
        case FrameSegmentKind.payload:
          if (value != true) throw FormatException('$path.payload 必须是 true');
          if (++payloadCount > 1)
            throw FormatException('$key 最多只能有一个 payload 段');
          parsed.add(const _PayloadSegment());
        case FrameSegmentKind.length:
          final length = readObject(value, '$path.length');
          final of = readSpan(
            length,
            'of',
            '$path.length',
            fallback: FrameSpan.payload,
          );
          final width = optionalInteger(
            length,
            'bytes',
            '$path.length',
            fallback: 1,
            min: 1,
            max: 4,
          );
          final ceiling = optionalInteger(
            length,
            'max',
            '$path.length',
            fallback: 0,
            min: 0,
            max: 0xFFFFFF,
          );
          parsed.add(
            _LengthSegment(
              of: of,
              bytes: width,
              endian: _endian(length, '$path.length'),
              max: ceiling == 0 ? null : ceiling,
            ),
          );
        case FrameSegmentKind.crc:
          final crc = readObject(value, '$path.crc');
          final type = readChecksumKind(crc['type'], '$path.crc.type');
          parsed.add(
            _ChecksumSegment(
              type: type,
              endian: _endian(crc, '$path.crc'),
              of: readSpan(crc, 'of', '$path.crc', fallback: FrameSpan.frame),
            ),
          );
      }
    }
    return GenericFrame(parsed);
  }

  static ByteEndian _endian(Map<String, Object?> json, String path) {
    final raw = json['endian'];
    if (raw == null) return ByteEndian.big;
    final endian = ByteEndian.valueOf(raw);
    if (endian == null) throw FormatException('$path.endian 只能是 big 或 little');
    return endian;
  }

  static Map<String, GenericCommand> _parseCommands(
    Map<String, Object?> json,
    Map<String, GenericCharacteristic> chars,
  ) {
    final raw = optionalObject(json, 'commands', 'commands');
    final result = <String, GenericCommand>{};
    for (final entry in raw.entries) {
      final path = 'commands.${entry.key}';
      final value = readObject(entry.value, path);
      final charName = readString(value['char'], '$path.char');
      final target = chars[charName];
      if (target == null)
        throw FormatException('$path.char 引用了未定义的特征：$charName');

      int? command;
      final rawCommand = value['command'];
      if (rawCommand != null) {
        final bytes = readHexBytes(rawCommand, '$path.command');
        if (bytes.length != 1) throw FormatException('$path.command 必须是单个字节');
        command = bytes.first;
      }

      List<GenericPayloadSegment>? payload;
      if (value['payload'] != null) {
        final list = readList(value['payload'], '$path.payload');
        if (list.isEmpty) throw FormatException('$path.payload 不能为空');
        payload = [
          for (var index = 0; index < list.length; index++)
            _parsePayloadSegment(
              readObject(list[index], '$path.payload[$index]'),
              '$path.payload[$index]',
            ),
        ];
      }

      List<GenericFieldSegment>? fields;
      if (value['fields'] != null) {
        final list = readList(value['fields'], '$path.fields');
        if (list.isEmpty) throw FormatException('$path.fields 不能为空');
        fields = [
          for (var index = 0; index < list.length; index++)
            _parseFieldSegment(
              readObject(list[index], '$path.fields[$index]'),
              '$path.fields[$index]',
            ),
        ];
      }

      final kind = readCommandKind(value, 'kind', path,
          fallback: GenericCommandKind.state);
      final source = readCommandSource(value, 'source', path,
          fallback: GenericCommandSource.notify);
      final writeType = readWriteType(value, 'writeType', path,
          fallback: GatewayWriteType.withResponse);

      if (payload == null && fields == null && kind != GenericCommandKind.ack) {
        throw FormatException('$path 必须声明 payload、fields 或 kind: ack 之一');
      }

      int? acceptLength;
      if (value['accept'] != null) {
        final accept = readObject(value['accept'], '$path.accept');
        acceptLength = readInteger(
          accept['length'],
          '$path.accept.length',
          0,
          65535,
        );
      }

      result[entry.key] = GenericCommand(
        name: entry.key,
        charName: charName,
        target: target,
        command: command,
        writeType: writeType,
        payload: payload,
        fields: fields,
        source: source,
        kind: kind,
        acceptLength: acceptLength,
      );
    }
    return result;
  }

  static GenericPayloadSegment _parsePayloadSegment(
    Map<String, Object?> json,
    String path,
  ) {
    if (json['const'] != null) {
      return GenericPayloadSegment(
        constant: readHexBytes(json['const'], '$path.const'),
      );
    }
    if (json['clock'] != null) {
      final clock = readClock(json['clock'], '$path.clock');
      return GenericPayloadSegment(clock: clock);
    }
    final field = json['field'] == null
        ? null
        : readString(json['field'], '$path.field');
    return GenericPayloadSegment(
      field: field,
      spec: _parseValueSpec(json, path, decoding: false),
    );
  }

  static GenericFieldSegment _parseFieldSegment(
    Map<String, Object?> json,
    String path,
  ) {
    final index = readInteger(json['index'], '$path.index', 0, 4096);
    final spec = _parseValueSpec(json, path, decoding: true);
    final length = optionalInteger(
      json,
      'length',
      path,
      fallback: spec.bytes,
      min: 1,
      max: 8,
    );
    return GenericFieldSegment(
      index: index,
      length: length,
      target: json['target'] == null
          ? null
          : readFunctionType(json['target'], '$path.target'),
      spec: spec,
    );
  }

  /// 解析一份取值规则
  ///
  /// `map` 的方向随用途变化：写入时键是状态值、值是十六进制字节；
  /// 读取时键是十六进制字节、值是状态值。两种写法都归一化成同一对正反表。
  static GenericValueSpec _parseValueSpec(
    Map<String, Object?> json,
    String path, {
    required bool decoding,
  }) {
    final as = readValueKind(json, 'as', path, fallback: WireValueKind.integer);
    Map<String, String>? map;
    Map<String, Object?>? reverse;
    if (json['map'] != null) {
      final raw = readObject(json['map'], '$path.map');
      if (raw.isEmpty) throw FormatException('$path.map 不能为空');
      final forward = <String, String>{};
      final backward = <String, Object?>{};
      for (final entry in raw.entries) {
        final String statusText;
        final List<int> bytes;
        if (decoding) {
          statusText = '${entry.value}';
          bytes = readHexBytes(entry.key, '$path.map.${entry.key}');
        } else {
          statusText = entry.key;
          bytes = readHexBytes(entry.value, '$path.map.${entry.key}');
        }
        forward[statusText] = GenericValueSpec.hexKey(bytes).toLowerCase();
        backward[GenericValueSpec.hexKey(bytes)] = _coerceStatus(
          decoding ? entry.value : entry.key,
          as,
          '$path.map.${entry.key}',
        );
      }
      if (as == WireValueKind.boolean &&
          (!forward.containsKey('true') || !forward.containsKey('false'))) {
        throw FormatException('$path.map 的布尔映射必须同时给出 true 和 false');
      }
      map = forward;
      reverse = backward;
    } else if (as == WireValueKind.enumeration || as == WireValueKind.boolean) {
      throw FormatException('$path.as 为 ${as.wire} 时必须声明 map');
    }

    int? min, max;
    if (json['range'] != null) {
      final range = readList(json['range'], '$path.range');
      if (range.length != 2) throw FormatException('$path.range 必须是两个数值');
      min = readInteger(range[0], '$path.range[0]', 0, 0xFFFFFFFF);
      max = readInteger(range[1], '$path.range[1]', 0, 0xFFFFFFFF);
      if (min > max) throw FormatException('$path.range 的下界不能大于上界');
    }

    return GenericValueSpec(
      as: as,
      bytes: optionalInteger(json, 'bytes', path, fallback: 1, min: 1, max: 4),
      endian: _endian(json, path),
      min: min,
      max: max,
      scale: json['scale'] == null
          ? 1
          : readNumber(json['scale'], '$path.scale', -1e9, 1e9),
      offset: json['offset'] == null
          ? 0
          : readNumber(json['offset'], '$path.offset', -1e9, 1e9),
      map: map,
      reverse: reverse,
      fallback: json['default'],
    );
  }

  /// 把映射表里的字面量还原成该 [as] 对应的 Dart 类型
  static Object _coerceStatus(Object? value, WireValueKind as, String path) =>
      switch (as) {
        WireValueKind.boolean => switch (value) {
          bool() => value,
          'true' => true,
          'false' => false,
          _ => throw FormatException('$path 必须是布尔值'),
        },
        WireValueKind.enumeration => value is String ? value : '$value',
        _ => switch (value) {
          int() => value,
          num() => value.toInt(),
          String() =>
            int.tryParse(value) ?? (throw FormatException('$path 必须是整数')),
          _ => throw FormatException('$path 必须是整数'),
        },
      };

  static String _normalizeUuid(String value, String path) {
    final clean = value.trim().toLowerCase().replaceAll('-', '');
    if (clean.isEmpty || !RegExp(r'^[0-9a-f]+$').hasMatch(clean)) {
      throw FormatException('$path 含非法字符：$value');
    }
    return switch (clean.length) {
      4 => '0000$clean-0000-1000-8000-00805f9b34fb',
      8 => '$clean-0000-1000-8000-00805f9b34fb',
      32 =>
        '${clean.substring(0, 8)}-${clean.substring(8, 12)}-${clean.substring(12, 16)}-'
            '${clean.substring(16, 20)}-${clean.substring(20)}',
      _ => throw FormatException('$path 的长度不受支持：$value'),
    };
  }
}

// ----------------------------------------------------------------------------
// 配置里的枚举取值
// ----------------------------------------------------------------------------

/// 读取功能类型，未知取值报错
ConfigurableFunction readFunctionType(Object? value, String path) {
  if (value == null) throw FormatException('$path 必须是非空字符串');
  final type = ConfigurableFunction.valueOf(value);
  if (type == null) {
    throw FormatException(
      '$path 不支持：$value（可用 ${ConfigurableFunction.values.map((t) => t.wire).join('、')}）',
    );
  }
  return type;
}

/// 从对象里读取可选的枚举取值，缺失时返回 [fallback]，显式填写非法值报错
T readEnum<T extends WireEnum>(
  Map<String, Object?> json,
  String key,
  String path, {
  required T fallback,
  required T? Function(Object? raw) parse,
  required String choices,
}) {
  final raw = json[key];
  if (raw == null) return fallback;
  final value = parse(raw);
  if (value == null) throw FormatException('$path.$key 只能是 $choices');
  return value;
}

WireValueKind readValueKind(
  Map<String, Object?> json,
  String key,
  String path, {
  required WireValueKind fallback,
}) => readEnum(
  json,
  key,
  path,
  fallback: fallback,
  parse: WireValueKind.valueOf,
  choices: WireValueKind.choices,
);

GenericCommandKind readCommandKind(
  Map<String, Object?> json,
  String key,
  String path, {
  required GenericCommandKind fallback,
}) => readEnum(
  json,
  key,
  path,
  fallback: fallback,
  parse: GenericCommandKind.valueOf,
  choices: 'state 或 ack',
);

GenericCommandSource readCommandSource(
  Map<String, Object?> json,
  String key,
  String path, {
  required GenericCommandSource fallback,
}) => readEnum(
  json,
  key,
  path,
  fallback: fallback,
  parse: GenericCommandSource.valueOf,
  choices: 'notify 或 read',
);

GatewayWriteType readWriteType(
  Map<String, Object?> json,
  String key,
  String path, {
  required GatewayWriteType fallback,
}) => readEnum(
  json,
  key,
  path,
  fallback: fallback,
  parse: GatewayWriteType.valueOf,
  choices: 'withResponse 或 withoutResponse',
);

FrameSpan readSpan(
  Map<String, Object?> json,
  String key,
  String path, {
  required FrameSpan fallback,
}) => readEnum(
  json,
  key,
  path,
  fallback: fallback,
  parse: FrameSpan.valueOf,
  choices: 'payload 或 frame',
);

ClockField readClock(Object? value, String path) {
  final clock = ClockField.valueOf(value);
  if (clock == null) {
    throw FormatException('$path 只能是 hour、minute、second 或 unix');
  }
  return clock;
}

ChecksumKind readChecksumKind(Object? value, String path) {
  final kind = ChecksumKind.valueOf(value);
  if (kind == null) throw FormatException('不支持的校验类型：$path');
  return kind;
}
