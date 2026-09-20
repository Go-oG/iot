import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'helpers/at5_device.dart';
import 'package:light/src/core/device_model.dart';

String hex(List<int> bytes) =>
    bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();

Uint8List frame(List<int> bytes) => Uint8List.fromList(bytes);

List<int> at5Checksum(List<int> data) => ChecksumCodec.calculate(
  CheckSumAlg.crc16Modbus,
  Uint8List.fromList(data),
  endian: DataEndian.big,
);

void main() {
  late DeviceModelRuntime runtime;

  setUp(() => runtime = DeviceModelRuntime(at5DeviceModel));

  group('AT5 设备定义逐字节复现既有实现', () {
    test('电源开关', () {
      expect(hex(runtime.encodeWrite('power', true)), '3443888805000101230e');
      expect(hex(runtime.encodeWrite('power', false)), '3443888805000100e3cf');
    });

    test('五路亮度', () {
      expect(
        hex(
          runtime.encodeWrite('channels', const {
            'red': 15,
            'green': 15,
            'blue': 17,
            'white': 25,
            'uv': 0,
          }),
        ),
        '344388880300050f0f111900cc43',
      );
      expect(
        hex(
          runtime.encodeWrite('channels', const {
            'red': 100,
            'green': 0,
            'blue': 55,
            'white': 1,
            'uv': 99,
          }),
        ),
        '344388880300056400370163f3ce',
      );
    });

    test('温控与风扇共用一条命令', () {
      expect(
        hex(
          runtime.encodeWrite(
            'temperature',
            31,
            propertyState: const {'fanSpeed': 1},
          ),
        ),
        '344388880600021f01a4de',
      );
      expect(
        hex(
          runtime.encodeWrite(
            'temperature',
            80,
            propertyState: const {'fanSpeed': 2},
          ),
        ),
        '34438888060002500295aa',
      );
      // 单独改档位时用同一批次的温度值补帧，结果与整条命令一致
      expect(
        hex(
          runtime.encodeWrite(
            'fanSpeed',
            2,
            propertyState: const {'temperature': 80},
          ),
        ),
        '34438888060002500295aa',
      );
    });

    test('定时九字节负载', () {
      expect(
        hex(
          runtime.encodeWrite('timer', const {
            'index': 2,
            'enabled': true,
            'startHour': 6,
            'startMinute': 30,
            'endHour': 22,
            'endMinute': 15,
            'sunriseSunsetEnabled': true,
            'sunriseMinutes': 45,
            'sunsetMinutes': 60,
          }),
        ),
        '344388880400090201061e160f012d3cb359',
      );
    });

    test('对时写入时分秒', () {
      expect(
        hex(
          runtime.encodeWrite('time', const {
            'hour': 23,
            'minute': 59,
            'second': 58,
          }),
        ),
        '34438888010003173b3a6237',
      );
    });
  });

  group('AT5 响应按定义校验', () {
    PacketDecodeSpec responseOf(String property) =>
        at5DeviceModel.properties[property]!.notify!.response!;

    test('帧头、命令字节与 CRC 全部校验通过后按状态码判断确认', () {
      final response = responseOf('power');
      final accepted = frame([
        ...at5ResponseHeader,
        at5CommandBytes['power']!,
        0x00,
        0x01,
        0x00,
      ]);
      expect(
        PacketDecoder.matches(response, frame([...accepted, ...at5Checksum(accepted)])),
        isTrue,
      );

      // 状态码非 0 的响应不匹配任何响应定义，不会被当成设备确认
      final rejected = frame([
        ...at5ResponseHeader,
        at5CommandBytes['power']!,
        0x00,
        0x01,
        0x01,
      ]);
      expect(
        PacketDecoder.matches(response, frame([...rejected, ...at5Checksum(rejected)])),
        isFalse,
      );
    });

    test('命令字节、保留字节或 CRC 不符的报文不属于本设备', () {
      final response = responseOf('power');

      final wrongCommand = frame([
        ...at5ResponseHeader,
        0x7F,
        0x00,
        0x01,
        0x00,
      ]);
      expect(
        PacketDecoder.matches(
          response,
          frame([...wrongCommand, ...at5Checksum(wrongCommand)]),
        ),
        isFalse,
      );

      final wrongReserved = frame([
        ...at5ResponseHeader,
        at5CommandBytes['power']!,
        0x01,
        0x01,
        0x00,
      ]);
      expect(
        PacketDecoder.matches(
          response,
          frame([...wrongReserved, ...at5Checksum(wrongReserved)]),
        ),
        isFalse,
      );

      final brokenCrc = frame([
        ...at5ResponseHeader,
        at5CommandBytes['power']!,
        0x00,
        0x01,
        0x00,
        0x00,
        0x00,
      ]);
      // 帧头与命令字节可以匹配，但 CRC 校验不通过，解码直接报错
      expect(
        () => PacketDecoder.decode(response, brokenCrc),
        throwsFormatException,
      );
    });
  });

  group('AT5 设备定义', () {
    test('模型声明可以序列化后重新载入', () {
      final restored = DeviceModel.fromJsonString(at5DeviceModel.toJsonString());
      expect(restored.toJsonString(), at5DeviceModel.toJsonString());
    });

    test('通知报文按响应定义解析成属性增量', () {
      final model = DeviceModel.fromJson({
        'id': 'sensor',
        'name': '传感器',
        'properties': {
          'power': {
            'name': '电源',
            'type': 'bool',
            'notify': {
              'op': 'subscribe',
              'service': 'fff0',
              'characteristic': 'fff1',
              'response': {
                'service': 'fff0',
                'characteristic': 'fff1',
                // 字面量自动成为匹配锚点，at= 表示取值偏移
                'template': r'01 ${value:bool8,at=1}',
              },
            },
          },
        },
      });
      final sensor = DeviceModelRuntime(model);
      expect(sensor.decodeNotifyPatch('power', frame([0x01, 0x01])), {
        'power': true,
      });
    });

    test('越界与类型不符的写入被模型校验拒绝', () {
      expect(() => runtime.encodeWrite('power', 'yes'), throwsArgumentError);
      expect(() => runtime.encodeWrite('temperature', 100), throwsRangeError);
      expect(() => runtime.encodeWrite('unknown', 1), throwsStateError);
      expect(
        () => runtime.encodeWrite('channels', const {'red': 1}),
        throwsArgumentError,
      );
    });
  });
}
