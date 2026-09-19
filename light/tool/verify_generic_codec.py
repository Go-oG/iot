#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""校验《通用设备远程读写协议设计》对 AT5 的描述是否逐字节正确。

左侧按设计文档的 frame/commands 结构实现编码器，右侧复刻 At5Client 的
现有编码逻辑，逐命令比对字节输出。两侧独立实现，任何不一致都会暴露设计缺陷。
"""

REQ_HEADER = bytes([0x34, 0x43, 0x88, 0x88])
RESP_HEADER = bytes([0x43, 0x34, 0x88, 0x88])


# ---------- 右侧：复刻 At5Client 现有实现 ----------

def crc16_modbus(data):
    crc = 0xFFFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc & 0xFFFF


def at5_build(command, payload):
    """对应 At5Client._buildRequest"""
    out = bytearray(REQ_HEADER)
    out.append(command)
    out.append(0x00)          # Reserved
    out.append(len(payload))  # Length
    out.extend(payload)
    crc = crc16_modbus(out)
    out.append((crc >> 8) & 0xFF)
    out.append(crc & 0xFF)
    return bytes(out)


def at5_set_power(enabled):
    return at5_build(0x05, [0x01 if enabled else 0x00])


def at5_set_brightness(red, green, blue, white, uv):
    return at5_build(0x03, [max(0, min(100, v)) for v in (red, green, blue, white, uv)])


def at5_set_climate(temperature, fan_speed):
    """fan_speed: 'low' -> 1, 'high' -> 2"""
    value = {'low': 1, 'high': 2}[fan_speed]
    return at5_build(0x06, [max(0, min(255, temperature)), value])


def at5_set_timer(cfg):
    return at5_build(0x04, [
        cfg['index'],
        0x01 if cfg['enabled'] else 0x00,
        cfg['startHour'], cfg['startMinute'],
        cfg['endHour'], cfg['endMinute'],
        0x01 if cfg['sunriseSunsetEnabled'] else 0x00,
        cfg['sunriseMinutes'], cfg['sunsetMinutes'],
    ])


def at5_sync_time(hour, minute, second):
    return at5_build(0x01, [hour, minute, second])


# ---------- 左侧：按设计文档的结构驱动编码器 ----------

def resolve_path(state, path):
    """按点号访问嵌套字段，与 Dart 实现一致"""
    current = state
    for part in path.split('.'):
        if not isinstance(current, dict) or part not in current:
            raise KeyError(f'字段 {path} 不在设备状态中')
        current = current[part]
    return current


def encode_payload(segments, state, now):
    """payload 段列表 -> 字节。字段相对整机 state 解析。"""
    out = bytearray()
    for segment in segments:
        if 'const' in segment:
            out.extend(bytes.fromhex(segment['const']))
            continue
        if 'clock' in segment:
            out.append({'hour': now[0], 'minute': now[1], 'second': now[2]}[segment['clock']])
            continue
        field = segment.get('field', 'value')
        value = state.get('value') if field == 'value' else resolve_path(state, field)
        out.extend(encode_value(segment, value))
    return bytes(out)


def encode_value(segment, value):
    kind = segment.get('as', 'int')
    if 'map' in segment:
        key = str(value).lower() if isinstance(value, bool) else str(value)
        return bytes.fromhex(segment['map'][key])
    if kind == 'percent':
        return bytes([max(0, min(100, int(value)))])
    if kind == 'bool':
        return bytes([1 if value else 0])
    number = int(round((value - segment.get('offset', 0)) * segment.get('scale', 1)))
    low, high = segment.get('range', (0, 255))
    if not low <= number <= high:
        raise ValueError(f'{segment.get("field")} 超出范围：{number}')
    size = segment.get('bytes', 1)
    return number.to_bytes(size, 'little' if segment.get('endian') == 'little' else 'big')


def encode_frame(frame, command, payload):
    """frame.segments -> 完整报文"""
    out = bytearray()
    for segment in frame['segments']:
        if 'const' in segment:
            out.extend(bytes.fromhex(segment['const']))
        elif 'reserved' in segment:
            out.extend(bytes.fromhex(segment['reserved']))
        elif segment.get('command'):
            out.extend(bytes.fromhex(command['command']))
        elif 'length' in segment:
            size = len(payload) if segment['length'].get('of') == 'payload' else len(out)
            out.extend(size.to_bytes(segment['length'].get('bytes', 1), 'big'))
        elif segment.get('payload'):
            out.extend(payload)
        elif 'crc' in segment:
            crc_type = segment['crc']['type']
            target = payload if segment['crc'].get('of') == 'payload' else bytes(out)
            value = crc16_modbus(target) if crc_type == 'crc16-modbus' else 0
            order = 'little' if segment['crc'].get('endian') == 'little' else 'big'
            out.extend(value.to_bytes(2, order))
    return bytes(out)


def build(design, command_name, state, now=(0, 0, 0)):
    command = design['commands'][command_name]
    payload = encode_payload(command['payload'], state, now)
    return encode_frame(design['frame'], command, payload)


# ---------- 文档中的 AT5 配置 ----------

AT5 = {
    'frame': {
        'segments': [
            {'const': '34438888'},
            {'command': True},
            {'reserved': '00'},
            {'length': {'of': 'payload'}},
            {'payload': True},
            {'crc': {'type': 'crc16-modbus', 'endian': 'big'}},
        ]
    },
    'commands': {
        'setPower': {
            'char': 'ctrl', 'command': '05',
            'payload': [{'field': 'power', 'as': 'bool', 'map': {'true': '01', 'false': '00'}}],
        },
        'setLight': {
            'char': 'ctrl', 'command': '03',
            'payload': [
                {'field': 'light.red', 'as': 'percent'},
                {'field': 'light.green', 'as': 'percent'},
                {'field': 'light.blue', 'as': 'percent'},
                {'field': 'light.white', 'as': 'percent'},
                {'field': 'light.uv', 'as': 'percent'},
            ],
        },
        'setClimate': {
            'char': 'ctrl', 'command': '06',
            'payload': [
                {'field': 'temperature', 'as': 'int', 'range': [20, 80]},
                {'field': 'fanSpeed', 'as': 'enum', 'map': {'low': '01', 'high': '02'}},
            ],
        },
        'setTimer': {
            'char': 'ctrl', 'command': '04',
            'payload': [
                {'field': 'timer.index', 'as': 'int', 'range': [1, 2]},
                {'field': 'timer.enabled', 'as': 'bool', 'map': {'true': '01', 'false': '00'}},
                {'field': 'timer.startHour', 'as': 'int', 'range': [0, 23]},
                {'field': 'timer.startMinute', 'as': 'int', 'range': [0, 59]},
                {'field': 'timer.endHour', 'as': 'int', 'range': [0, 23]},
                {'field': 'timer.endMinute', 'as': 'int', 'range': [0, 59]},
                {'field': 'timer.sunriseSunsetEnabled', 'as': 'bool', 'map': {'true': '01', 'false': '00'}},
                {'field': 'timer.sunriseMinutes', 'as': 'int', 'range': [0, 255]},
                {'field': 'timer.sunsetMinutes', 'as': 'int', 'range': [0, 255]},
            ],
        },
        'syncTime': {
            'char': 'ctrl', 'command': '01',
            'payload': [{'clock': 'hour'}, {'clock': 'minute'}, {'clock': 'second'}],
        },
    },
}

TIMER = {
    'index': 2, 'enabled': True,
    'startHour': 6, 'startMinute': 30, 'endHour': 22, 'endMinute': 15,
    'sunriseSunsetEnabled': True, 'sunriseMinutes': 45, 'sunsetMinutes': 60,
}

CASES = [
    ('电源 开',
     build(AT5, 'setPower', {'power': True}),
     at5_set_power(True)),
    ('电源 关',
     build(AT5, 'setPower', {'power': False}),
     at5_set_power(False)),
    ('亮度 全通道',
     build(AT5, 'setLight', {'light': {'red': 15, 'green': 15, 'blue': 17, 'white': 25, 'uv': 0}}),
     at5_set_brightness(15, 15, 17, 25, 0)),
    ('亮度 边界 100',
     build(AT5, 'setLight', {'light': {'red': 100, 'green': 0, 'blue': 55, 'white': 1, 'uv': 99}}),
     at5_set_brightness(100, 0, 55, 1, 99)),
    ('温控+风扇（低速）',
     build(AT5, 'setClimate', {'temperature': 31, 'fanSpeed': 'low'}),
     at5_set_climate(31, 'low')),
    ('温控+风扇（高速）',
     build(AT5, 'setClimate', {'temperature': 80, 'fanSpeed': 'high'}),
     at5_set_climate(80, 'high')),
    ('定时 槽位 2',
     build(AT5, 'setTimer', {'timer': TIMER}),
     at5_set_timer(TIMER)),
    ('对时',
     build(AT5, 'syncTime', {}, now=(23, 59, 58)),
     at5_sync_time(23, 59, 58)),
]


def main():
    failed = 0
    for name, produced, expected in CASES:
        if produced == expected:
            print(f'  OK   {name:22} {produced.hex(" ").upper()}')
        else:
            failed += 1
            print(f'  FAIL {name:22}')
            print(f'       设计: {produced.hex(" ").upper()}')
            print(f'       现有: {expected.hex(" ").upper()}')

    # 响应帧解析：按设计描述重建字段偏移
    response = {
        'segments': [
            {'const': '43348888'},
            {'command': True},
            {'reserved': '00'},
            {'length': {'of': 'payload'}},
            {'payload': True},
            {'crc': {'type': 'crc16-modbus', 'endian': 'big'}},
        ]
    }
    payload = bytes([31, 2])
    body = bytearray()
    for segment in response['segments']:
        if 'const' in segment:
            body.extend(bytes.fromhex(segment['const']))
        elif segment.get('command'):
            body.extend(bytes.fromhex('06'))
        elif 'reserved' in segment:
            body.extend(bytes.fromhex(segment['reserved']))
        elif 'length' in segment:
            body.append(len(payload))
        elif segment.get('payload'):
            body.extend(payload)
        elif 'crc' in segment:
            crc = crc16_modbus(bytes(body))
            body.extend(crc.to_bytes(2, 'big'))
    frame_bytes = bytes(body)

    # At5Client.parseResponse 的等价校验：头部 4 + CMD 1 + Reserved 1 + Length 1
    offset = 4 + 1 + 1 + 1
    declared = frame_bytes[6]
    parsed = frame_bytes[offset:offset + declared]
    checks = [
        ('响应帧头', frame_bytes[:4], RESP_HEADER),
        ('命令字节', frame_bytes[4], 0x06),
        ('保留字节', frame_bytes[5], 0x00),
        ('负载长度', declared, len(payload)),
        ('CRC 高位在前', int.from_bytes(frame_bytes[offset + declared:offset + declared + 2], 'big'),
         crc16_modbus(frame_bytes[:offset + declared])),
        ('字段[0] 温度', parsed[0], 31),
        ('字段[1] 风速', parsed[1], 2),
    ]
    for name, produced, expected in checks:
        if produced == expected:
            print(f'  OK   {name:22} {produced!r}')
        else:
            failed += 1
            print(f'  FAIL {name:22} 设计={produced!r} 现有={expected!r}')

    print()
    print(f'{"全部通过" if not failed else f"{failed} 项不一致"}')
    return 1 if failed else 0


if __name__ == '__main__':
    raise SystemExit(main())
