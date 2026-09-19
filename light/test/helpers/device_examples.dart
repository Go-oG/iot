/// 通用设备配置的示例集合
///
/// 这里放的是**样例**，不是标准。通用格式不围绕任何一台设备设计，
/// 不同设备在「有没有命令字节」「有没有长度字段」「用哪种校验」「值怎么编码」上
/// 差别很大，所以示例刻意选了两种结构完全不同的设备来覆盖这些轴：
///
/// - [at5ExampleConfig]：命令帧型。一条特征承载所有命令，报文有帧头、命令字节、
///   保留字节、长度和 CRC16，写入靠通知回报确认。
/// - [thermostatExampleConfig]：寄存器型。一个功能一条特征，没有命令字节也没有
///   长度字段，16 位小端、0.1℃ 步长，校验用 sum8，写入不需要响应。
///
/// 两种设备共用同一份实现和同一套配置字段，任何一侧需要特殊处理都说明设计跑偏了。
library;

/// 命令帧型示例：AT5 灯具
///
/// 规则来自既有 Dart 实现，这里用配置复现它以验证格式的表达力。
const Map<String, Object?> at5ExampleConfig = {
  'id': 'at5-lamp',
  'name': 'AT5 智能灯',
  'chars': {
    'ctrl': {
      'service': '8332af20-6d0e-4eea-bb35-665544332211',
      'char': '8332af20-6d0e-4eea-bb35-665544332211',
    },
  },
  'frame': {
    'segments': [
      {'const': '34438888'},
      {'command': true},
      {'reserved': '00'},
      {
        'length': {'of': 'payload'},
      },
      {'payload': true},
      {
        'crc': {'type': 'crc16-modbus', 'endian': 'big'},
      },
    ],
  },
  'response': {
    'segments': [
      {'const': '43348888'},
      {'command': true},
      {'reserved': '00'},
      {
        'length': {'of': 'payload'},
      },
      {'payload': true},
      {
        'crc': {'type': 'crc16-modbus', 'endian': 'big'},
      },
    ],
  },
  'subscribe': ['ctrl'],
  'commands': {
    'setPower': {
      'char': 'ctrl',
      'command': '05',
      'payload': [
        {
          'field': 'power',
          'as': 'bool',
          'map': {'true': '01', 'false': '00'},
        },
      ],
    },
    'setLight': {
      'char': 'ctrl',
      'command': '03',
      'payload': [
        {'field': 'light.red', 'as': 'percent'},
        {'field': 'light.green', 'as': 'percent'},
        {'field': 'light.blue', 'as': 'percent'},
        {'field': 'light.white', 'as': 'percent'},
        {'field': 'light.uv', 'as': 'percent'},
      ],
    },
    'setClimate': {
      'char': 'ctrl',
      'command': '06',
      'payload': [
        {
          'field': 'temperature',
          'as': 'int',
          'range': [20, 80],
        },
        {
          'field': 'fanSpeed',
          'as': 'enum',
          'map': {'low': '01', 'high': '02'},
        },
      ],
    },
    'setTimer': {
      'char': 'ctrl',
      'command': '04',
      'payload': [
        {
          'field': 'timer.index',
          'as': 'int',
          'range': [1, 2],
        },
        {
          'field': 'timer.enabled',
          'as': 'bool',
          'map': {'true': '01', 'false': '00'},
        },
        {
          'field': 'timer.startHour',
          'as': 'int',
          'range': [0, 23],
        },
        {
          'field': 'timer.startMinute',
          'as': 'int',
          'range': [0, 59],
        },
        {
          'field': 'timer.endHour',
          'as': 'int',
          'range': [0, 23],
        },
        {
          'field': 'timer.endMinute',
          'as': 'int',
          'range': [0, 59],
        },
        {
          'field': 'timer.sunriseSunsetEnabled',
          'as': 'bool',
          'map': {'true': '01', 'false': '00'},
        },
        {
          'field': 'timer.sunriseMinutes',
          'as': 'int',
          'range': [0, 255],
        },
        {
          'field': 'timer.sunsetMinutes',
          'as': 'int',
          'range': [0, 255],
        },
      ],
    },
    'syncTime': {
      'char': 'ctrl',
      'command': '01',
      'payload': [
        {'clock': 'hour'},
        {'clock': 'minute'},
        {'clock': 'second'},
      ],
    },
    'powerAck': {
      'char': 'ctrl',
      'command': '05',
      'kind': 'ack',
      'accept': {'length': 1},
    },
    'lightAck': {
      'char': 'ctrl',
      'command': '03',
      'kind': 'ack',
      'accept': {'length': 1},
    },
    'timerAck': {
      'char': 'ctrl',
      'command': '04',
      'kind': 'ack',
      'accept': {'length': 1},
    },
    'climateState': {
      'char': 'ctrl',
      'command': '06',
      'fields': [
        {
          'index': 0,
          'as': 'int',
          'range': [20, 80],
          'target': 'temperature',
        },
        {
          'index': 1,
          'as': 'enum',
          'map': {'01': 'low', '02': 'high'},
          'target': 'fanSpeed',
        },
      ],
    },
  },
  'functions': [
    {'type': 'power', 'status': false, 'write': 'setPower'},
    {
      'type': 'light',
      'status': {'red': 15, 'green': 15, 'blue': 17, 'white': 25, 'uv': 0},
      'write': 'setLight',
    },
    {'type': 'temperature', 'status': 31, 'write': 'setClimate'},
    {'type': 'fanSpeed', 'status': 'low', 'write': 'setClimate'},
    {
      'type': 'timer',
      'status': {
        'index': 1,
        'enabled': false,
        'startHour': 8,
        'startMinute': 0,
        'endHour': 20,
        'endMinute': 0,
        'sunriseSunsetEnabled': false,
        'sunriseMinutes': 0,
        'sunsetMinutes': 0,
      },
      'write': 'setTimer',
    },
  ],
};

/// 寄存器型示例：简版温控器
///
/// 与 AT5 示例刻意选在相反的取值上，用来证明格式不依赖任何一种设备形态：
///
/// | 维度 | AT5 | 本设备 |
/// | --- | --- | --- |
/// | 命令寻址 | 命令字节 | 每个功能各自的特征 |
/// | 帧结构 | 帧头 + 命令 + 保留 + 长度 + 负载 + CRC | 负载 + 校验 |
/// | 校验 | CRC16-Modbus | sum8 |
/// | 值编码 | 单字节整数 | 16 位小端、0.1℃ 步长 |
/// | 写入确认 | 通知回报 ACK | 不需要响应，靠上报特征更新 |
const Map<String, Object?> thermostatExampleConfig = {
  'id': 'thermostat-01',
  'name': '简版温控器',
  'chars': {
    'setpoint': {'service': 'fff0', 'char': 'fff1'},
    'report': {'service': 'fff0', 'char': 'fff2'},
  },
  'frame': {
    'segments': [
      {'payload': true},
      {
        'crc': {'type': 'sum8', 'of': 'payload'},
      },
    ],
  },
  'response': {
    'segments': [
      {'payload': true},
      {
        'crc': {'type': 'sum8', 'of': 'payload'},
      },
    ],
  },
  'subscribe': ['report'],
  'commands': {
    'setTemperature': {
      'char': 'setpoint',
      'writeType': 'withoutResponse',
      'payload': [
        {
          'field': 'temperature',
          'as': 'int',
          'bytes': 2,
          'endian': 'little',
          'scale': 10,
          'range': [100, 350],
        },
      ],
    },
    'temperatureReport': {
      'char': 'report',
      'fields': [
        {
          'index': 0,
          'length': 2,
          'as': 'int',
          'endian': 'little',
          'scale': 10,
          'range': [100, 350],
          'target': 'temperature',
        },
      ],
    },
  },
  'functions': [
    {'type': 'temperature', 'status': 24.5, 'write': 'setTemperature'},
  ],
};
