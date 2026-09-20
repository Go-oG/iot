import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:light/src/core/device_model.dart';
import 'package:light/src/core/frame_template.dart';

import 'helpers/at5_device.dart';

String hex(List<int> bytes) =>
    bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();

Uint8List frame(List<int> bytes) => Uint8List.fromList(bytes);

/// 请求帧编码
Uint8List encode(
  String template, {
  Object? value,
  Map<String, Object?> properties = const {},
  Map<String, Object?> variables = const {},
  int sequence = 0,
  FrameDefaults defaults = const FrameDefaults(),
}) {
  final spec = FrameTemplate.parseRequest(template, defaults: defaults);
  return PacketEncoder.encode(
    spec,
    PacketEncodeContext(
      value: value,
      properties: properties,
      variables: variables,
      sequence: sequence,
    ),
  );
}

void main() {
  setUpAll(loadDeviceModelCatalog);

  group('请求模板', () {
    test('字面量与占位符按出现顺序编译', () {
      const source =
          r'AA55 ${length:u8} ${seq:u8} 2103 ${value:u16be,scale=0.1} ${crc16modbus}';
      final spec = FrameTemplate.parseRequest(source);

      expect(spec.fields.map((field) => field.kind), [
        FieldKind.constant,
        FieldKind.length,
        FieldKind.sequence,
        FieldKind.constant,
        FieldKind.value,
        FieldKind.checksum,
      ]);
      expect(spec.fields.map((field) => field.order), [10, 20, 30, 40, 50, 60]);
      expect(spec.fields.map((field) => field.name), [
        null,
        'len',
        'seq',
        null,
        'value',
        'crc',
      ]);

      // 裸 ${length:u8} 默认统计载荷：seq + 2103 + value
      final length = spec.fields[1].length!;
      expect(length.source, LengthSource.range);
      expect(length.fromOrder, 30);
      expect(length.toOrder, 50);

      final bytes = encode(source, value: 123, sequence: 7);
      expect(hex(bytes.sublist(0, 8)), 'aa550507210304ce');
      expect(
        bytes.sublist(8),
        ChecksumCodec.calculate(
          CheckSumAlg.crc16Modbus,
          bytes.sublist(0, 8),
          endian: DataEndian.big,
        ),
      );
    });

    test('长度默认跨度由模型配置决定', () {
      const source = r'AA55 ${length:u8} ${value:u8}';
      // 默认 body：只有 value 计入
      expect(encode(source, value: 7)[2], 1);
      // 整帧：长度字段与自身之后的字节都计入
      expect(
        encode(source, value: 7, defaults: const FrameDefaults(lengthSpan: 'all'))[2],
        4,
      );
      expect(
        encode(
          source,
          value: 7,
          defaults: const FrameDefaults(lengthSpan: 'field(value)'),
        )[2],
        1,
      );
    });

    test('span 与 adjust 可以覆盖默认值', () {
      final spec = FrameTemplate.parseRequest(
        r'AA55 ${length:u8,span=field(value),adjust=-1} ${value:u32be}',
      );
      expect(spec.fields[1].length!.source, LengthSource.field);
      expect(spec.fields[1].length!.adjust, -1);
      expect(encode(
        r'AA55 ${length:u8,span=field(value),adjust=-1} ${value:u32be}',
        value: 1,
      )[2], 3);
    });

    test('跨度按名字引用，校验范围可自定义', () {
      final spec = FrameTemplate.parseRequest(
        r'AA55 ${value:u8} 5A ${crc16modbus,span=value..value}',
      );
      final checksum = spec.fields.last.checksum!;
      expect(checksum.fromOrder, 20);
      expect(checksum.toOrder, 20);
      expect(
        hex(encode(r'AA55 ${value:u8} 5A ${crc16modbus,span=value..value}', value: 3)),
        // span=value..value 只统计 value 字段
        'aa55035a${hex(ChecksumCodec.calculate(
          CheckSumAlg.crc16Modbus,
          frame([0x03]),
          endian: DataEndian.big,
        ))}',
      );
    });

    test('跨度写法归一成枚举', () {
      expect(FrameSpan.parse('all', path: 't').kind, FrameSpanKind.packet);
      expect(FrameSpan.parse('packet', path: 't'), const FrameSpan.packet());
      expect(FrameSpan.parse('body', path: 't'), const FrameSpan.body());
      expect(
        FrameSpan.parse('field(value)', path: 't'),
        const FrameSpan.field('value'),
      );
      expect(
        FrameSpan.parse('value..timer', path: 't'),
        const FrameSpan.range('value', 'timer'),
      );
      expect(
        () => FrameSpan.parse('unknown', path: 't'),
        throwsFormatException,
      );
    });

    test('校验算法参数按规范键名传给算法实现', () {
      const source =
          r'AA55 ${value:u8} ${crc8,span=all,poly=0x31,init=0xFF,reflectin=false}';
      final bytes = encode(source, value: 0x12);
      // 别名 poly / init / reflectin 归一成 polynomial / init / reflectIn
      expect(
        bytes.sublist(3),
        ChecksumCodec.calculate(
          CheckSumAlg.crc8,
          frame([0xAA, 0x55, 0x12]),
          options: const {
            'polynomial': 0x31,
            'init': 0xFF,
            'reflectIn': false,
          },
        ),
      );
    });

    test('属性、变量与简写形式', () {
      const source =
          r'AA55 ${property.fanSpeed:u8} ${variable.nonce:u16le} ${@mode:u8} ${$key:u8}';
      final spec = FrameTemplate.parseRequest(source);
      expect(spec.fields[1].property, 'fanSpeed');
      expect(spec.fields[2].variable, 'nonce');
      expect(spec.fields[3].property, 'mode');
      expect(spec.fields[4].variable, 'key');
      expect(
        hex(
          encode(
            source,
            properties: const {'fanSpeed': 2, 'mode': 9},
            variables: const {'nonce': 0x0102, 'key': 5},
          ),
        ),
        'aa550202010905',
      );
    });

    test('条件字段按属性取值决定是否参与帧', () {
      const source = r'AA55 ${value:u8?power}';
      expect(hex(encode(source, value: 7, properties: const {'power': true})), 'aa5507');
      expect(hex(encode(source, value: 7)), 'aa55');
      expect(
        hex(
          encode(
            r'AA55 ${value:u8?power==false}',
            value: 7,
            properties: const {'power': false},
          ),
        ),
        'aa5507',
      );
      expect(
        hex(encode(r'AA55 ${property.mode:u8?mode in (1,2)}', properties: const {'mode': 2})),
        'aa5502',
      );
      expect(
        hex(encode(r'AA55 ${property.mode:u8?mode in (1,2)}', properties: const {'mode': 3})),
        'aa55',
      );
      expect(
        hex(encode(r'AA55 ${property.flags:u8?flags & 0x04}', properties: const {'flags': 0x04})),
        'aa5504',
      );
      expect(
        hex(encode(r'AA55 ${property.flags:u8?not flags & 0x04}', properties: const {'flags': 0x00})),
        'aa5500',
      );
    });

    test('位域按位区间与来源组装', () {
      const source =
          r'AA55 ${bitfield:u8,parts=0:const(1);1:value;3..4:property.mode;5:property.power?power}';
      expect(
        hex(encode(source, value: true, properties: const {'mode': 2})),
        'aa5513',
      );
      expect(
        hex(
          encode(
            source,
            value: true,
            properties: const {'mode': 2, 'power': true},
          ),
        ),
        'aa5533',
      );
    });

    test('对象与数组编码', () {
      expect(
        hex(encode(r'${value:object,fields=a:u8;b:u16le}', value: const {'a': 1, 'b': 0x0203})),
        '010302',
      );
      expect(
        hex(encode(r'${value:array,items=u8,prefix=u8}', value: const [1, 2, 3])),
        '03010203',
      );
    });

    test('模型可以用配置声明自己的长度含义', () {
      final model = DeviceModel.fromJson({
        'id': 'demo',
        'name': '演示设备',
        'frame': {'lengthSpan': 'all'},
        'properties': {
          'level': {
            'name': '档位',
            'type': 'int',
            'ui': {'renderer': 'input'},
            'write': {
              'op': 'write',
              'service': 'fff0',
              'characteristic': 'fff1',
              'request': {'template': r'AA55 ${length:u8} ${value:u8}'},
            },
          },
        },
      });
      final bytes = DeviceModelRuntime(model).encodeWrite('level', 7);
      // 整帧 4 字节：AA55 + 长度 + 值
      expect(bytes[2], 4);
    });
  });

  group('响应模板', () {
    test('字面量自动成为匹配锚点，skip 只跳过不取值', () {
      const source = r'43348888 05 00 ${skip:u8} 00 ${crc16modbus,at=-2}';
      final spec = FrameTemplate.parseResponse(source);

      expect(spec.match.map((match) => '${match.offset}:${match.hex}'), [
        '0:43348888',
        '4:05',
        '5:00',
        '7:00',
      ]);
      expect(spec.checksum!.alg, CheckSumAlg.crc16Modbus);
      expect(spec.checksum!.offset, -2);
      expect(spec.value, isNull);

      final payload = [0x43, 0x34, 0x88, 0x88, 0x05, 0x00, 0x01, 0x00];
      final packet = frame([
        ...payload,
        ...ChecksumCodec.calculate(
          CheckSumAlg.crc16Modbus,
          Uint8List.fromList(payload),
          endian: DataEndian.big,
        ),
      ]);
      expect(PacketDecoder.matches(spec, packet), isTrue);
      // 只声明确认、没有上报字段的响应不产生状态增量
      expect(PacketDecoder.decode(spec, packet), isNull);
    });

    test('按偏移解析数值并校验和', () {
      const source = r'${value:u16le,scale=0.1,at=0} ${checksum:sum8,at=2}';
      final spec = FrameTemplate.parseResponse(source);
      final value = [0x85, 0x02];
      final packet = frame([
        ...value,
        ...ChecksumCodec.calculate(
          CheckSumAlg.sum8,
          Uint8List.fromList(value),
        ),
      ]);
      expect(PacketDecoder.decode(spec, packet), closeTo(64.5, 0.001));
    });

    test('mask 匹配与多值上报', () {
      const source =
          r'${match:AA,mask=F0,at=0} ${property.mode:u8,at=1} ${property.level:u8,at=2}';
      final spec = FrameTemplate.parseResponse(source);
      expect(spec.match.single.mask, 'F0');
      expect(spec.values.map((item) => item.property), ['mode', 'level']);
      expect(PacketDecoder.decode(spec, frame([0xAB, 2, 9])), {
        'mode': 2,
        'level': 9,
      });
      expect(PacketDecoder.matches(spec, frame([0xBB, 2, 9])), isFalse);
    });

    test('校验字段可声明统计范围', () {
      final spec = FrameTemplate.parseResponse(
        r'${value:u8,at=0} ${checksum:crc16ccittFalse,start=1,end=beforeChecksum,at=-2}',
      );
      expect(spec.checksum!.start, 1);
      expect(spec.checksum!.end, ResponseChecksumEnd.beforeChecksum);
      expect(spec.checksum!.length, 2);
    });

    test('动态宽度字段之后必须显式给出偏移', () {
      expect(
        () => FrameTemplate.parseResponse(
          r'${value:utf8,at=0} ${property.mode:u8}',
        ),
        throwsFormatException,
      );
    });
  });

  group('写回模板', () {
    test('请求模板可以规范化往返', () {
      const source = r'AA55 ${length:u8} ${value:u16be,scale=0.1} ${crc16modbus}';
      final spec = FrameTemplate.parseRequest(source);
      final written = FrameTemplate.writeRequest(spec);
      expect(written, source);
      expect(
        hex(
          PacketEncoder.encode(
            FrameTemplate.parseRequest(written),
            PacketEncodeContext(value: 12.5),
          ),
        ),
        hex(PacketEncoder.encode(spec, PacketEncodeContext(value: 12.5))),
      );
    });

    test('响应的规范化结果稳定', () {
      const source = r'43348888 05 00 ${skip:u8} 00 ${crc16modbus,at=-2}';
      final first = FrameTemplate.writeResponse(
        FrameTemplate.parseResponse(source),
      );
      final second = FrameTemplate.writeResponse(
        FrameTemplate.parseResponse(first),
      );
      expect(second, first);
      expect(first, contains(r'${crc16modbus,at=-2}'));
    });

    test('AT5 模型序列化后仍然可用', () {
      final restored = DeviceModel.fromJsonString(at5DeviceModel.toJsonString());
      final runtime = DeviceModelRuntime(restored);
      expect(hex(runtime.encodeWrite('power', true)), '3443888805000101230e');
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
    });

    test('随包模型文件就是规范化模板', () {
      final source = jsonDecode(
        File('assets/devices/at5.json').readAsStringSync(),
      );
      // 编辑器保存后的内容与仓库里的定义完全一致，避免出现格式漂移
      expect(jsonDecode(at5DeviceModel.toJsonString()), source);
    });
  });

  group('错误提示', () {
    test('未知字段类型与未知选项', () {
      expect(
        () => FrameTemplate.parseRequest(r'${foo:u8}'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('未知的字段类型'),
          ),
        ),
      );
      expect(
        () => FrameTemplate.parseRequest(r'${value:u8,bar=1}'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('未知的选项'),
          ),
        ),
      );
    });

    test('跨度引用不存在的字段', () {
      expect(
        () => FrameTemplate.parseRequest(r'AA55 ${length:u8,span=field(payload)}'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('不存在的字段'),
          ),
        ),
      );
    });

    test('响应专用字段不能出现在请求模板', () {
      expect(
        () => FrameTemplate.parseRequest(r'AA55 ${skip:u8}'),
        throwsFormatException,
      );
    });

    test('字段名重复', () {
      expect(
        () => FrameTemplate.parseRequest(
          r'${property.power:u8} ${property.power:u8}',
        ),
        throwsFormatException,
      );
    });

    test('校验范围不能包含自身', () {
      expect(
        () => FrameTemplate.parseRequest(r'AA55 ${value:u8} ${crc16modbus,span=crc..crc}'),
        throwsFormatException,
      );
    });

    test('长度字段必须是固定宽度', () {
      expect(
        () => FrameTemplate.parseRequest(r'${length:utf8} ${value:u8}'),
        throwsFormatException,
      );
    });
  });
}
