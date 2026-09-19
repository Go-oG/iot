# 通用设备远程读写协议设计

本文补全通用设备（`GenericDevice`）缺失的远程读写通道：给设备配置增加**命令与响应**描述，使 App 能把功能值编码成 BLE 报文经 V1 网关下发，并把读回或通知解析成功能状态。

状态：**已实现。** 现有配置（只有 `type` 和 `status`）继续有效，新字段全部可选；没有声明 `commands` 的配置仍然只支持本地预览。

实现位置：

| 文件 | 作用 |
| --- | --- |
| `lib/src/core/device/checksum.dart` | 校验和，AT5 与通用设备共用 |
| `lib/src/core/device/generic_codec.dart` | 配置解析、校验、编码与解码，不依赖 MQTT |
| `lib/src/core/device/generic_session.dart` | 把编解码接到 V1 网关操作（连接、订阅、写、读） |
| `lib/src/core/device/impl/generic_device.dart` | 构造时校验配置，持有编解码器，提供状态回写 |
| `lib/src/core/device/json_read.dart` | 带字段路径的配置取值函数 |

验证：

- `test/generic_codec_test.dart`：编解码与配置校验。AT5 示例逐字节复现既有 Dart 实现，温控器示例覆盖命令帧之外的形态
- `test/generic_session_test.dart`：用假传输验证两种设备的下发报文、订阅、状态回写与拒绝路径
- `test/helpers/device_examples.dart`：两台结构不同的示例设备，是**样例**不是标准
- `tool/verify_generic_codec.py`：按文档结构独立实现的编码器，与 Dart 实现互相印证

```sh
flutter test test/generic_codec_test.dart test/generic_session_test.dart
PYTHONUTF8=1 python tool/verify_generic_codec.py
```

---

## 1. 问题

当前 `GenericDevice` 的配置只描述设备的**语义**，不描述线上字节：

```json
{
  "id": "lamp-01",
  "functions": [{ "type": "power", "status": true }]
}
```

`bleServices` 只说有哪些服务和特征，不说哪个功能对应哪个特征，更不说 `true` 该编成 `01` 还是 `FF`。因此 `_execute` / `_refresh` 回调无从实现，通用设备无法远程控制。

`At5Client` 能工作，是因为它的编码规则写死在 Dart 里（头部 `34438888`、命令 `0x05`、负载 `[0 或 1]`、CRC16-Modbus 大端）。要让配置驱动控制，这些规则必须变成数据。

## 2. 范围

**只改 App 侧的配置格式。** 网关照旧只做 BLE 原子操作，通用设备复用已有的 `write` / `read` / `subscribe` / `batch`，不需要动固件，也不需要新的 `op`。

网关保持通用、不解析业务报文，这一点不因为通用设备接入而改变：编解码仍全部在 App 内完成，网关看到的只是一串 hex。

## 3. 设计要点

三个决定塑造了整体结构：

1. **帧是设备级属性，不是功能级。** 同一台设备的所有命令共用同一套封包规则（前缀、命令字节、长度、CRC）。逐功能声明会重复五遍且容易漂移。
2. **命令的字节布局只写一次。** 一条线上命令可能同时承载多个功能值（AT5 的 `0x06` 一次写温度和风速），把布局挂在功能上必然重复。
3. **字段路径相对整机状态解析。** `GenericDevice.status` 本来就是 `{功能类型: 值}` 的合并映射，命令的字段名直接按它取，多值命令天然可写。

因此配置里新增三个顶层块：`frame`（请求封包）、`response`（响应封包）、`commands`（命令与响应的字节布局）。

## 4. 结构总览

```json
{
  "id": "at5-lamp",
  "name": "AT5 智能灯",
  "frame":    { "segments": [ ... ] },
  "response": { "segments": [ ... ] },
  "commands": {
    "setPower":   { "command": "05", "payload": [ ... ] },
    "setClimate": { "command": "06", "payload": [ ... ] },
    "getClimate": { "command": "06", "source": "notify", "fields": [ ... ] }
  },
  "subscribe": [ "ctrl" ],
  "chars": { "ctrl": { "service": "8332af20-...", "char": "8332af20-..." } },
  "functions": [
    { "type": "power", "status": false, "write": "setPower" },
    { "type": "temperature", "status": 31, "write": "setClimate" },
    { "type": "fanSpeed", "status": "low", "write": "setClimate" }
  ]
}
```

| 块 | 作用 |
| --- | --- |
| `chars` | 具名特征表，供命令按名字引用，避免重复写长 UUID |
| `frame` | 请求封包规则，作用于所有写命令 |
| `response` | 响应封包规则，作用于所有读回和通知 |
| `commands` | 命令与响应的字节布局，带 `payload` 的是写命令，带 `fields` 的是读命令 |
| `subscribe` | 需要订阅通知的特征名 |
| `functions[].write` | 该功能变化时发送哪条写命令 |

## 5. 特征表 `chars`

```json
"chars": {
  "ctrl": {
    "service": "8332af20-6d0e-4eea-bb35-665544332211",
    "char":    "8332af20-6d0e-4eea-bb35-665544332211"
  },
  "state": { "service": "fff0", "char": "fff1" }
}
```

UUID 支持 16 / 32 / 128 位三种写法，按协议第 7 节归一化，与 `GatewayUuid.normalize` 一致。`service` 省略时使用设备 `bleServices` 中的第一个服务。

## 6. 帧 `frame` 与 `response`

两者结构相同，都是**有序段列表**。段从左到右填充，顺序即字节顺序。

```json
"frame": {
  "segments": [
    { "const": "34438888" },
    { "command": true },
    { "reserved": "00" },
    { "length": { "of": "payload" } },
    { "payload": true },
    { "crc": { "type": "crc16-modbus", "endian": "big" } }
  ]
}
```

### 6.1 段类型

| 段 | 写法 | 说明 |
| --- | --- | --- |
| 常量 | `{"const": "34438888"}` | 固定字节，hex |
| 命令 | `{"command": true}` | 该命令自己的命令字节 |
| 保留 | `{"reserved": "00"}` | 语义上等同于常量，单独命名以便阅读 |
| 长度 | `{"length": {...}}` | 某个区段的字节数 |
| 负载 | `{"payload": true}` | 命令编码出的负载 |
| 校验 | `{"crc": {...}}` | 校验和 |

`command` 段只允许出现一次，且只有 `commands` 中带 `command` 字段的条目能用。`payload` 段只允许出现一次，只有带 `payload` 的写命令能用。

### 6.2 长度段的来源

| `of` | 含义 |
| --- | --- |
| `"payload"` | 负载字节数 |
| `"frame"` | 帧开头到本段之前的字节数 |

```json
{ "length": { "of": "payload", "bytes": 1, "endian": "big", "max": 255 } }
```

`bytes` 默认 1。长度超出 `max` 时报错而不截断。

### 6.3 校验段

```json
{ "crc": { "type": "crc16-modbus", "endian": "big", "of": "frame" } }
```

| `type` | 算法 |
| --- | --- |
| `"crc16-modbus"` | poly `0xA001`，init `0xFFFF`，xorout `0` |
| `"crc16-ccitt"` | poly `0x1021`，init `0xFFFF` |
| `"sum8"` | 逐字节累加取低 8 位 |
| `"xor8"` | 逐字节异或 |
| `"none"` | 不校验 |

`endian` 默认 `"big"`。`of` 默认 `"frame"`（本段之前的全部字节）；`"payload"` 表示只对负载计算。

### 6.4 无帧设备

省略 `frame` 表示负载原样写入特征，不做任何封包。字符型设备、单个开关量设备都属于这一类。

`response` 省略时，不解析响应特征值；写命令的成功与否只由 V1 的 `write` 结果决定。

## 7. 命令 `commands`

```json
"commands": {
  "setPower": {
    "char": "ctrl",
    "command": "05",
    "writeType": "withResponse",
    "payload": [
      { "field": "value", "as": "bool", "map": { "true": "01", "false": "00" } }
    ]
  }
}
```

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `char` | 是 | 目标特征名，取自 `chars` |
| `command` | 否 | 命令字节，帧含 `command` 段时必填 |
| `writeType` | 否 | `withResponse`（默认）/ `withoutResponse` |
| `payload` | 写命令必填 | 负载段列表 |
| `fields` | 读命令必填 | 响应负载的字段列表 |
| `source` | 否 | `notify`（默认）/ `read`，读命令的取值方式 |
| `kind` | 否 | `state`（默认）/ `ack`，见 8.3 |

同一命令既可以有 `payload` 也可以有 `fields`，表示它既写又回。

## 8. 负载与字段段

`payload` 和 `fields` 都是段列表，但语义不同：`payload` 是**从值生成字节**，`fields` 是**从字节提取值**。

### 8.1 取值来源

写命令的 `payload` 段：

| 写法 | 取值 |
| --- | --- |
| `{"field": "value"}` | 当前命令所服务功能的 `status` |
| `{"field": "temperature"}` | 整机状态中 `temperature` 功能的值 |
| `{"clock": "hour"}` | 当前时间，支持 `hour` / `minute` / `second` / `unix` |
| `{"const": "01"}` | 固定字节 |

`field` 省略或写 `"value"` 都表示当前功能自身的状态值（适合只有一个功能使用的命令）。其余字段名按整机状态解析，用点号访问嵌套：灯光通道写 `{"field": "light.red"}`，定时槽位写 `{"field": "timer.index"}`。

字段路径一律相对整机状态，不做「找不到就到当前功能里找」的隐式回退——共享同一条命令的功能不止一个，隐式回退会让读到的值取决于谁在调用。

### 8.2 类型与变换

| `as` | 说明 |
| --- | --- |
| `"bool"` | 配合 `map` 映射到字节 |
| `"int"` | 整数，配合 `bytes` / `endian` |
| `"enum"` | 字符串值，必须配 `map` |
| `"percent"` | 0～100 整数，等价于 `{"as": "int", "range": [0, 100]}` |

公共修饰：

| 字段 | 说明 |
| --- | --- |
| `bytes` | 字节数，默认 1，允许 1 / 2 / 4 |
| `endian` | `big`（默认）/ `little` |
| `range` | `[min, max]`，越界报错 |
| `scale` | 线性缩放，写入时 `round((value - offset) * scale)`，读取时反算 |
| `offset` | 见 `scale`，默认 0 |
| `map` | 显式取值映射，键为状态值，值为字节串 |
| `default` | 字段缺失时使用的值 |

`map` 的键按 JSON 字面量书写：布尔写 `"true"` / `"false"`，枚举写 `"low"` / `"high"`。

`scale` 和 `offset` 覆盖最常见的量化需求，例如设备用 0.5℃ 步长、且 0 表示关闭：

```json
{ "field": "temperature", "as": "int", "scale": 2, "range": [20, 80] }
```

### 8.3 响应类别 `kind`

| `kind` | 含义 |
| --- | --- |
| `"state"` | 响应携带状态，按 `fields` 解析 |
| `"ack"` | 响应只表示接受或拒绝，不解析状态 |

`kind: "ack"` 的命令可以带 `"accept": {"length": 1}` 声明可接受的负载长度；长度不符视为设备拒绝。AT5 的写入确认正是这个形态。

### 8.4 字段提取

```json
"fields": [
  { "index": 0, "target": "temperature", "as": "int", "range": [20, 80] },
  { "index": 1, "target": "fanSpeed", "as": "enum", "map": { "01": "low", "02": "high" } }
]
```

| 字段 | 说明 |
| --- | --- |
| `index` | 负载内起始偏移，从 0 开始 |
| `length` | 读取长度，默认由 `bytes` 推断，否则 1 |
| `target` | 写回哪个功能，对应 `functions[].type`；省略表示不写回，仅用于校验 |
| `as` / `bytes` / `endian` / `range` / `scale` / `offset` / `map` | 与 8.2 相同，方向相反 |

`fields` 里没有 `target` 的项用于校验帧结构（例如检查保留字节是否为 0），解析失败时整帧丢弃。

## 9. 订阅与读取

```json
"subscribe": ["ctrl"],
"commands": {
  "getState": { "char": "state", "source": "read", "fields": [ ... ] }
}
```

- `subscribe` 列出的特征在设备连接后订阅 `delivery: "stream"`，收到的通知按 `response` 解帧，再按命令字节匹配到 `commands` 中对应的读命令
- `source: "read"` 的读命令在 `refresh()` 时发 `read` 请求，响应按同一套 `response` 规则解析
- `source: "notify"` 的读命令不主动请求，只消费订阅到的通知

一个响应可以同时写回多个功能：AT5 的 `0x06` 响应一次给出温度和风速，两条 `fields` 各自带 `target`，一次通知更新两个功能。

## 10. 与 V1 网关操作的映射

不需要新的 `op`。通用设备的每一次操作都落到已有原语：

| 场景 | V1 操作 |
| --- | --- |
| 只写 | `write`（`value` 为编码后的 hex） |
| 写前先订阅、写完等通知 | 单个 `batch`：`subscribe` + `write` |
| 主动读状态 | `read` |
| 连接后建立通知 | `batch` 内的 `subscribe`，或设备连接后单独 `subscribe` |

AT5 当前就是「一个 batch 完成 subscribe + write，再等通知里的 ACK」，通用设备沿用同一条路径，包括 `stopOnError: true` 和写入后用通知确认的时序。

命令字节、CRC、长度都在 App 内算好，网关收到的只是 hex 字符串，与 `At5Client` 现在下发的报文没有任何区别。

编码时使用的状态是**设备当前状态叠加本次新值**：被改动的功能取新值，共享同一条命令的其它功能取各自最后已知的值。AT5 的「改温度必须同时带上风速」正是靠这条规则工作——单独调温度时风速沿用上一次的值，不需要额外的状态副本。

## 11. 状态回写

- 写命令成功**不覆盖**功能状态。这与现有实现一致：`GenericDevice` 只在执行或刷新成功时更新快照，而 V1 的 `write` 成功只代表报文已发出
- `kind: "state"` 的响应按 `fields` 写回对应功能，是唯一能更新状态的来源
- `kind: "ack"` 的响应只影响本次命令的成功/失败判定
- 一个响应写回多个功能时，各功能分别校验自己的 `range`，单项越界只丢弃该项并记录，不丢弃整帧

## 12. 校验规则

配置在构造时校验，错误带字段路径，与现有 `functions[1].status.red` 的风格一致：

- `chars` 引用的特征名必须存在；`service` 省略时设备至少有一个 `bleServices` 项
- 帧最多一个 `command` 段、一个 `payload` 段
- 带 `payload` 的命令必须在 `frame` 有 `payload` 段；反之亦然
- `frame` 有 `command` 段时，每条写命令必须给 `command`；无 `command` 段时不允许给
- `subscribe` 中的特征名必须存在
- 读命令必须有 `fields`；写命令必须有 `payload`
- `fields[].target` 必须对应已声明的功能
- `functions[].write` 必须指向带 `payload` 的命令
- 命令名不得重复；同一功能不得同时出现在两条写命令的必填字段里

构造后 `device.status` 与现有语义一致：初值来自配置，只在执行或刷新成功时更新。

## 13. 示例

**通用格式不围绕任何一台设备设计。** 下面两台设备在寻址方式、帧结构、校验算法和值编码上全部不同，用同一份配置字段和同一套实现跑通；AT5 只是其中一例，它的字节规则仅对 AT5 有效，不构成对其他设备的建议。

| 维度 | 13.1 AT5 灯具 | 13.2 简版温控器 |
| --- | --- | --- |
| 功能寻址 | 命令字节 | 每个功能各自的特征 |
| 帧结构 | 帧头 + 命令 + 保留 + 长度 + 负载 + CRC | 负载 + 校验 |
| 校验 | CRC16-Modbus | sum8 |
| 值编码 | 单字节整数 | 16 位小端、0.1℃ 步长 |
| 写入确认 | 通知回报 ACK | 不需要响应 |

## 13.1 命令帧型：AT5 灯具

这是设计的验收用例之一。AT5 的规则来自 `At5Client`：请求头 `34438888`、响应头 `43348888`、长度字节后接负载、CRC16-Modbus 大端、命令 `0x05` 电源 / `0x03` 亮度 / `0x06` 温控风扇 / `0x04` 定时 / `0x01` 对时。

```json
{
  "id": "at5-lamp",
  "name": "AT5 智能灯",
  "macd": "AA:BB:CC:DD:EE:FF",
  "chars": {
    "ctrl": {
      "service": "8332af20-6d0e-4eea-bb35-665544332211",
      "char": "8332af20-6d0e-4eea-bb35-665544332211"
    }
  },
  "frame": {
    "segments": [
      { "const": "34438888" },
      { "command": true },
      { "reserved": "00" },
      { "length": { "of": "payload" } },
      { "payload": true },
      { "crc": { "type": "crc16-modbus", "endian": "big" } }
    ]
  },
  "response": {
    "segments": [
      { "const": "43348888" },
      { "command": true },
      { "reserved": "00" },
      { "length": { "of": "payload" } },
      { "payload": true },
      { "crc": { "type": "crc16-modbus", "endian": "big" } }
    ]
  },
  "subscribe": ["ctrl"],
  "commands": {
    "setPower": {
      "char": "ctrl",
      "command": "05",
      "payload": [
        { "field": "value", "as": "bool", "map": { "true": "01", "false": "00" } }
      ]
    },
    "setLight": {
      "char": "ctrl",
      "command": "03",
      "payload": [
        { "field": "light.red",   "as": "percent" },
        { "field": "light.green", "as": "percent" },
        { "field": "light.blue",  "as": "percent" },
        { "field": "light.white", "as": "percent" },
        { "field": "light.uv",    "as": "percent" }
      ]
    },
    "setClimate": {
      "char": "ctrl",
      "command": "06",
      "payload": [
        { "field": "temperature", "as": "int", "range": [20, 80] },
        { "field": "fanSpeed", "as": "enum", "map": { "low": "01", "high": "02" } }
      ]
    },
    "setTimer": {
      "char": "ctrl",
      "command": "04",
      "payload": [
        { "field": "index", "as": "int", "range": [1, 2] },
        { "field": "enabled", "as": "bool", "map": { "true": "01", "false": "00" } },
        { "field": "startHour", "as": "int", "range": [0, 23] },
        { "field": "startMinute", "as": "int", "range": [0, 59] },
        { "field": "endHour", "as": "int", "range": [0, 23] },
        { "field": "endMinute", "as": "int", "range": [0, 59] },
        { "field": "sunriseSunsetEnabled", "as": "bool", "map": { "true": "01", "false": "00" } },
        { "field": "sunriseMinutes", "as": "int", "range": [0, 255] },
        { "field": "sunsetMinutes", "as": "int", "range": [0, 255] }
      ]
    },
    "syncTime": {
      "char": "ctrl",
      "command": "01",
      "payload": [
        { "clock": "hour" },
        { "clock": "minute" },
        { "clock": "second" }
      ]
    },
    "powerAck":  { "char": "ctrl", "command": "05", "kind": "ack", "accept": { "length": 1 } },
    "lightAck":  { "char": "ctrl", "command": "03", "kind": "ack", "accept": { "length": 1 } },
    "timerAck":  { "char": "ctrl", "command": "04", "kind": "ack", "accept": { "length": 1 } },
    "climateAck": { "char": "ctrl", "command": "06", "kind": "ack", "accept": { "length": 1 } },
    "deviceState": {
      "char": "ctrl",
      "command": "01",
      "fields": [
        { "index": 0, "as": "int" }, { "index": 1, "as": "int" },
        { "index": 2, "as": "int" }, { "index": 3, "as": "int" },
        { "index": 4, "as": "int" }, { "index": 5, "as": "int" },
        { "index": 6, "as": "int" }, { "index": 7, "as": "int" }
      ]
    }
  },
  "functions": [
    { "type": "power", "status": false, "write": "setPower" },
    { "type": "light", "status": { "red": 15, "green": 15, "blue": 17, "white": 25, "uv": 0 }, "write": "setLight" },
    { "type": "temperature", "status": 31, "write": "setClimate" },
    { "type": "fanSpeed", "status": "low", "write": "setClimate" },
    { "type": "timer", "status": { "index": 1, "enabled": false, "startHour": 8, "startMinute": 0, "endHour": 20, "endMinute": 0, "sunriseSunsetEnabled": false, "sunriseMinutes": 0, "sunsetMinutes": 0 }, "write": "setTimer" }
  ]
}
```

逐项核对 `At5Client` 的输出：

- 电源：`34 43 88 88 | 05 | 00 | 01 | 01 | CRC` — 与 `setPower` 一致
- 亮度：`34 43 88 88 | 03 | 00 | 05 | R G B W UV | CRC` — 与 `setBrightness` 一致，五路 0～100 直接落字节
- 温控风扇：`34 43 88 88 | 06 | 00 | 02 | TEMP FAN | CRC` — 与 `setTemperatureAndFan` 一致
- 定时：`34 43 88 88 | 04 | 00 | 09 | 9 字节 | CRC` — 与 `setTimer` 一致
- 对时：`34 43 88 88 | 01 | 00 | 03 | HH MM SS | CRC` — 与 `syncTime` 一致
- 写入确认：命令字节相同、负载长度为 1 时判为 ACK — 与 `_resolveResponseType` 一致
- 设备状态：命令 `0x01`、负载长度 8 时解析为状态 — 与 `_resolveResponseType` 的 `deviceStatus` 一致

**AT5 的「温度与风速必须同发」在这里自然解决**：两者都指向 `setClimate`，命令的负载从整机状态取两个字段。功能只改其中之一时，另一个取当前状态值，行为与 `At5Client` 用 `_lastWrittenStatus` 补齐等价，且不需要额外的状态副本。

## 13.2 寄存器型：简版温控器

一个功能一条特征，没有命令字节、没有长度字段、没有帧头，写入不需要响应。用来验证格式不依赖命令帧这一种形态。

```json
{
  "id": "thermostat-01",
  "name": "简版温控器",
  "chars": {
    "setpoint": { "service": "fff0", "char": "fff1" },
    "report":   { "service": "fff0", "char": "fff2" }
  },
  "frame": {
    "segments": [
      { "payload": true },
      { "crc": { "type": "sum8", "of": "payload" } }
    ]
  },
  "response": {
    "segments": [
      { "payload": true },
      { "crc": { "type": "sum8", "of": "payload" } }
    ]
  },
  "subscribe": ["report"],
  "commands": {
    "setTemperature": {
      "char": "setpoint",
      "writeType": "withoutResponse",
      "payload": [
        { "field": "temperature", "as": "int", "bytes": 2, "endian": "little",
          "scale": 10, "range": [100, 350] }
      ]
    },
    "temperatureReport": {
      "char": "report",
      "fields": [
        { "index": 0, "length": 2, "as": "int", "endian": "little",
          "scale": 10, "range": [100, 350], "target": "temperature" }
      ]
    }
  },
  "functions": [
    { "type": "temperature", "status": 24.5, "write": "setTemperature" }
  ]
}
```

编码结果：

| 状态 | 字节 | 说明 |
| --- | --- | --- |
| 24.5℃ | `f5 00 f5` | 245 = `0x00F5` 小端，末字节是 sum8 校验 |
| 20.0℃ | `c8 00 c8` | 200 = `0x00C8` |
| 35.0℃ | `5e 01 5f` | 350 = `0x015E` |
| 上报 `11 01 12` | 27.3℃ | 273 = `0x0111`，除以 10 |

`scale: 10` 把摄氏度换算成设备的 0.1℃ 整数，`range` 比较换算后的整数。写入落在 `setpoint`，上报来自 `report`，两条命令的目标特征不同。

没有长度字段时，负载长度按「剩余字节减去其后的校验字段」推断，因此 `payload` 段后面必须能算出校验字段的大小。

## 14. 最小配置：单特征开关

没有帧、没有 CRC、没有响应解析，只有一条写命令：

```json
{
  "id": "switch-01",
  "name": "通用开关",
  "chars": { "sw": { "service": "fff0", "char": "fff1" } },
  "commands": {
    "setPower": {
      "char": "sw",
      "payload": [{ "field": "value", "as": "bool", "map": { "true": "01", "false": "00" } }]
    }
  },
  "functions": [{ "type": "power", "status": false, "write": "setPower" }]
}
```

下发时就是一个 `write`，`value` 为 `01` 或 `00`。省略 `frame` 即不做封包，省略 `response` 即不解析回包。

## 15. 兼容性

- 现有配置（只有 `id` / `name` / `macd` / `bleServices` / `functions[].type` / `functions[].status`）解析结果不变，新字段全部可选
- 没有 `commands` 的配置等同「仅本地配置与预览」，与当前行为一致，不假装可远程控制
- `toJson()` 只输出实际声明的块，空块不写回，避免配置在编辑往返中膨胀
- 配置文件仍然不出现任何 Dart 类型名

## 16. 未覆盖的能力

明确不做，遇到时需要扩展设计而不是硬套：

| 能力 | 原因 |
| --- | --- |
| 变长负载 | 长度段只能声明固定区段的字节数，无法表达「按值决定负载长度」 |
| 分片写入 | V1 单次写不超过协商 MTU，长报文的分片语义应由设备协议自行定义 |
| 多帧事务 | 一条命令要求多个写 + 多个读的严格事务，仍应写成多条命令由上层编排 |
| 位域 | 只支持整字节字段，位级打包需要新增段类型 |
| 动态字段偏移 | 偏移必须静态可算，不支持依赖前序字段值的偏移 |
| 校验之外的加密与签名 | 属于安全层，不在本文范围 |
