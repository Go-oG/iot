# Device Profile JSON 规范

本文说明 `assets/devices/*.json` 中的 Device Profile JSON 如何构造、各字段的含义、默认值以及
当前实现会执行的约束。

Device Profile 是一份设备定义。`Device.fromJson()` / `Device.fromJsonString()` 读取并通过校验后，
会得到可以直接用于属性读写、帧编解码和会话控制的 `Device` 对象。

## 1. 设计原则

一份 Device Profile 同时描述四类信息：

1. 设备标识和匹配规则
2. 属性的逻辑类型、约束、默认值和界面渲染方式
3. BLE 读写通知操作及其服务、特征
4. 请求帧和响应帧的字节模板

协议帧不再使用结构化的 `fields[]`、`order` 或 `match[]` 数组描述，而是使用
`cmd` / `response` 字符串模板。模板中 `${...}` 的出现顺序就是字段顺序。

Device Profile 文件本身必须是标准 JSON：

- 不能使用 JavaScript 风格注释
- 不能保留对象或数组末尾逗号
- 对象键必须使用双引号

模板字符串内部的 `//` 注释规则不属于 JSON 注释，只在解析模板时生效。

## 2. 最小结构

```json
{
  "id": "example",
  "name": "示例设备",
  "properties": {
    "service": "0000fff0-0000-1000-8000-00805f9b34fb",
    "characteristic": "0000fff1-0000-1000-8000-00805f9b34fb",
    "power": {
      "name": "电源",
      "type": "bool",
      "default": false,
      "ui": {"renderer": "switch"},
      "write": {
        "op": "write",
        "mode": "withResponse",
        "cmd": "AA55 ${length:u8} ${value:bool8} ${crc16modbus}"
      },
      "notify": {
        "op": "subscribe",
        "response": "AA55 ${skip:u8} ${value:bool8,at=3}"
      }
    }
  }
}
```

## 3. 顶层字段

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `id` | string | 是 | 设备标识，不能为空。会话、数据库和 MQTT 事件都用它识别设备 |
| `name` | string | 是 | 设备显示名称，不能为空 |
| `match` | array | 否 | 设备匹配规则，默认空数组 |
| `service` | string | 否 | 设备级 BLE service UUID |
| `characteristic` | string | 否 | 设备级 BLE characteristic UUID |
| `frame` | object | 否 | 帧级默认长度和校验范围 |
| `properties` | object | 是 | 属性和 BLE 默认地址的容器，至少要有一个属性 |

### 3.1 BLE 默认地址

`service` 和 `characteristic` 可以写在顶层，也可以写在 `properties` 内：

```json
{
  "service": "fff0",
  "characteristic": "fff1",
  "properties": {
    "power": {}
  }
}
```

或：

```json
{
  "properties": {
    "service": "fff0",
    "characteristic": "fff1",
    "power": {}
  }
}
```

两者含义相同。顶层值优先于 `properties` 中的值。规范化写回时，地址写入 `properties.service`
和 `properties.characteristic`。

`properties` 中的 `service`、`characteristic` 是保留键，不会被当作普通属性。它们的值必须是
字符串。某次操作没有声明自己的地址时会继承设备级地址；继承后仍为空则解析失败。

### 3.2 设备匹配规则

`match` 的每一项结构为：

```json
{
  "type": "serviceUuid",
  "value": "fff0",
  "mask": "ffff"
}
```

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `type` | 是 | `serviceUuid`，兼容 `service` / `serviceUUID`；或 `manufacturerDataPrefix`，兼容 `mfgDataPrefix` |
| `value` | 是 | 匹配值，非空字符串 |
| `mask` | 否 | 按位匹配掩码 |

当 `mask` 存在时，它解码后的字节数必须与 `value` 相同，否则定义失败。

## 4. 属性定义

除 `service`、`characteristic` 外，`properties` 的每个键都是属性 ID：

```json
{
  "properties": {
    "temperature": {
      "name": "温度",
      "description": "环境温度",
      "type": "double",
      "unit": "℃",
      "default": 25.0,
      "constraints": {"min": -20, "max": 80, "step": 0.1},
      "ui": {"renderer": "slider"},
      "permissions": {"write": ["admin"]},
      "read": {},
      "write": {},
      "notify": {}
    }
  }
}
```

### 4.1 通用字段

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `name` | string | 是 | 属性显示名称 |
| `description` | string | 否 | 描述 |
| `type` | string | 是 | 逻辑数据类型 |
| `unit` | string | 否 | 单位，只用于展示 |
| `nullable` | bool | 否 | 是否允许 `null`，默认 `false` |
| `default` | JSON value | 否 | 默认值 |
| `constraints` | object | 否 | 类型约束 |
| `values` | array | 否 | 枚举项，仅 `enum` 可用 |
| `items` | object | 否 | 数组元素定义，仅 `array` 可用 |
| `properties` | object | 否 | 对象子属性，仅 `object` 可用 |
| `ui` | object | 否 | 界面渲染定义 |
| `permissions` | object | 否 | 角色权限定义 |
| `read` | object | 否 | 读操作 |
| `write` | object | 否 | 写操作 |
| `notify` | object | 否 | 订阅通知操作 |
| `service` | string | 否 | 属性级 BLE service 覆盖 |
| `characteristic` | string | 否 | 属性级 BLE characteristic 覆盖 |

默认值的类型和约束不会在 `Device.fromJson()` 阶段递归验证。写入属性时会通过
`ValueValidator` 校验实际值，因此 `default` 也应遵守属性自身的类型和约束。

`nullable: true` 只表示逻辑值校验允许 `null`。BLE codec 仍要求具体的 bool、数字、字符串等
类型；可写属性通常不应依赖 `null` 做协议编码，除非模板不会把该值写入字段。

### 4.2 逻辑类型

| `type` | 兼容写法 | Dart 值 | 额外要求 |
| --- | --- | --- | --- |
| `bool` | `boolean` | `bool` | 无 |
| `int` | `integer` | `int` | 必须是整数，不能是 `1.0` |
| `double` | `decimal` | `num` | 整数和小数都可接受 |
| `string` | `str` | `String` | 无 |
| `enum` | `enumeration` | 枚举值本身 | 必须有非空 `values` |
| `array` | `list` | `List` | 必须有 `items` |
| `object` | `obj` | `Map` | 必须有非空 `properties` |

以下字段只允许出现在对应类型中：

- `values` 只能用于 `enum`
- `items` 只能用于 `array`
- `properties` 只能用于 `object`

### 4.3 constraints

```json
{
  "constraints": {
    "min": 0,
    "max": 100,
    "step": 5,
    "minLength": 1,
    "maxLength": 32,
    "minItems": 1,
    "maxItems": 8,
    "pattern": "^[A-Za-z0-9_-]+$"
  }
}
```

| 字段 | 适用类型 | 约束 |
| --- | --- | --- |
| `min` | `int`、`double` | 下限 |
| `max` | `int`、`double` | 上限 |
| `step` | `int`、`double` | 必须大于 0；步长基准是 `min ?? 0` |
| `minLength` | `string` | 必须大于等于 0 |
| `maxLength` | `string` | 必须大于等于 0，且不能小于 `minLength` |
| `minItems` | `array` | 必须大于等于 0 |
| `maxItems` | `array` | 必须大于等于 0，且不能小于 `minItems` |
| `pattern` | `string` | 必须是合法正则表达式 |

定义阶段只校验约束自身是否矛盾，不检查约束是否适用于当前类型。与自己类型不匹配的约束会被
忽略，因此应只声明适用于该类型的字段。

### 4.4 enum

```json
{
  "type": "enum",
  "default": 1,
  "values": [
    {"value": 1, "label": "低速"},
    {"value": 2, "label": "高速", "description": "最大风速"}
  ]
}
```

约束：

- `values` 不能为空
- 每项的 `value` 不能是 `null`
- 每项的 `label` 必须是非空字符串
- 同一个枚举内不能出现重复 `value`

### 4.5 array

```json
{
  "type": "array",
  "constraints": {"minItems": 1, "maxItems": 8},
  "items": {
    "type": "int",
    "constraints": {"min": 0, "max": 255}
  }
}
```

数组校验会递归检查每一个元素。`minItems`、`maxItems` 先检查数组长度，再执行 `items` 校验。

协议编码时，`items` 的 codec 必须是固定字节长度，因为数组解码需要按固定步长切分元素。

### 4.6 object

```json
{
  "type": "object",
  "default": {"red": 0, "green": 0, "blue": 0},
  "properties": {
    "red": {"type": "int", "constraints": {"min": 0, "max": 255}},
    "green": {"type": "int", "constraints": {"min": 0, "max": 255}},
    "blue": {"type": "int", "constraints": {"min": 0, "max": 255}}
  }
}
```

对象值必须覆盖所有声明的子属性，否则校验失败。当前实现不拒绝额外键，但额外键不会被协议
编解码逻辑主动使用，因此模型应尽量保持对象键集合与声明一致。

当对象 codec 没有通过 `len` 声明固定总长度时，每个子字段 codec 也必须具有固定字节长度。

### 4.7 ui

```json
{
  "ui": {
    "renderer": "slider",
    "config": {}
  }
}
```

支持的 `renderer`：

| `renderer` | 用途 |
| --- | --- |
| `switch` | 布尔值开关 |
| `slider` | 有上下限的数值滑杆 |
| `stepper` | 按步长增减的数值 |
| `segmented` | 枚举分段选择 |
| `color` | 对象颜色通道编辑 |
| `scheduleList` | 定时对象的列表编辑入口 |
| `input` | 按逻辑类型编辑 |
| `hexEditor` | 十六进制字符串编辑 |
| `hidden` | 不显示属性卡片 |

`config` 当前是任意 JSON object，由具体渲染器解释。未声明 `ui` 时，页面会按逻辑类型推断，
通常为：

- `bool` → `switch`
- `enum` → `segmented`
- 有 `min`、`max` 的 `int` / `double` → `slider`
- 其它 → `input`

### 4.8 permissions

```json
{
  "permissions": {
    "read": ["*"],
    "write": ["user", "admin"],
    "notify": ["user", "admin"]
  }
}
```

支持的角色：

- `*`
- `user`
- `admin`
- `factory`

权限数组不能为空，不能包含重复角色。某个权限字段不存在时，表示该角色不限制该操作。权限只
限制“是否允许执行”，不能代替操作能力：没有 `write` 操作时，即使 `permissions.write` 允许，
属性仍然不可写。

## 5. BLE 操作

属性可以声明以下三类操作：

```json
{
  "read": {
    "op": "read",
    "response": "AA55 ${value:u8,at=2}"
  },
  "write": {
    "op": "write",
    "mode": "withResponse",
    "cmd": "AA55 ${value:u8}"
  },
  "notify": {
    "op": "subscribe",
    "response": "AA55 ${value:u8,at=2}"
  }
}
```

### 5.1 操作字段

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `op` | string | `read`、`write`、`subscribe`；兼容 `r`、`w`、`subs` |
| `service` | string | 可选，覆盖设备级或属性级 service |
| `characteristic` | string | 可选，覆盖设备级或属性级 characteristic |
| `mode` | string | 只用于写操作：`withResponse` 或 `withoutResponse` |
| `writeMode` | string | `mode` 的兼容旧写法 |
| `cmd` | string/object | 写操作请求模板，等价于旧字段 `request` |
| `request` | string/object | 兼容旧写法，推荐统一使用 `cmd` |
| `response` | string/object | 响应模板 |
| `timeoutMs` | int | 可选且必须大于 0；当前保留在定义中，超时等待仍由会话的 `ackWindow` 控制 |

写操作没有声明 `mode` 时，会话默认使用 `withResponse`。

### 5.2 操作约束

| 操作 | 要求 |
| --- | --- |
| `read` | 不能是 `subscribe`；必须有 `response`；可以有 `request` |
| `write` | 必须是 `write`；必须有 `cmd` 或 `request`；可以有 `response` |
| `notify` | 必须是 `subscribe`；必须有 `response` |

`request` / `cmd` 可以是模板字符串，也可以使用旧对象形式：

```json
{"template": "AA55 ${value:u8}"}
```

`response` 同理：

```json
{"template": "AA55 ${value:u8,at=2}"}
```

推荐使用字符串形式。只有响应需要覆盖 service 或 characteristic 时，才使用对象形式：

```json
{
  "response": {
    "service": "fff0",
    "characteristic": "fff2",
    "template": "AA55 ${value:u8,at=2}"
  }
}
```

## 6. frame 默认范围

```json
{
  "frame": {
    "lengthSpan": "body",
    "checksumSpan": "all"
  }
}
```

| 字段 | 默认值 | 作用 |
| --- | --- | --- |
| `lengthSpan` | `body` | `${length:...}` 未声明 `span` 时的范围 |
| `checksumSpan` | `all` | 校验字段未声明 `span` 时的范围 |

支持的范围：

| 写法 | 含义 |
| --- | --- |
| `all` | 整帧 |
| `packet` | `all` 的兼容写法 |
| `body` | 长度字段之后到最后一个业务字段 |
| `field(name)` | 单个具名字段 |
| `a..b` | 两个具名字段之间的闭区间 |

`length` 的 `all` 会统计所有活动字段的编码长度，包括 length 和 checksum 字段自身。
`checksum` 的 `all` 表示从帧首到校验字段之前；校验字段不允许使用 `body`。

## 7. 帧模板

### 7.1 按 `${...}` 分割

模板首先按 `${...}` 分割：

```text
34438888 05 00 ${length:u8} ${value:bool8} ${crc16modbus}
```

- `${...}` 是占位符
- 两个占位符之间的内容是一个十六进制字面量段
- `${` 之后到第一个 `}` 之间的内容是占位符定义
- 字面量段中出现 `//` 时，到行尾的内容作为注释忽略

### 7.2 字面量规则

字面量段内：

- 空格、制表符、换行和缩进全部忽略
- `:` 和 `-` 忽略
- `0x` / `0X` 前缀忽略
- 其它字符必须是十六进制字符
- 合并后的十六进制字符数必须是偶数
- 每两个字符组成一个字节

以下写法等价：

```text
aa bbcc
aabbcc
AA:BB-CC
0xAA 0xBB 0xCC
```

请求中，一个字面量段会成为一个常量字段。响应中，一个字面量段会成为一个连续匹配锚点。

### 7.3 占位符基本形式

```text
${kind[.name][:codec][?condition][,option=value...]}
```

示例：

```text
${value:u16be,scale=0.1}
${property.fanSpeed:u8}
${variable.nonce:u16le}
${seq:u8}
${length:u8,span=body}
${crc16modbus,at=-2}
${bitfield:u8,parts=0:const(1);1:value}
```

类型名支持的主要兼容写法：

| 规范名 | 兼容名 | 说明 |
| --- | --- | --- |
| `value` | 无 | 当前操作的主值 |
| `property` | `prop`、`attr` | 引用或解码其它属性 |
| `variable` | `var` | 运行时变量，仅请求使用 |
| `sequence` | `seq` | 请求序号 |
| `timestamp` | `ts` | 时间戳 |
| `length` | `len` | 长度字段 |
| `checksum` | `crc` | 校验字段 |
| `bitfield` | `bits` | 位域 |
| `match` | 无 | 响应显式匹配锚点 |
| `skip` | 无 | 响应跳过字节 |

### 7.4 字段名称

字段名称用于 `length`、`checksum` 的 `span` 引用：

- `property.xxx` 的字段名是 `xxx`
- `variable.xxx` 的字段名是 `xxx`
- `value`、`seq`、`len`、`crc` 等未命名占位符使用默认名
- 可写成 `${value.payload:u8}` 指定字段名为 `payload`
- 同名 `property` / `variable` 不允许出现两次
- 普通类型未显式命名且发生冲突时，会自动生成 `value2`、`crc2` 等名称

### 7.5 编码格式

| 格式 | 字节数 | 说明 |
| --- | --- | --- |
| `bool8` | 1 | 布尔值 |
| `u8` / `i8` | 1 | 无符号 / 有符号整数 |
| `u16` / `i16` | 2 | 默认大端 |
| `u32` / `i32` / `f32` | 4 | 默认大端 |
| `u64` / `i64` / `f64` | 8 | 默认大端 |
| `utf8` | 可变或固定 | 文本 |
| `ascii` | 可变或固定 | ASCII 文本 |
| `bytes` | 可变或固定 | 字节数组，可接受 `Uint8List`、`List<int>` 或十六进制字符串 |
| `array` | 可变 | 数组 |
| `object` | 可变或固定 | 对象 |

多字节格式可以写后缀：

- `u16be` / `u16le`
- `i32be` / `i32le`
- `f64be` / `f64le`

未写后缀时默认大端。

### 7.6 codec 选项

| 选项 | 适用格式 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `scale` | 数值 | `1` | `logical = raw * scale + offset`；不能为 0 |
| `offset` | 数值 | `0` | 逻辑值偏移 |
| `len` | string/bytes/object | 无 | 固定编码长度，必须大于 0 |
| `prefix` | string/array/bytes | 无 | 长度前缀：`u8`、`u16`、`u32` |
| `true` | bool8 | `1` | `true` 的字节值 |
| `false` | bool8 | `0` | `false` 的字节值 |
| `endian` | 多字节格式 | `big` | `big` 或 `little` |
| `items` | array | 无 | 元素 codec，数组必须声明 |
| `fields` | object | 无 | 子字段，格式为 `name:codec;name:codec` |

示例：

```text
${value:u8,true=0xAA,false=0x7F}
```

表示逻辑 `true` 编码成 `AA`，逻辑 `false` 编码成 `7F`。

```text
${value:object,fields=red:u8;green:u8;blue:u8}
```

表示对象依次编码为三个字节。

```text
${value:array,items=u8,prefix=u8}
```

表示数组先写元素数量的 `u8` 前缀，再依次写每个 `u8`。

### 7.7 条件字段

占位符可以附加条件：

```text
${value:u8?power}
${value:u8?power==true}
${value:u8?mode in (1,2)}
${property.flags:u8?flags & 0x04}
${value:u8?not valueExists}
```

条件来源：

- `value`：当前主值
- `property.xxx` / `attr.xxx` / `@xxx` / 裸名字：属性状态
- `variable.xxx` / `var.xxx` / `$xxx`：运行时变量
- `sequence`：请求序号

支持的操作：

| 条件 | 含义 |
| --- | --- |
| `?source` | 来源存在 |
| `?not source` | 来源不存在 |
| `?source==value` | 等于 |
| `?source!=value` | 不等于 |
| `?source>value` | 大于 |
| `?source>=value` | 大于等于 |
| `?source<value` | 小于 |
| `?source<=value` | 小于等于 |
| `?source in (a,b)` | 在集合中 |
| `?source not in (a,b)` | 不在集合中 |
| `?source & mask` | 按位命中 |
| `?not source & mask` | 按位未命中 |

条件在编码前求值。条件不成立的字段完全不参与输出、长度计算和 CRC 计算。

### 7.8 bitfield

```text
${bitfield:u8,parts=0:const(1);1:value;3..4:property.mode}
```

- 位段下标从 0 开始
- 单个数字表示 1 位，例如 `0`
- `a..b` 表示闭区间
- 位段来源可以是 `const(...)`、`value`、`seq`、`property.xxx`、`variable.xxx`
- 位段可以附加条件
- bool 值映射为 1 / 0
- 数值会取整，超出该位段范围会报错
- 最终字节顺序由 codec 的端序决定

## 8. 长度与校验

### 8.1 length

```text
${length:u8}
${length:u16le,span=body}
${length:u8,span=field(value),adjust=-1}
${length:u8,span=header..payload}
```

约束：

- length codec 必须是固定长度
- `field(name)` 和 `a..b` 引用的字段必须存在
- `all` 统计所有活动字段的字节长度
- `body` 从 length 字段之后的第一个字段开始，到最后一个非 length / checksum 字段结束
- `adjust` 会在计算出范围后加上该整数

### 8.2 checksum

```text
${crc16modbus}
${crc16modbus,span=all}
${crc16modbus,span=header..payload}
${crc16modbus,at=-2}
```

请求帧中，校验范围只包含本校验字段之前的活动字段。未指定 `fromOrder` 时从帧首开始；
未指定 `toOrder` 时截止到校验字段之前。

支持的算法：

| 算法 | 字节数 | 说明 |
| --- | --- | --- |
| `sum8` / `checksum8` | 1 | 累加和低 8 位 |
| `xor8` | 1 | 逐字节异或 |
| `crc8` | 1 | 默认 poly `0x07`、init `0x00` |
| `crc16` | 2 | 默认 poly `0x1021`、init `0xFFFF` |
| `crc16modbus` / `modbus` | 2 | Modbus CRC16 |
| `crc16ccittFalse` / `ccitt` | 2 | CCITT-FALSE |
| `crc32` | 4 | CRC32 |

`crc8` 和 `crc16` 可使用：

```text
poly=0x1021,init=0xFFFF,xorOut=0x0000,reflectIn=false,reflectOut=false
```

兼容键：

- `poly` 等价于 `polynomial`
- `reflectin` 等价于 `reflectIn`
- `reflectout` 等价于 `reflectOut`

## 9. 响应模板

响应模板只允许以下内容：

- 十六进制字面量匹配锚点
- `${match:...}`
- `${skip:...}`
- `${value:...}`
- `${property.xxx:...}`
- `${crc...}` / `${checksum...}`

响应字段通常需要 `at=` 指定绝对偏移：

```text
43348888 05 00 ${skip:u8} 00 ${crc16modbus,at=-2}
```

规则：

- `at` 可以是负数，`-1` 表示最后一个字节
- 字面量段自动成为匹配锚点
- 上一个字段宽度不固定时，后续字段必须有显式 `at`
- `${match:AA,mask=F0,at=0}` 可以按掩码匹配
- 一个响应最多一个 `value`
- 多个 `${property.xxx:...}` 可以在一帧中更新多个属性
- 不能同时声明 `value` 和多属性 `property`
- 一个响应最多一个 checksum
- 响应至少要有一个匹配锚点或取值定义
- mask 的字节长度必须等于匹配值长度

响应校验顺序是：匹配锚点全部通过，再校验 checksum，最后解码 value / property。

## 10. 编译、写回与顺序

- 模板在 `Device.fromJson()` 时编译
- 请求中字面量、占位符按出现顺序生成内部 order：`10, 20, 30...`
- 非字面量字段的名称来自属性名、变量名或类型默认名
- `length` / `checksum` 通过字段名引用其它字段，不直接依赖字节偏移
- `Device.toJson()` 会写回规范模板
- 写回时十六进制字面量统一为大写且不带空格
- 兼容输入 `request`、`writeMode` 会写回为 `cmd`、`mode`
- 设备级 BLE 地址会写回到 `properties.service` 和 `properties.characteristic`

模板空白只用于书写。以下命令等价：

```text
aa bbcc ${value:u8}
aabbcc ${value:u8}
AA:BB-CC ${value:u8}
0xAA 0xBB 0xCC ${value:u8}
```

## 11. 示例

### 11.1 bool 映射非 00/01

```json
{
  "name": "电源",
  "type": "bool",
  "default": false,
  "ui": {"renderer": "switch"},
  "write": {
    "op": "write",
    "mode": "withResponse",
    "cmd": "AA55 ${length:u8} ${value:bool8,true=0xAA,false=0x7F} ${crc16modbus}"
  },
  "notify": {
    "op": "subscribe",
    "response": "AA55 ${skip:u8} ${value:bool8,at=3,true=0xAA,false=0x7F}"
  }
}
```

### 11.2 缩放数值

```json
{
  "name": "温度",
  "type": "double",
  "unit": "℃",
  "constraints": {"min": -40, "max": 125, "step": 0.1},
  "read": {
    "op": "read",
    "response": "AA55 ${value:u16le,scale=0.1,at=2}"
  },
  "notify": {
    "op": "subscribe",
    "response": "AA55 ${value:u16le,scale=0.1,at=2}"
  }
}
```

### 11.3 多属性响应

```json
{
  "response": "AA55 ${property.temperature:u16le,at=2} ${property.humidity:u8,at=4}"
}
```

该响应会把同一个包解析成：

```json
{
  "temperature": 23.5,
  "humidity": 60
}
```

## 12. 常见错误

| 错误 | 原因 |
| --- | --- |
| `id must not be empty` | 缺少 `id` 或值为空 |
| `properties must define at least one property` | 没有普通属性 |
| `read operation requires response` | `read` 没有响应定义 |
| `write operation requires request` | `write` 没有 `cmd` 或 `request` |
| `notify operation requires response` | `notify` 没有响应定义 |
| `Unsupported value type` | `type` 不是支持的类型或兼容写法 |
| `enum value must define values` | `enum` 没有 `values` |
| `array value must define items` | `array` 没有 `items` |
| `object value must define properties` | `object` 没有 `properties` |
| `未知的字段类型` | `${...}` 的类型名或前缀不被支持 |
| `十六进制字节不完整` | 合并后的字面量 hex 字符数为奇数 |
| `模板中不支持的字符` | 字面量中存在非 hex 字符 |
| `跨度引用了不存在的字段` | `span=` 使用了未命名或不存在的字段 |
| `校验字段必须能确定偏移` | 响应 checksum 没有可推导的 `at` |
| `响应字段必须能确定偏移` | 动态宽度字段之后没有显式 `at` |
| `Property state not found` | 请求引用了未提供的 `property.xxx` 状态 |
| `Runtime variable not found` | 请求引用了未提供的 `variable.xxx` |

## 13. 编写检查清单

1. `id`、`name`、`properties` 是否完整
2. 每个普通属性是否有 `name` 和合法 `type`
3. `enum`、`array`、`object` 是否满足各自的附属定义
4. `default` 是否符合类型和 `constraints`
5. 是否声明了正确的 `read`、`write`、`notify`
6. 每个操作是否能解析出 service 和 characteristic
7. 请求模板是否有唯一的 value 语义和完整的 length/checksum 范围
8. 响应模板是否包含足够的匹配锚点，且动态字段有明确 `at`
9. bool、整数、浮点数映射是否与设备协议一致
10. 用真实响应样例构造测试，验证“编码字节、匹配、解码属性值”三段结果
