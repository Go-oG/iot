import 'dart:async';
import 'dart:typed_data';

import 'package:light/src/core/device/device.dart';
import 'package:light/src/core/functions/fan_speed.dart';
import 'package:light/src/core/functions/light.dart';
import 'package:light/src/core/functions/power.dart';
import 'package:light/src/core/functions/temperature.dart';

import '../../functions/timer.dart';
import '../../protocol/protocol.dart';
import '../../protocol/remote_protocol.dart';
import '../../response.dart';

/// AT5 远端下发里的固定写步骤标识
enum At5Step implements WireEnum {
  brightness('brightness'),
  temperatureFan('temperatureFan'),
  power('power'),
  syncTime('syncTime'),
  timer('timer');

  const At5Step(this.wire);

  @override
  final String wire;
}

class At5Status {
  int temperature = 31;
  FanSpeed fanSpeed = FanSpeed.low;
}

class At5Client extends Device<At5Status>  {
  At5Client({
    this.id = 'at5',
    this.name = 'AT5 智能灯',
    this._write,
    this._disconnect,
  });

  final Future<void> Function(Uint8List packet)? _write;
  final Future<void> Function()? _disconnect;

  @override
  final String id;

  @override
  final String name;

  final At5Status _lastWrittenStatus = At5Status();

  static const String serviceUuid = '8332af20-6d0e-4eea-bb35-665544332211';
  static const String characteristicUuid =
      '8332af20-6d0e-4eea-bb35-665544332211';

  /// 手机 -> AT5
  static const List<int> requestHeader = [0x34, 0x43, 0x88, 0x88];

  /// AT5 -> 手机
  static const List<int> responseHeader = [0x43, 0x34, 0x88, 0x88];

  static const int commandSyncTime = 0x01;
  static const int commandBrightness = 0x03;
  static const int commandTimer = 0x04;
  static const int commandPower = 0x05;
  static const int commandTemperatureFan = 0x06;

  @override
  FutureOr<At5Status> onInit() => _lastWrittenStatus;

  /// CMD 0x05
  /// Payload:
  /// 00 = 关闭
  /// 01 = 开启
  Uint8List setPower(bool enabled) {
    return _buildRequest(
      command: commandPower,
      payload: [enabled ? 0x01 : 0x00],
    );
  }

  /// 同步时间 CMD 0x01
  /// Payload:
  /// HH MM SS
  Uint8List syncTime(DateTime time) {
    return _buildRequest(
      command: commandSyncTime,
      payload: [time.hour, time.minute, time.second],
    );
  }

  /// 设置亮度 CMD 0x03
  ///
  /// Payload:
  ///
  /// RED GREEN BLUE WHITE UV
  ///
  /// 每一路直接使用 0~100 百分比值
  Uint8List setBrightness({
    required int red,
    required int green,
    required int blue,
    required int white,
    required int uv,
  }) {
    return _buildRequest(
      command: commandBrightness,
      payload: [
        _percent(red),
        _percent(green),
        _percent(blue),
        _percent(white),
        _percent(uv),
      ],
    );
  }

  Uint8List setLightState(LightState state) {
    return setBrightness(
      red: state.red,
      green: state.green,
      blue: state.blue,
      white: state.white,
      uv: state.uv,
    );
  }

  ///设置定时 / 日出 / 日落 CMD 0x04
  ///
  /// Payload:
  ///
  /// [0] TIMER_INDEX
  /// [1] TIMER_ENABLED
  /// [2] START_HOUR
  /// [3] START_MINUTE
  /// [4] END_HOUR
  /// [5] END_MINUTE
  /// [6] SUNRISE_SUNSET_ENABLED
  /// [7] SUNRISE_MINUTES
  /// [8] SUNSET_MINUTES
  Uint8List setTimer(TimerConfig config) {
    _validateTimer(config);

    return _buildRequest(
      command: commandTimer,
      payload: [
        config.index,
        config.enabled ? 0x01 : 0x00,
        config.startHour,
        config.startMinute,
        config.endHour,
        config.endMinute,
        config.sunriseSunsetEnabled ? 0x01 : 0x00,
        config.sunriseMinutes,
        config.sunsetMinutes,
      ],
    );
  }

  /// 单独修改温控目标温度 AT5 的 CMD 0x06 必须同时发送：
  /// TEMP + FAN_SPEED
  /// 因此这里会自动带上当前 [_lastWrittenStatus] 中的风扇档位
  Uint8List setTemperature(int temperature) {
    return setTemperatureAndFan(
      temperature: temperature,
      fanSpeed: _lastWrittenStatus.fanSpeed,
    );
  }

  /// 单独修改风扇档位
  /// 当前确认：
  /// 01 = 低速
  /// 02 = 高速
  /// 会自动带上当前 [_lastWrittenStatus] 中的温度
  Uint8List setFanSpeed(FanSpeed speed) {
    return setTemperatureAndFan(
      temperature: _lastWrittenStatus.temperature,
      fanSpeed: speed,
    );
  }

  Uint8List setTemperatureAndFan({
    required int temperature,
    required FanSpeed fanSpeed,
  }) {
    return _buildRequest(
      command: commandTemperatureFan,
      payload: [_temperatureValue(temperature), fanSpeed.value],
    );
  }

  /// 解析 AT5 -> 手机的 BLE Notify / Indicate 数据
  /// 响应帧：43 34 88 88
  /// CMD 00
  /// LENGTH
  /// PAYLOAD...
  /// CRC_H
  /// CRC_L
  /// 如果数据非法，会抛出 [FormatException]。
  static ClientResponse parseResponse(List<int> bytes) {
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);

    // 最短帧：
    //
    // Header 4
    // CMD 1
    // Reserved 1
    // Length 1
    // CRC 2
    //
    // 总计 9 bytes
    if (data.length < 9) {
      throw FormatException('AT5 响应长度过短：${data.length}');
    }

    if (data[0] != responseHeader[0] ||
        data[1] != responseHeader[1] ||
        data[2] != responseHeader[2] ||
        data[3] != responseHeader[3]) {
      throw FormatException('无效的 AT5 响应帧头：${toHex(data)}');
    }

    final command = data[4];

    /// 当前已确认该字节固定为 0。
    final reserved = data[5];

    if (reserved != 0x00) {
      throw FormatException(
        '未知 Reserved 字段：0x'
        '${reserved.toRadixString(16).padLeft(2, '0')}',
      );
    }

    final payloadLength = data[6];

    final expectedLength =
        4 + // Header
        1 + // CMD
        1 + // Reserved
        1 + // Length
        payloadLength +
        2; // CRC

    if (data.length != expectedLength) {
      throw FormatException(
        'AT5 响应长度不匹配：'
        '声明 Payload=$payloadLength，'
        '应为 $expectedLength bytes，'
        '实际 ${data.length} bytes',
      );
    }

    final payloadStart = 7;
    final payloadEnd = payloadStart + payloadLength;

    final payload = Uint8List.fromList(data.sublist(payloadStart, payloadEnd));

    /// AT5 CRC 在线上传输顺序：
    ///
    /// High -> Low
    final receivedCrc = (data[payloadEnd] << 8) | data[payloadEnd + 1];

    final calculatedCrc = crc16Modbus(data, length: payloadEnd);

    if (receivedCrc != calculatedCrc) {
      throw FormatException(
        'AT5 CRC 校验失败：'
        'received=0x'
        '${receivedCrc.toRadixString(16).padLeft(4, '0').toUpperCase()}, '
        'calculated=0x'
        '${calculatedCrc.toRadixString(16).padLeft(4, '0').toUpperCase()}',
      );
    }

    return ClientResponse(
      type: _resolveResponseType(command, payload),
      command: command,
      payload: payload,
      rawData: Uint8List.fromList(data),
      receivedCrc: receivedCrc,
      calculatedCrc: calculatedCrc,
    );
  }

  static ResponseType _resolveResponseType(int command, Uint8List payload) {
    switch (command) {
      case commandBrightness:
      case commandTimer:
      case commandPower:
      case commandTemperatureFan:
        if (payload.length == 1) {
          return ResponseType.ack;
        }
        return ResponseType.unknown;
      case commandSyncTime:

        /// 抓包中已经观察到：
        /// 43 34 88 88 01 00 08
        /// xx xx xx xx xx xx xx xx
        /// CRC
        /// 暂时定义为设备状态
        if (payload.length == 8) {
          return ResponseType.deviceStatus;
        }
        return ResponseType.unknown;
      default:
        return ResponseType.unknown;
    }
  }

  /// 手机 -> AT5：34 43 88 88
  /// CMD
  /// 00
  /// LENGTH
  /// PAYLOAD...
  /// CRC_H
  /// CRC_L
  Uint8List _buildRequest({required int command, required List<int> payload}) {
    final result = Uint8List(7 + payload.length + 2);

    var offset = 0;
    result[offset++] = requestHeader[0];
    result[offset++] = requestHeader[1];
    result[offset++] = requestHeader[2];
    result[offset++] = requestHeader[3];
    result[offset++] = command;

    /// Reserved
    result[offset++] = 0x00;
    result[offset++] = payload.length;

    for (final value in payload) {
      result[offset++] = value & 0xFF;
    }

    final crc = crc16Modbus(result, length: offset);
    result[offset++] = (crc >> 8) & 0xFF;
    result[offset] = crc & 0xFF;
    return result;
  }

  /// poly    = 0xA001
  /// init    = 0xFFFF
  /// xorout  = 0
  ///
  /// AT5 在线上传输 CRC 时使用：
  ///
  /// CRC_H -> CRC_L
  static int crc16Modbus(List<int> data, {int? length}) {
    var crc = 0xFFFF;
    final end = length ?? data.length;
    for (var i = 0; i < end; i++) {
      crc ^= data[i];
      for (var bit = 0; bit < 8; bit++) {
        if ((crc & 0x0001) != 0) {
          crc = (crc >> 1) ^ 0xA001;
        } else {
          crc >>= 1;
        }
      }
    }
    return crc & 0xFFFF;
  }

  static int _percent(int value) => value.clamp(0, 100);

  static int _temperatureValue(int value) => value.clamp(0, 255);

  static void _validateTimer(TimerConfig config) {
    if (config.index != 1 && config.index != 2) {
      throw ArgumentError.value(config.index, 'index', '只能是 1 或 2');
    }

    if (config.startHour < 0 || config.startHour > 23) {
      throw ArgumentError.value(config.startHour, 'startHour');
    }

    if (config.endHour < 0 || config.endHour > 23) {
      throw ArgumentError.value(config.endHour, 'endHour');
    }

    if (config.startMinute < 0 || config.startMinute > 59) {
      throw ArgumentError.value(config.startMinute, 'startMinute');
    }

    if (config.endMinute < 0 || config.endMinute > 59) {
      throw ArgumentError.value(config.endMinute, 'endMinute');
    }

    if (config.sunriseMinutes < 0 || config.sunriseMinutes > 255) {
      throw ArgumentError.value(config.sunriseMinutes, 'sunriseMinutes');
    }

    if (config.sunsetMinutes < 0 || config.sunsetMinutes > 255) {
      throw ArgumentError.value(config.sunsetMinutes, 'sunsetMinutes');
    }
  }

  @override
  List<BleServiceDesc> bleServices() {
    return [
      BleServiceDesc(
        uuid: serviceUuid,
        name: '灯光控制',
        characteristicList: [
          CharacteristicDesc(uuid: characteristicUuid, name: "灯光控制"),
        ],
      ),
    ];
  }

  // ---- 远端通道上的 AT5 编解码 ----
  //
  // 报文由这里生成、也由这里解析；传输层只负责把十六进制写进对应特征并回传通知。

  @override
  String get remoteService => serviceUuid;

  @override
  String get remoteCharacteristic => characteristicUuid;

  @override
  List<RemoteWriteStep> buildRemoteSteps(
    DeviceCommand command,
    Map<String, Object?> payload,
  ) {
    switch (command) {
      case DeviceCommand.setState:
      case DeviceCommand.setLimit:
        final state = DeviceStatePayload.fromJson(payload);
        final channels = state.channels;
        return [
          RemoteWriteStep(
            id: At5Step.brightness.wire,
            service: serviceUuid,
            characteristic: characteristicUuid,
            bytes: setBrightness(
              red: channels.red,
              green: channels.green,
              blue: channels.blue,
              white: channels.white,
              uv: channels.uv,
            ),
          ),
          RemoteWriteStep(
            id: At5Step.temperatureFan.wire,
            service: serviceUuid,
            characteristic: characteristicUuid,
            bytes: setTemperatureAndFan(
              temperature: state.temperature,
              fanSpeed: state.fanSpeed,
            ),
          ),
          RemoteWriteStep(
            id: At5Step.power.wire,
            service: serviceUuid,
            characteristic: characteristicUuid,
            bytes: setPower(state.power),
          ),
        ];
      case DeviceCommand.setTimer:
        final config = TimerConfig.fromJson(payload);
        return [
          RemoteWriteStep(
            id: At5Step.syncTime.wire,
            service: serviceUuid,
            characteristic: characteristicUuid,
            bytes: syncTime(DateTime.now()),
          ),
          RemoteWriteStep(
            id: At5Step.timer.wire,
            service: serviceUuid,
            characteristic: characteristicUuid,
            bytes: setTimer(config),
          ),
        ];
    }
  }

  @override
  RemoteDecodedFrame? decodeRemoteFrame(Uint8List bytes, {String? format}) {
    final response = parseResponse(bytes);
    if (!response.isAck) return null;
    return RemoteDecodedFrame(
      commandByte: response.command,
      accepted: response.success != false,
    );
  }

  @override
  Future<bool> onConnection() async {
    final write = _write;
    if (write == null) throw StateError('设备未配置传输通道');
    await write(syncTime(DateTime.now()));
    return true;
  }

  @override
  Future<bool> onDisConnection() async {
    await _disconnect?.call();
    return true;
  }

  Future<bool> _send(Uint8List packet) async {
    if (!isConnection || _write == null) throw StateError('请先连接设备');
    await _write(packet);
    return true;
  }

  Future<bool> _setTemperatureFan(int temperature, FanSpeed speed) async {
    final target = _temperatureValue(temperature);
    await _send(setTemperatureAndFan(temperature: target, fanSpeed: speed));
    status.temperature = target;
    status.fanSpeed = speed;
    function<TemperatureFunction>()?.status = target.toDouble();
    function<FanSpeedFunction>()?.status = speed;
    function<TemperatureFanFunction>()?.status = TemperatureFanState(
      temperature: target,
      fanSpeed: speed,
    );
    return true;
  }

  @override
  List<DeviceFunction> onSupportFunctions() {
    return [
      PowerFunction(executeCall: (_, value) => _send(setPower(value))),
      LightFunction(executeCall: (_, value) => _send(setLightState(value))),
      TemperatureFunction(
        executeCall: (_, value) =>
            _setTemperatureFan(value.toInt(), _lastWrittenStatus.fanSpeed),
      ),
      FanSpeedFunction(
        executeCall: (_, value) =>
            _setTemperatureFan(_lastWrittenStatus.temperature, value),
      ),
      TimerFunction(executeCall: (_, value) => _send(setTimer(value))),
      TemperatureFanFunction(
        executeCall: (_, value) =>
            _setTemperatureFan(value.temperature, value.fanSpeed),
      ),
    ];
  }

  @override
  String get macd => id;
}

/// AT5 BLE 响应
class ClientResponse {
  const ClientResponse({
    required this.type,
    required this.command,
    required this.payload,
    required this.rawData,
    required this.receivedCrc,
    required this.calculatedCrc,
  });

  final ResponseType type;

  /// 响应 CMD
  ///
  /// 与发送命令对应，例如：
  ///
  /// 0x03 = 五路亮度
  /// 0x04 = 定时
  /// 0x05 = 电源
  /// 0x06 = 温度 / 风扇
  final int command;

  /// 不包含 Header / CMD / Length / CRC 的纯 Payload。
  final Uint8List payload;

  /// 完整原始 BLE 响应帧。
  final Uint8List rawData;

  /// 数据包携带的 CRC
  final int receivedCrc;

  /// 本地重新计算的 CRC
  final int calculatedCrc;

  bool get crcValid {
    return receivedCrc == calculatedCrc;
  }

  /// 是否为操作 ACK
  bool get isAck {
    return type == ResponseType.ack;
  }

  /// ACK 是否表示成功
  /// 当前抓包确认：
  /// Payload:
  /// 00 = Success
  /// 非 ACK 响应返回 null
  bool? get success {
    if (!isAck || payload.length != 1) {
      return null;
    }

    return payload[0] == 0x00;
  }

  /// ACK 状态码
  /// 当前只确认：
  /// 0x00 = Success
  int? get statusCode {
    if (!isAck || payload.length != 1) {
      return null;
    }

    return payload[0];
  }

  @override
  String toString() {
    return 'At5Response('
        'type: $type, '
        'command: 0x${command.toRadixString(16).padLeft(2, '0').toUpperCase()}, '
        'payload: ${toHex(payload)}, '
        'success: $success, '
        'crcValid: $crcValid'
        ')';
  }
}
