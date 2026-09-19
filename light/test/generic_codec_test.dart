import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:light/src/core/device/checksum.dart';
import 'package:light/src/core/device/function_type.dart';
import 'package:light/src/core/device/generic_codec.dart';
import 'package:light/src/core/device/impl/generic_device.dart';
import 'package:light/src/core/protocol/protocol.dart';
import 'package:light/src/data/device_configuration.dart';

import 'helpers/device_examples.dart';

/// 把字节转成便于比对的十六进制
String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List unhex(String text) {
  final clean = text.replaceAll(' ', '');
  return Uint8List.fromList([
    for (var i = 0; i < clean.length; i += 2)
      int.parse(clean.substring(i, i + 2), radix: 16),
  ]);
}

/// 按 AT5 响应帧规则拼一条报文，用于驱动解析路径
Uint8List at5Response(int command, List<int> payload) {
  final body = [
    0x43,
    0x34,
    0x88,
    0x88,
    command,
    0x00,
    payload.length,
    ...payload,
  ];
  final crc = Checksums.crc16Modbus(body);
  return Uint8List.fromList([...body, (crc >> 8) & 0xFF, crc & 0xFF]);
}

void main() {
  late GenericCodec codec;

  setUp(() {
    codec = GenericCodec.fromJson(at5ExampleConfig, serviceFallbacks: const []);
  });

  group('命令帧型示例：AT5 灯具逐字节复现', () {
    // 期望值取自 At5Client 的实际输出，改动任何一侧都会失败
    test('电源开', () {
      expect(
        hex(codec.encode('setPower', const {ConfigurableFunction.power: true})),
        '3443888805000101230e',
      );
    });

    test('电源关', () {
      expect(
        hex(codec.encode('setPower', const {ConfigurableFunction.power: false})),
        '3443888805000100e3cf',
      );
    });

    test('亮度全通道', () {
      const light = {'red': 15, 'green': 15, 'blue': 17, 'white': 25, 'uv': 0};
      expect(
        hex(codec.encode('setLight', const {ConfigurableFunction.light: light})),
        '344388880300050f0f111900cc43',
      );
    });

    test('亮度上限与零值', () {
      const light = {'red': 100, 'green': 0, 'blue': 55, 'white': 1, 'uv': 99};
      expect(
        hex(codec.encode('setLight', const {ConfigurableFunction.light: light})),
        '344388880300056400370163f3ce',
      );
    });

    test('温控与风扇同一命令', () {
      expect(
        hex(
          codec.encode('setClimate', const {
            ConfigurableFunction.temperature: 31,
            ConfigurableFunction.fanSpeed: 'low',
          }),
        ),
        '344388880600021f01a4de',
      );
      expect(
        hex(
          codec.encode('setClimate', const {
            ConfigurableFunction.temperature: 80,
            ConfigurableFunction.fanSpeed: 'high',
          }),
        ),
        '34438888060002500295aa',
      );
    });

    test('定时九字节负载', () {
      const timer = {
        'index': 2,
        'enabled': true,
        'startHour': 6,
        'startMinute': 30,
        'endHour': 22,
        'endMinute': 15,
        'sunriseSunsetEnabled': true,
        'sunriseMinutes': 45,
        'sunsetMinutes': 60,
      };
      expect(
        hex(codec.encode('setTimer', const {ConfigurableFunction.timer: timer})),
        '34438888040009020106 1e160f012d3cb359'.replaceAll(' ', ''),
      );
    });

    test('对时取当前时间', () {
      final now = DateTime(2026, 9, 19, 23, 59, 58);
      expect(
        hex(codec.encode('syncTime', const {}, now: now)),
        '34438888010003 173b3a6237'.replaceAll(' ', ''),
      );
    });

    test('value 简写取当前功能的状态值', () {
      // 单功能命令可以用 value 代替完整路径
      final shorthand = GenericCodec.fromJson({
        'chars': {
          'a': {'service': 'fff0', 'char': 'fff1'},
        },
        'commands': {
          'setPower': {
            'char': 'a',
            'payload': [
              {
                'field': 'value',
                'as': 'bool',
                'map': {'true': '01', 'false': '00'},
              },
            ],
          },
        },
      }, serviceFallbacks: const []);
      expect(shorthand.encodeHex('setPower', const {}, value: true), '01');
    });
  });

  group('寄存器型示例：温控器', () {
    // 与 AT5 示例在寻址方式、帧结构、校验算法、值编码上全部不同，
    // 用同一份实现跑通即说明格式不依赖某一种设备形态
    late GenericCodec thermostat;

    setUp(() {
      thermostat = GenericCodec.fromJson(
        thermostatExampleConfig,
        serviceFallbacks: const [],
      );
    });

    test('没有帧头、命令字节和长度字段，只有负载加校验', () {
      // 24.5℃ -> 245 -> 小端 f5 00，sum8 = f5
      expect(
        hex(thermostat.encode('setTemperature', const {ConfigurableFunction.temperature: 24.5})),
        'f500f5',
      );
      // 20.0℃ -> 200 -> c8 00
      expect(
        hex(thermostat.encode('setTemperature', const {ConfigurableFunction.temperature: 20.0})),
        'c800c8',
      );
      // 35.0℃ -> 350 -> 5e 01
      expect(
        hex(thermostat.encode('setTemperature', const {ConfigurableFunction.temperature: 35.0})),
        '5e015f',
      );
    });

    test('写入不需要响应', () {
      expect(
        thermostat.commands['setTemperature']!.writeType,
        GatewayWriteType.withoutResponse,
      );
      expect(
        thermostat.commands['setTemperature']!.acceptsWithoutResponse,
        isTrue,
      );
    });

    test('超出声明范围的取值被拒绝', () {
      expect(
        () => thermostat.encode('setTemperature', const {ConfigurableFunction.temperature: 40.0}),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => thermostat.encode('setTemperature', const {ConfigurableFunction.temperature: 5.0}),
        throwsA(isA<FormatException>()),
      );
    });

    test('上报特征解析成摄氏度', () {
      // 273 -> 27.3℃，sum8 = 12
      final decoded = thermostat.decode(unhex('110112'), charName: 'report');
      expect(decoded, isNotNull);
      expect(decoded!.kind, GenericCommandKind.state);
      expect(decoded.values[ConfigurableFunction.temperature], 27.3);
    });

    test('校验和不符返回 null', () {
      expect(thermostat.decode(unhex('1101ff'), charName: 'report'), isNull);
    });

    test('上报值超出范围时报错而不是写坏状态', () {
      // 校验和正确但数值为 50 -> 5.0℃，低于声明的下限
      expect(
        () => thermostat.decode(unhex('320032'), charName: 'report'),
        throwsA(isA<FormatException>()),
      );
    });

    test('订阅的是上报特征而非写入特征', () {
      expect(thermostat.subscribe, ['report']);
      expect(thermostat.commands['setTemperature']!.charName, 'setpoint');
      expect(thermostat.commands['temperatureReport']!.charName, 'report');
    });

    test('上报走通知，不需要主动轮询', () {
      expect(thermostat.polledCommands, isEmpty);
    });
  });

  group('响应解析', () {
    test('状态响应写回多个功能', () {
      final decoded = codec.decode(at5Response(0x06, [31, 2]));
      expect(decoded, isNotNull);
      expect(decoded!.kind, GenericCommandKind.state);
      expect(decoded.commandName, 'climateState');
      expect(decoded.values[ConfigurableFunction.temperature], 31);
      expect(decoded.values[ConfigurableFunction.fanSpeed], 'high');
    });

    test('确认响应按负载长度判定接受', () {
      final accepted = codec.decode(at5Response(0x05, [0x01]));
      expect(accepted!.kind, GenericCommandKind.ack);
      expect(accepted.accepted, isTrue);

      final rejected = codec.decode(at5Response(0x05, [0x01, 0x02]));
      expect(rejected!.kind, GenericCommandKind.ack);
      expect(rejected.accepted, isFalse);
    });

    test('帧头不符返回 null', () {
      final frame = at5Response(0x05, [0x01]);
      frame[0] = 0x00;
      expect(codec.decode(frame), isNull);
    });

    test('校验和不符返回 null', () {
      final frame = at5Response(0x05, [0x01]);
      frame[frame.length - 1] ^= 0xFF;
      expect(codec.decode(frame), isNull);
    });

    test('未知命令字节返回 null', () {
      expect(codec.decode(at5Response(0x7F, [0x01])), isNull);
    });

    test('负载不足以容纳字段时报错', () {
      expect(
        () => codec.decode(at5Response(0x06, [31])),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('命令与功能绑定', () {
    test('共享命令的两个功能只下发一次', () {
      final names = codec.writeCommandsFor(const [
        ConfigurableFunction.temperature,
        ConfigurableFunction.fanSpeed,
      ]);
      expect(names, ['setClimate']);
    });

    test('多个功能各自映射到自己的命令', () {
      expect(
        codec.writeCommandsFor(const [
          ConfigurableFunction.power,
          ConfigurableFunction.light,
          ConfigurableFunction.timer,
        ]),
        [
        'setPower',
        'setLight',
        'setTimer',
      ]);
    });

    test('没有绑定的功能不产生命令', () {
      expect(
        codec.writeCommandsFor(const [ConfigurableFunction.fanSpeedPercent]),
        isEmpty,
      );
    });

    test('未绑定 write 的功能返回空命令', () {
      expect(codec.writeCommandFor(ConfigurableFunction.temperature), isNotNull);
      expect(codec.writeCommandFor(ConfigurableFunction.fanSpeedPercent), isNull);
    });

    test('需要主动读取的命令被列出', () {
      expect(codec.polledCommands, isEmpty);
    });

    test('订阅列表解析成特征', () {
      expect(codec.subscribe, ['ctrl']);
      expect(codec.chars['ctrl']!.char, '8332af20-6d0e-4eea-bb35-665544332211');
    });
  });

  group('配置校验', () {
    test('引用未定义特征报错', () {
      expect(
        () => GenericCodec.fromJson({
          'commands': {
            'c': {
              'char': 'missing',
              'payload': [
                {'const': '01'},
              ],
            },
          },
        }, serviceFallbacks: const []),
        throwsA(isA<FormatException>()),
      );
    });

    test('声明了 frame 却没有 payload 段时报错', () {
      expect(
        () => GenericCodec.fromJson({
          'chars': {
            'a': {'service': 'fff0', 'char': 'fff1'},
          },
          'frame': {
            'segments': [
              {'const': 'aa'},
            ],
          },
          'commands': {
            'c': {
              'char': 'a',
              'payload': [
                {'const': '01'},
              ],
            },
          },
        }, serviceFallbacks: const []),
        throwsA(isA<FormatException>()),
      );
    });

    test('帧含命令段但命令缺少 command 报错', () {
      expect(
        () => GenericCodec.fromJson({
          'chars': {
            'a': {'service': 'fff0', 'char': 'fff1'},
          },
          'frame': {
            'segments': [
              {'command': true},
              {'payload': true},
            ],
          },
          'commands': {
            'c': {
              'char': 'a',
              'payload': [
                {'const': '01'},
              ],
            },
          },
        }, serviceFallbacks: const []),
        throwsA(isA<FormatException>()),
      );
    });

    test('帧没有命令段但命令声明了 command 报错', () {
      expect(
        () => GenericCodec.fromJson({
          'chars': {
            'a': {'service': 'fff0', 'char': 'fff1'},
          },
          'frame': {
            'segments': [
              {'payload': true},
            ],
          },
          'commands': {
            'c': {
              'char': 'a',
              'command': '01',
              'payload': [
                {'const': '01'},
              ],
            },
          },
        }, serviceFallbacks: const []),
        throwsA(isA<FormatException>()),
      );
    });

    test('write 指向读命令报错', () {
      expect(
        () => GenericCodec.fromJson({
          'chars': {
            'a': {'service': 'fff0', 'char': 'fff1'},
          },
          'frame': {
            'segments': [
              {'payload': true},
            ],
          },
          'commands': {
            'read': {
              'char': 'a',
              'fields': [
                {'index': 0, 'as': 'int'},
              ],
            },
          },
          'functions': [
            {'type': 'power', 'write': 'read'},
          ],
        }, serviceFallbacks: const []),
        throwsA(isA<FormatException>()),
      );
    });

    test('target 指向未声明功能报错', () {
      expect(
        () => GenericCodec.fromJson({
          'chars': {
            'a': {'service': 'fff0', 'char': 'fff1'},
          },
          'commands': {
            'read': {
              'char': 'a',
              'fields': [
                {'index': 0, 'as': 'int', 'target': 'ghost'},
              ],
            },
          },
          'functions': [
            {'type': 'power'},
          ],
        }, serviceFallbacks: const []),
        throwsA(isA<FormatException>()),
      );
    });

    test('枚举缺少 map 报错', () {
      expect(
        () => GenericCodec.fromJson({
          'chars': {
            'a': {'service': 'fff0', 'char': 'fff1'},
          },
          'frame': {
            'segments': [
              {'payload': true},
            ],
          },
          'commands': {
            'c': {
              'char': 'a',
              'payload': [
                {'field': 'value', 'as': 'enum'},
              ],
            },
          },
        }, serviceFallbacks: const []),
        throwsA(isA<FormatException>()),
      );
    });

    test('布尔映射缺少一侧报错', () {
      expect(
        () => GenericCodec.fromJson({
          'chars': {
            'a': {'service': 'fff0', 'char': 'fff1'},
          },
          'frame': {
            'segments': [
              {'payload': true},
            ],
          },
          'commands': {
            'c': {
              'char': 'a',
              'payload': [
                {
                  'field': 'value',
                  'as': 'bool',
                  'map': {'true': '01'},
                },
              ],
            },
          },
        }, serviceFallbacks: const []),
        throwsA(isA<FormatException>()),
      );
    });

    test('subscribe 引用未定义特征报错', () {
      expect(
        () => GenericCodec.fromJson({
          'chars': {
            'a': {'service': 'fff0', 'char': 'fff1'},
          },
          'subscribe': ['missing'],
        }, serviceFallbacks: const []),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('无帧设备', () {
    test('负载原样写入特征', () {
      final simple = GenericCodec.fromJson({
        'chars': {
          'sw': {'service': 'fff0', 'char': 'fff1'},
        },
        'frame': {
          'segments': [
            {'payload': true},
          ],
        },
        'commands': {
          'setPower': {
            'char': 'sw',
            'payload': [
              {
                'field': 'value',
                'as': 'bool',
                'map': {'true': '01', 'false': '00'},
              },
            ],
          },
        },
        'functions': [
          {'type': 'power', 'write': 'setPower'},
        ],
      }, serviceFallbacks: const []);

      expect(simple.encodeHex('setPower', const {}, value: true), '01');
      expect(simple.encodeHex('setPower', const {}, value: false), '00');
    });

    test('省略 frame 时按原样写入', () {
      final raw = GenericCodec.fromJson({
        'chars': {
          'level': {'service': 'fff0', 'char': 'fff2'},
        },
        'commands': {
          'setLevel': {
            'char': 'level',
            'payload': [
              {
                'field': 'value',
                'as': 'int',
                'range': [0, 100],
              },
            ],
          },
        },
      }, serviceFallbacks: const []);
      // 直接写入 hex，不加任何封包
      expect(raw.encodeHex('setLevel', const {}, value: 42), '2a');
    });
  });

  group('取值变换', () {
    test('scale 与 offset 双向换算', () {
      final scaled = GenericValueSpec(
        as: WireValueKind.integer,
        scale: 2,
        offset: 10,
        min: 0,
        max: 255,
      );
      // (31 - 10) * 2 = 42
      expect(scaled.encode(31), [42]);
      expect(scaled.decode([42]), 31);
    });

    test('多字节大端与小端', () {
      const big = GenericValueSpec(
        as: WireValueKind.integer,
        bytes: 2,
        endian: ByteEndian.big,
      );
      const little = GenericValueSpec(
        as: WireValueKind.integer,
        bytes: 2,
        endian: ByteEndian.little,
      );
      expect(big.encode(0x1234), [0x12, 0x34]);
      expect(little.encode(0x1234), [0x34, 0x12]);
      expect(big.decode([0x12, 0x34]), 0x1234);
      expect(little.decode([0x34, 0x12]), 0x1234);
    });

    test('超出范围报错', () {
      const spec = GenericValueSpec(
        as: WireValueKind.integer,
        min: 20,
        max: 80,
      );
      expect(() => spec.encode(10), throwsA(isA<FormatException>()));
      expect(() => spec.encode(90), throwsA(isA<FormatException>()));
    });

    test('映射表以外的取值报错', () {
      const spec = GenericValueSpec(
        as: WireValueKind.enumeration,
        map: {'low': '01', 'high': '02'},
        reverse: {'01': 'low', '02': 'high'},
      );
      expect(() => spec.encode('medium'), throwsA(isA<FormatException>()));
      expect(() => spec.decode([9]), throwsA(isA<FormatException>()));
    });

    test('百分比钳制在 0 到 100', () {
      const spec = GenericValueSpec(as: WireValueKind.percent);
      expect(spec.encode(120), [100]);
      expect(spec.encode(-5), [0]);
      expect(spec.decode([200]), 100);
    });
  });

  group('配置往返', () {
    test('解析后再序列化保持等价', () {
      // 编解码器只负责自己的块，功能声明仍由设备配置持有
      final restored = GenericCodec.fromJson({
        ...at5ExampleConfig,
        ...codec.toJson(),
      }, serviceFallbacks: const []);
      expect(restored.commands.keys, codec.commands.keys);
      expect(restored.subscribe, codec.subscribe);
      expect(
        hex(restored.encode('setPower', const {ConfigurableFunction.power: true})),
        hex(codec.encode('setPower', const {ConfigurableFunction.power: true})),
      );
      expect(
        hex(
          restored.encode('setClimate', const {
            ConfigurableFunction.temperature: 31,
            ConfigurableFunction.fanSpeed: 'low',
          }),
        ),
        hex(
          codec.encode('setClimate', const {
            ConfigurableFunction.temperature: 31,
            ConfigurableFunction.fanSpeed: 'low',
          }),
        ),
      );
      expect(
        restored.decode(at5Response(0x06, [31, 2]))?.values,
        codec.decode(at5Response(0x06, [31, 2]))?.values,
      );
    });

    test('经过设备配置保存后协议块与功能绑定不丢失', () {
      // 设备页的导入/导出与编辑器都走 DeviceConfiguration
      final configuration = DeviceConfiguration.fromJson(at5ExampleConfig);
      final exported = configuration.toJson();

      final rebuilt = GenericDevice.fromJson(exported);
      expect(rebuilt.supportsRemoteControl, isTrue);
      expect(
        hex(rebuilt.codec.encode('setPower', const {ConfigurableFunction.power: true})),
        '3443888805000101230e',
      );
      expect(
        rebuilt.codec.writeCommandsFor(const [
          ConfigurableFunction.temperature,
          ConfigurableFunction.fanSpeed,
        ]),
        ['setClimate'],
      );
      expect(configuration.functions.map((f) => f['write']), [
        'setPower',
        'setLight',
        'setClimate',
        'setClimate',
        'setTimer',
      ]);
    });

    test('没有协议块的配置仍然可以解析和预览', () {
      final device = GenericDevice.fromJson(const {
        'id': 'plain',
        'name': '纯预览设备',
        'functions': [
          {'type': 'power', 'status': true},
        ],
      });
      expect(device.supportsRemoteControl, isFalse);
      expect(device.status[ConfigurableFunction.power], isTrue);
    });
  });
}
