import 'dart:convert' as convert;
import 'dart:typed_data';

import '../wire_enum.dart';

/// 主题层级：`iot/{version}/{gatewayId}/{leaf}`
///
/// 每个网关只使用三个固定主题，设备识别信息都放在消息体内，
/// 因此主题数量不随 BLE 设备数量增长
enum GatewayTopic implements WireEnum {
  /// 主题根段
  root('iot'),

  /// App 与云端下发请求
  down('down'),

  /// 网关上报响应、事件与状态
  up('up'),

  /// 网关在线状态，使用 retain 与遗嘱消息
  presence('presence');

  const GatewayTopic(this.wire);

  @override
  final String wire;
}

/// 协议帧与消息体使用的字段名
/// 这些键只在拼装或解析 JSON 时通过 [wire] 使用，代码内一律引用枚举
enum GatewayField implements WireEnum {
  v('v'),
  gatewayId('gatewayId'),
  clientId('clientId'),
  ts('ts'),
  messages('messages'),

  // 消息
  type('type'),
  reqId('reqId'),
  op('op'),
  deviceId('deviceId'),
  service('service'),
  char('char'),
  value('value'),
  format('format'),
  timeout('timeout'),
  queueTimeout('queueTimeout'),
  code('code'),
  message('message'),
  data('data'),
  nativeCode('nativeCode'),

  // 网关能力
  maxFrameBytes('maxFrameBytes'),

  // 在线状态
  online('online'),

  // 快照与状态增量
  revision('revision'),
  devices('devices'),
  states('states'),
  connection('connection'),
  rssi('rssi'),
  lastSeen('lastSeen'),
  services('services'),
  uuid('uuid'),
  chars('chars'),
  mac('mac'),
  name('name'),
  addrType('addrType'),
  state('state'),

  // 扫描
  action('action'),
  scanId('scanId'),
  duration('duration'),
  active('active'),

  // 批量与步骤
  steps('steps'),
  id('id'),
  stopOnError('stopOnError'),
  autoConnect('autoConnect'),

  // 连接与订阅参数
  policy('policy'),
  enabled('enabled'),
  mode('mode'),
  delivery('delivery'),
  writeType('writeType'),

  // 网关管理
  registry('registry'),
  device('device'),
  config('config'),

  // 登记对象与运行时状态
  alias('alias'),
  deviceUuid('deviceUuid'),
  addressType('addressType'),
  reportMode('reportMode'),
  intervalMinMs('intervalMinMs'),
  intervalMaxMs('intervalMaxMs'),
  subscriptions('subscriptions'),
  paused('paused'),
  protocolOwned('protocolOwned'),

  // 网络配置
  wifiSsid('wifiSsid'),
  mqttUri('mqttUri'),
  mqttUsername('mqttUsername'),
  wifiPassword('wifiPassword'),
  mqttPassword('mqttPassword'),
  keepWifiPassword('keepWifiPassword'),
  keepMqttPassword('keepMqttPassword'),
  clearWifiPassword('clearWifiPassword'),
  clearMqttPassword('clearMqttPassword'),

  // 备份
  version('version');

  const GatewayField(this.wire);

  @override
  final String wire;
}

class MqttTopics {
  const MqttTopics(this.gatewayId);

  final String gatewayId;

  /// 主题版本段，与 [GatewayFrame.protocolVersion] 保持一致
  static String get versionSegment => 'v${GatewayFrame.protocolVersion}';

  static String prefix(String gatewayId) =>
      '${GatewayTopic.root.wire}/$versionSegment/$gatewayId';

  String get prefixOfGateway => prefix(gatewayId);

  /// App向云端下发请求
  String get down => '$prefixOfGateway/${GatewayTopic.down.wire}';

  /// 网关上报响应、事件与状态
  String get up => '$prefixOfGateway/${GatewayTopic.up.wire}';

  /// 网关在线状态，使用 retain 与遗嘱消息
  String get presence => '$prefixOfGateway/${GatewayTopic.presence.wire}';

  /// App 需要订阅的主题
  List<String> get subscriptions => [up, presence];
}

/// 消息类型
enum GatewayMessageType implements WireEnum {
  request('req'),
  response('res'),
  event('event');

  const GatewayMessageType(this.wire);

  @override
  final String wire;

  static GatewayMessageType? valueOf(Object? raw) =>
      wireValueOf(values, raw);
}

/// BLE 原子操作
enum GatewayOption implements WireEnum {
  scan('scan'),
  connect('connect'),
  disconnect('disconnect'),
  read('read'),
  write('write'),
  subscribe('subscribe'),
  batch('batch'),
  snapshot('snapshot'),
  manage('manage'),
  overflow('overflow'),

  /// 预留能力，App 侧已经按协议第 21 节使用
  waitNotify('waitNotify'),
  discover('discover'),

  /// 网关能力上报事件
  hello('hello'),

  /// 状态增量事件
  state('state'),

  /// Notify 与 Indicate 事件
  notify('notify'),

  /// 连接状态事件
  connection('connection');

  const GatewayOption(this.wire);

  @override
  final String wire;

  static GatewayOption? valueOf(Object? raw) => wireValueOf(values, raw);
}

/// 值编码，默认 hex
enum ValueFormat implements WireEnum {
  hex('hex'),
  base64('base64'),
  utf8('utf8');

  const ValueFormat(this.wire);

  @override
  final String wire;

  static ValueFormat? valueOf(Object? raw) => wireValueOf(values, raw);

  static String encode(List<int> bytes, [ValueFormat format = hex]) =>
      switch (format) {
        base64 => convert.base64.encode(bytes),
        utf8 => convert.utf8.decode(bytes, allowMalformed: true),
        _ => bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(),
      };

  static Uint8List decode(String value, [ValueFormat format = hex]) =>
      switch (format) {
        base64 => convert.base64.decode(value),
        utf8 => Uint8List.fromList(convert.utf8.encode(value)),
        _ => _decodeHex(value),
      };

  static Uint8List _decodeHex(String value) {
    final clean = value.replaceAll(RegExp(r'[\s:-]'), '');
    if (clean.length.isOdd) throw const FormatException('十六进制值长度必须是偶数');
    final bytes = Uint8List(clean.length ~/ 2);
    for (var index = 0; index < bytes.length; index++) {
      final byte = int.tryParse(
        clean.substring(index * 2, index * 2 + 2),
        radix: 16,
      );
      if (byte == null) throw const FormatException('十六进制值包含非法字符');
      bytes[index] = byte;
    }
    return bytes;
  }
}

/// UUID 归一化，支持 16/32/128 位写法
class GatewayUuid {
  const GatewayUuid._();

  static const String sigSuffix = '-0000-1000-8000-00805f9b34fb';

  static String normalize(String uuid) {
    final clean = uuid.trim().toLowerCase().replaceAll('-', '');
    if (!RegExp(r'^[0-9a-f]+$').hasMatch(clean)) {
      throw FormatException('UUID 包含非法字符：$uuid');
    }
    if (clean.length == 4) return '0000$clean$sigSuffix';
    if (clean.length == 8) return '$clean$sigSuffix';
    if (clean.length == 32) {
      return '${clean.substring(0, 8)}-${clean.substring(8, 12)}-${clean.substring(12, 16)}-'
          '${clean.substring(16, 20)}-${clean.substring(20)}';
    }
    throw FormatException('UUID 长度不受支持：$uuid');
  }
}

/// 错误码 底层错误码放在 data.nativeCode
enum GatewayErrorCode {
  ok(0, 'OK'),
  invalidRequest(1001, 'INVALID_REQUEST'),
  unsupportedOp(1002, 'UNSUPPORTED_OP'),
  invalidArgument(1003, 'INVALID_ARGUMENT'),
  gatewayBusy(2001, 'GATEWAY_BUSY'),
  queueTimeout(2002, 'QUEUE_TIMEOUT'),
  connectionLimit(2003, 'CONNECTION_LIMIT'),
  deviceNotFound(3001, 'DEVICE_NOT_FOUND'),
  notConnected(3002, 'NOT_CONNECTED'),
  connectTimeout(3003, 'CONNECT_TIMEOUT'),
  notRegistered(3004, 'NOT_REGISTERED'),
  disconnected(3101, 'DISCONNECTED'),
  serviceNotFound(4001, 'SERVICE_NOT_FOUND'),
  characteristicNotFound(4002, 'CHAR_NOT_FOUND'),
  batchFailed(4003, 'BATCH_FAILED'),
  readFailed(4101, 'READ_FAILED'),
  writeFailed(4201, 'WRITE_FAILED'),
  subscribeFailed(4301, 'SUBSCRIBE_FAILED'),
  gattTimeout(4901, 'GATT_TIMEOUT'),
  skipped(4999, 'SKIPPED'),

  /// 未在协议中声明的错误码
  unknown(-1, 'UNKNOWN_ERROR');

  const GatewayErrorCode(this.code, this.label);

  /// 协议中的数值错误码
  final int code;

  /// 面向日志与界面的英文名
  final String label;

  static GatewayErrorCode of(int? code) {
    for (final value in values) {
      if (value != unknown && value.code == code) return value;
    }
    return unknown;
  }

  static String labelOf(int? code) => of(code).label;
}

/// 网关返回的错误，App 按错误码判断处理方式
class GatewayError implements Exception {
  /// 用协议里声明过的错误码构造
  GatewayError(GatewayErrorCode kind, this.message, {this.nativeCode})
    : kind = kind,
      code = kind.code;

  /// 用帧里读到的数值错误码构造，未声明过的码归入 [GatewayErrorCode.unknown]
  GatewayError.fromCode(this.code, this.message, {this.nativeCode})
    : kind = GatewayErrorCode.of(code);

  /// 协议里的数值错误码，未声明过的码原样保留
  final int code;

  /// [code] 对应的稳定错误码
  final GatewayErrorCode kind;

  final String message;

  /// 底层固件错误码，只能用于日志
  final int? nativeCode;

  bool get isQueueTimeout => kind == GatewayErrorCode.queueTimeout;

  bool get isNotConnected =>
      kind == GatewayErrorCode.notConnected ||
      kind == GatewayErrorCode.disconnected;

  bool get isTimeout =>
      kind == GatewayErrorCode.gattTimeout ||
      kind == GatewayErrorCode.connectTimeout;

  @override
  String toString() => '网关错误 $code（${kind.label}）：$message';
}


/// Notify 投递模式
enum GatewayDelivery implements WireEnum {
  stream('stream'),
  latest('latest');

  const GatewayDelivery(this.wire);

  @override
  final String wire;

  static GatewayDelivery? valueOf(Object? raw) => wireValueOf(values, raw);
}

/// Notify / Indicate 通知模式
enum GatewayNotifyMode implements WireEnum {
  auto('auto'),
  notify('notify'),
  indicate('indicate');

  const GatewayNotifyMode(this.wire);

  @override
  final String wire;

  static GatewayNotifyMode? valueOf(Object? raw) => wireValueOf(values, raw);
}

/// 写入方式
enum GatewayWriteType implements WireEnum {
  withResponse('withResponse'),
  withoutResponse('withoutResponse');

  const GatewayWriteType(this.wire);

  @override
  final String wire;

  static GatewayWriteType? valueOf(Object? raw) => wireValueOf(values, raw);
}

/// 连接时对网关调度队列的处理策略
enum GatewayConnectPolicy implements WireEnum {
  queue('queue'),
  reject('reject');

  const GatewayConnectPolicy(this.wire);

  @override
  final String wire;

  static GatewayConnectPolicy? valueOf(Object? raw) =>
      wireValueOf(values, raw);
}

/// 扫描动作
enum GatewayScanAction implements WireEnum {
  start('start'),
  stop('stop');

  const GatewayScanAction(this.wire);

  @override
  final String wire;

  static GatewayScanAction? valueOf(Object? raw) => wireValueOf(values, raw);
}

/// 网关登记里的设备模式
enum GatewayDeviceMode implements WireEnum {
  /// 由网关维持 BLE 连接，App 可以读写
  connection('connection'),

  /// 只监听广播，不建立连接
  broadcast('broadcast'),

  /// 走通用设备配置声明的读写通道
  generic('generic');

  const GatewayDeviceMode(this.wire);

  @override
  final String wire;

  bool get isBroadcast => this == broadcast;

  bool get isGeneric => this == generic;

  static GatewayDeviceMode? valueOf(Object? raw) =>
      wireValueOf(values, raw);
}

/// BLE 地址类型，登记对象里用数值书写，扫描结果里用文本
enum GatewayAddressType implements WireEnum {
  public('public'),
  random('random');

  const GatewayAddressType(this.wire);

  @override
  final String wire;

  /// 登记对象里的数值写法
  int get code => this == random ? 1 : 0;

  static GatewayAddressType? valueOf(Object? raw) =>
      wireValueOf(values, raw);

  static GatewayAddressType? fromJson(Object? raw) => switch (raw) {
    int value => value == random.code ? random : public,
    _ => valueOf(raw),
  };
}

/// 网关管理动作
enum GatewayManageAction implements WireEnum {
  status('status'),
  upsert('upsert'),
  remove('remove'),
  backup('backup'),
  save('save'),
  pause('pause'),
  resume('resume'),
  seen('seen'),
  diagnostics('diagnostics'),
  configGet('config.get'),
  configSet('config.set'),
  restart('restart');

  const GatewayManageAction(this.wire);

  @override
  final String wire;

  static GatewayManageAction? valueOf(Object? raw) =>
      wireValueOf(values, raw);
}

/// 单条消息
class GatewayMessage {
  const GatewayMessage({
    this.version = 1,
    this.reqId,
    required this.type,
    required this.op,
    this.deviceId,
    this.service,
    this.characteristic,
    this.value,
    this.format,
    this.timeout,
    this.queueTimeout,
    this.code,
    this.message,
    this.data,
    this.ts,
  });

  factory GatewayMessage.request({
    int version = 1,
    required GatewayOption op,
    String? reqId,
    String? deviceId,
    String? service,
    String? characteristic,
    String? value,
    ValueFormat? format,
    int? timeout,
    int? queueTimeout,
    Map<String, Object?>? data,
  }) => GatewayMessage(
    version: version,
    type: GatewayMessageType.request,
    reqId: reqId,
    op: op,
    deviceId: deviceId,
    service: service,
    characteristic: characteristic,
    value: value,
    format: format,
    timeout: timeout,
    queueTimeout: queueTimeout,
    data: data,
  );

  /// 消息版本，固定为 1
  final int version;
  final GatewayMessageType type;
  final String? reqId;
  final GatewayOption op;
  final String? deviceId;
  final String? service;
  final String? characteristic;
  final String? value;
  final ValueFormat? format;

  /// BLE 操作执行超时，毫秒
  final int? timeout;

  /// 调度队列等待超时，毫秒
  final int? queueTimeout;
  final int? code;
  final String? message;
  final Map<String, Object?>? data;
  final int? ts;

  bool get isRequest => type == GatewayMessageType.request;

  bool get isResponse => type == GatewayMessageType.response;

  bool get isEvent => type == GatewayMessageType.event;

  /// 非 0 错误码转换出的异常对象
  GatewayError? get error {
    final value = code;
    if (value == GatewayErrorCode.ok.code) return null;
    // 没有 code 的响应按无效请求处理，与缺字段的语义一致
    if (value == null) {
      return GatewayError(
        GatewayErrorCode.invalidRequest,
        '响应缺少 code',
        nativeCode: _nativeCode,
      );
    }
    return GatewayError.fromCode(
      value,
      message ?? GatewayErrorCode.of(value).label,
      nativeCode: _nativeCode,
    );
  }

  /// 固件自带的错误码，只在日志里出现
  int? get _nativeCode => data?[GatewayField.nativeCode.wire] is int
      ? data![GatewayField.nativeCode.wire] as int
      : null;

  /// 批量执行结果中的步骤，对应协议第 20 节
  List<GatewayStepResult> get steps {
    final raw = data?[GatewayField.steps.wire];
    if (raw is! List) return const [];
    return [
      for (final step in raw)
        if (step is Map<String, dynamic>) GatewayStepResult.fromJson(step),
    ];
  }

  Map<String, Object?> toJson() => {
    GatewayField.v.wire: version,
    GatewayField.type.wire: type.wire,
    if (reqId != null) GatewayField.reqId.wire: reqId,
    GatewayField.op.wire: op.wire,
    if (deviceId != null) GatewayField.deviceId.wire: deviceId,
    if (service != null) GatewayField.service.wire: service,
    if (characteristic != null) GatewayField.char.wire: characteristic,
    if (value != null) GatewayField.value.wire: value,
    if (format != null) GatewayField.format.wire: format!.wire,
    if (timeout != null) GatewayField.timeout.wire: timeout,
    if (queueTimeout != null) GatewayField.queueTimeout.wire: queueTimeout,
    if (code != null) GatewayField.code.wire: code,
    if (message != null) GatewayField.message.wire: message,
    if (data != null) GatewayField.data.wire: data,
    if (ts != null) GatewayField.ts.wire: ts,
  };

  factory GatewayMessage.fromJson(Map<String, dynamic> json) {
    final rawVersion = json[GatewayField.v.wire];
    if (rawVersion != null &&
        (rawVersion is! int || rawVersion != GatewayFrame.protocolVersion)) {
      throw FormatException('不支持的消息版本：$rawVersion');
    }
    final version = rawVersion as int? ?? GatewayFrame.protocolVersion;
    final type = GatewayMessageType.valueOf(json[GatewayField.type.wire]);
    if (type == null) {
      throw FormatException('未知的消息类型：${json[GatewayField.type.wire]}');
    }
    final op = GatewayOption.valueOf(json[GatewayField.op.wire]);
    if (op == null) {
      throw FormatException('未知操作：${json[GatewayField.op.wire]}');
    }
    final rawData = json[GatewayField.data.wire];
    return GatewayMessage(
      version: version,
      type: type,
      reqId: _string(json[GatewayField.reqId.wire]),
      op: op,
      deviceId: _string(json[GatewayField.deviceId.wire]),
      service: _string(json[GatewayField.service.wire]),
      characteristic: _string(json[GatewayField.char.wire]),
      value: _string(json[GatewayField.value.wire]),
      format: ValueFormat.valueOf(json[GatewayField.format.wire]),
      timeout: _integer(json[GatewayField.timeout.wire]),
      queueTimeout: _integer(json[GatewayField.queueTimeout.wire]),
      code: _integer(json[GatewayField.code.wire]),
      message: _string(json[GatewayField.message.wire]),
      data: rawData is Map<String, dynamic> ? rawData : null,
      ts: _integer(json[GatewayField.ts.wire]),
    );
  }

  GatewayMessage copyWith({
    int? version,
    GatewayMessageType? type,
    String? reqId,
    GatewayOption? op,
    String? deviceId,
    String? service,
    String? characteristic,
    String? value,
    ValueFormat? format,
    int? timeout,
    int? queueTimeout,
    int? code,
    String? message,
    Map<String, Object?>? data,
    int? ts,
  }) {
    return GatewayMessage(
      version: version ?? this.version,
      type: type ?? this.type,
      reqId: reqId ?? this.reqId,
      op: op ?? this.op,
      deviceId: deviceId ?? this.deviceId,
      service: service ?? this.service,
      characteristic: characteristic ?? this.characteristic,
      value: value ?? this.value,
      format: format ?? this.format,
      timeout: timeout ?? this.timeout,
      queueTimeout: queueTimeout ?? this.queueTimeout,
      code: code ?? this.code,
      message: message ?? this.message,
      data: data ?? this.data,
      ts: ts ?? this.ts,
    );
  }


}

String? _string(Object? value) => value is String ? value : null;

int? _integer(Object? value) => value is int ? value : null;

class GatewayStepResult {
  const GatewayStepResult({
    required this.id,
    required this.code,
    this.message,
    this.value,
    this.format,
  });

  final String id;
  final int code;
  final String? message;
  final String? value;
  final ValueFormat? format;

  GatewayErrorCode get kind => GatewayErrorCode.of(code);

  bool get ok => kind == GatewayErrorCode.ok;

  bool get skipped => kind == GatewayErrorCode.skipped;

  factory GatewayStepResult.fromJson(Map<String, dynamic> json) =>
      GatewayStepResult(
        id: _string(json[GatewayField.id.wire]) ?? '',
        code:
            _integer(json[GatewayField.code.wire]) ??
            GatewayErrorCode.invalidRequest.code,
        message: _string(json[GatewayField.message.wire]),
        value: _string(json[GatewayField.value.wire]),
        format: ValueFormat.valueOf(json[GatewayField.format.wire]),
      );

  GatewayError? get error =>
      ok ? null : GatewayError.fromCode(code, message ?? kind.label);
}

/// 一条 MQTT 或 WebSocket 帧，可以携带多条独立消息
class GatewayFrame {
  const GatewayFrame({
    required this.gatewayId,
    required this.messages,
    this.clientId = '',
    this.ts,
    this.version = protocolVersion,
  });

  static const int protocolVersion = 1;

  final int version;
  final String gatewayId;
  final String clientId;
  final int? ts;
  final List<GatewayMessage> messages;

  Map<String, Object?> toJson() => {
    GatewayField.v.wire: version,
    GatewayField.gatewayId.wire: gatewayId,
    if (clientId.isNotEmpty) GatewayField.clientId.wire: clientId,
    if (ts != null) GatewayField.ts.wire: ts,
    GatewayField.messages.wire: [
      for (final message in messages) message.toJson(),
    ],
  };

  String encode() => convert.jsonEncode(toJson());

  /// 解析帧，版本、必填字段或消息类型非法时抛出 [FormatException]
  factory GatewayFrame.decode(String payload) {
    final decoded = convert.jsonDecode(payload);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('协议帧必须是 JSON 对象');
    }
    return GatewayFrame.fromJson(decoded);
  }

  factory GatewayFrame.fromJson(Map<String, dynamic> json) {
    final version = json[GatewayField.v.wire];
    if (version != protocolVersion) throw FormatException('不支持的协议版本：$version');
    final gatewayId = json[GatewayField.gatewayId.wire];
    if (gatewayId is! String || gatewayId.isEmpty) {
      throw const FormatException('协议帧缺少 gatewayId');
    }
    final rawMessages = json[GatewayField.messages.wire];
    if (rawMessages is! List) throw const FormatException('协议帧缺少 messages 数组');
    final clientId = json[GatewayField.clientId.wire];
    final ts = json[GatewayField.ts.wire];
    return GatewayFrame(
      gatewayId: gatewayId,
      clientId: clientId is String ? clientId : '',
      ts: ts is int ? ts : null,
      messages: [
        for (final raw in rawMessages)
          raw is Map<String, dynamic>
              ? GatewayMessage.fromJson(raw)
              : throw const FormatException('messages 必须是对象数组'),
      ],
    );
  }
}
