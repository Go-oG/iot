import 'dart:typed_data';

import 'package:light/src/core/functions/fan_speed.dart';
import 'package:light/src/core/functions/light.dart';

import 'protocol.dart';

enum RemoteConnection { disconnected, connecting, connected }

/// 一次业务操作的类别，随下发请求一起进入设备编解码器
enum DeviceCommand implements WireEnum {
  /// 整机状态：五路亮度、电源、温度与风速
  setState('set_state'),

  /// 只调整输出上限
  setLimit('set_limit'),

  /// 写入一个定时槽位
  setTimer('set_timer');

  const DeviceCommand(this.wire);

  @override
  final String wire;

  static DeviceCommand? valueOf(Object? raw) => wireValueOf(values, raw);
}

/// 整机状态下发的字段名
///
/// [DeviceCommand.setState] 与 [DeviceCommand.setLimit] 共用一个负载结构。
enum DeviceStateField implements WireEnum {
  channels('channels'),
  power('power'),
  temperature('temperature'),
  fanSpeed('fanSpeed'),
  outputLimit('outputLimit');

  const DeviceStateField(this.wire);

  @override
  final String wire;
}

/// 一次下发携带的整机状态
///
/// App 侧用它拼出下发负载，设备编解码器再从负载还原成同一结构。
class DeviceStatePayload {
  const DeviceStatePayload({
    required this.channels,
    required this.power,
    required this.temperature,
    required this.fanSpeed,
    this.outputLimit = 100,
  });

  final LightState channels;
  final bool power;
  final int temperature;
  final FanSpeed fanSpeed;

  /// 每路亮度的上限，只有 App 的本地预览使用
  final int outputLimit;

  Map<String, Object?> toJson() => {
    DeviceStateField.channels.wire: channels.toJson(),
    DeviceStateField.power.wire: power,
    DeviceStateField.temperature.wire: temperature,
    DeviceStateField.fanSpeed.wire: fanSpeed.value,
    DeviceStateField.outputLimit.wire: outputLimit,
  };

  /// 负载不符合设备约定时抛出 [RemoteCommandRejected]
  factory DeviceStatePayload.fromJson(Map<String, Object?> json) {
    final raw = json[DeviceStateField.channels.wire];
    if (raw is! Map) {
      throw RemoteCommandRejected(
        '缺少 ${DeviceStateField.channels.wire} 字段',
        code: GatewayErrorCode.invalidArgument,
      );
    }
    int channel(LightChannel key) => _integerInRange(
      raw[key.wire],
      0,
      100,
      '${DeviceStateField.channels.wire}.${key.wire}',
    );
    return DeviceStatePayload(
      channels: LightState(
        red: channel(LightChannel.red),
        green: channel(LightChannel.green),
        blue: channel(LightChannel.blue),
        white: channel(LightChannel.white),
        uv: channel(LightChannel.uv),
      ),
      temperature: _integerInRange(
        json[DeviceStateField.temperature.wire],
        20,
        80,
        DeviceStateField.temperature.wire,
      ),
      fanSpeed:
          FanSpeed.fromValue(
            _integerInRange(
              json[DeviceStateField.fanSpeed.wire],
              1,
              2,
              DeviceStateField.fanSpeed.wire,
            ),
          ) ??
          FanSpeed.low,
      power: _boolean(
        json[DeviceStateField.power.wire],
        DeviceStateField.power.wire,
      ),
      outputLimit:
          json[DeviceStateField.outputLimit.wire] as int? ?? 100,
    );
  }

  static int _integerInRange(Object? value, int min, int max, String name) {
    if (value is! int || value < min || value > max) {
      throw RemoteCommandRejected(
        '$name 必须是 $min-$max 的整数',
        code: GatewayErrorCode.invalidArgument,
      );
    }
    return value;
  }

  static bool _boolean(Object? value, String name) {
    if (value is! bool) {
      throw RemoteCommandRejected(
        '$name 必须是布尔值',
        code: GatewayErrorCode.invalidArgument,
      );
    }
    return value;
  }
}

/// 一条业务操作的确认程度，随下发结果回到界面
enum RemoteConfirmation implements WireEnum {
  /// 只有写入成功，没有任何设备回报
  written('written'),

  /// 收到设备的协议确认
  deviceAck('device_ack'),

  /// 设备直接回报了状态
  deviceState('device_state'),

  /// 设备明确拒绝了本次命令
  ack('ack');

  const RemoteConfirmation(this.wire);

  @override
  final String wire;

  static RemoteConfirmation? valueOf(Object? raw) =>
      wireValueOf(values, raw);
}

/// 批量请求里的步骤标识
///
/// 标识由 App 生成，网关只把它原样回传，用于把批量结果对回本地请求。
enum RemoteStep implements WireEnum {
  /// 订阅步骤，同一次批量里的多条订阅用序号区分
  subscribe('sub'),

  /// 写步骤，同一次批量里的多条写入用命令名区分
  write('w');

  const RemoteStep(this.wire);

  @override
  final String wire;

  /// `sub`、`sub0`、`sub1`……
  String indexed([int index = -1]) => index < 0 ? wire : '$wire$index';

  /// `w:setPower`
  String named(String commandName) => '$wire:$commandName';
}

class RemoteCommandRejected extends StateError {
  RemoteCommandRejected(this.reason, {this.code})
    : super(
        code == null
            ? '设备拒绝执行：$reason'
            : '设备拒绝执行：$reason（${code.label}）',
      );

  final String reason;
  final GatewayErrorCode? code;
}

/// App 本地维护的灯具状态
///
/// 新协议下网关只做 BLE 原子操作，灯具业务状态由 App 根据写入内容和灯具确认推得，
/// 因此 bootId 与 revision 都是 App 本地序列，只用于忽略乱序更新
class ReportedLightState {
  const ReportedLightState({
    required this.light,
    required this.power,
    required this.temperature,
    required this.fanSpeed,
    required this.outputLimit,
    required this.timestamp,
    required this.revision,
    required this.bootId,
    required this.confirmation,
  });

  final LightState light;
  final bool power;
  final int temperature;
  final FanSpeed fanSpeed;
  final int outputLimit;
  final DateTime timestamp;
  final int revision;

  /// 状态纪元，App 每次重新建立远程控制会话时更新
  final String bootId;
  final RemoteConfirmation confirmation;
}

class RemoteSnapshot {
  const RemoteSnapshot({
    this.connection = RemoteConnection.disconnected,
    this.deviceOnline = false,
    this.lampConnected = false,
    this.state,
    this.lastSeen,
    this.message,
  });

  final RemoteConnection connection;

  /// 网关是否在线
  final bool deviceOnline;

  /// 灯具是否已被网关连接并确认可读写
  final bool lampConnected;
  final ReportedLightState? state;
  final DateTime? lastSeen;
  final String? message;

  bool get canControl =>
      connection == RemoteConnection.connected && deviceOnline && lampConnected;
}

class RemoteCommandResult {
  const RemoteCommandResult({
    required this.commandId,
    required this.confirmation,
  });
  final String commandId;
  final RemoteConfirmation confirmation;
}

/// 一台设备在远端通道上的写步骤
///
/// 帧由设备自己生成，网关只负责把十六进制报文写到对应的服务与特征上。
class RemoteWriteStep {
  const RemoteWriteStep({
    required this.id,
    required this.service,
    required this.characteristic,
    required this.bytes,
    this.writeType = GatewayWriteType.withResponse,
  });

  final String id;
  final String service;
  final String characteristic;
  final Uint8List bytes;
  final GatewayWriteType writeType;

  Map<String, Object?> toJson() => {
    GatewayField.id.wire: id,
    GatewayField.op.wire: GatewayOption.write.wire,
    GatewayField.service.wire: service,
    GatewayField.char.wire: characteristic,
    GatewayField.value.wire: ValueFormat.encode(bytes),
    GatewayField.format.wire: ValueFormat.hex.wire,
    GatewayField.data.wire: {GatewayField.writeType.wire: writeType.wire},
  };
}

/// 设备对一条命令的回应
class RemoteDecodedFrame {
  const RemoteDecodedFrame({required this.commandByte, required this.accepted});

  final int commandByte;
  final bool accepted;
}

/// 设备自己的远端编解码
///
/// 会话通过它把业务操作翻译成写步骤，并从通知报文里认出属于自己的确认。
/// 具体协议只属于具体设备，传输层不参与任何解析。
abstract interface class RemoteDeviceCodec {
  /// 命令对应的服务与特征
  String get remoteService;

  String get remoteCharacteristic;

  /// 把一次业务操作编码成一组写步骤
  List<RemoteWriteStep> buildRemoteSteps(
    DeviceCommand command,
    Map<String, Object?> payload,
  );

  /// 解析一帧通知报文
  ///
  /// 无法归属到本设备的报文返回 null。
  RemoteDecodedFrame? decodeRemoteFrame(Uint8List bytes, {String? format});
}

/// 一台设备在远端通道上的会话
///
/// 由设备管理方（AppController）创建并在设备切换时替换：会话订阅属于本设备
/// 的网关事件、解码回应并维护自己的下发状态。具体设备怎么下发由会话自己定义
/// （AT5 用 `execute(command, payload)`，通用设备用功能回调），管理方只关心它是否就绪。
abstract interface class RemoteDeviceSession {
  /// 是否已经具备下发条件
  bool get ready;

  /// 按设备命令下发一次业务操作
  Future<RemoteCommandResult> execute(
    DeviceCommand command,
    Map<String, Object?> payload,
  );

  Future<void> dispose();
}
