# 设备模块与设备模型

设备接入只有一条链路：一份设备模型 JSON 描述属性和报文，`DeviceModelSession` 负责下发与
解析，`DeviceModelPage` 按模型渲染界面。App 里没有按设备类型分叉的 Dart 代码。

## 分层与职责

| 层级 | 实现 | 职责 |
| --- | --- | --- |
| 设备模型 | `DeviceModel`、`DeviceModelRuntime` | 解析与校验定义；按字段、长度、校验和编码写入；按响应定义校验并解析上报 |
| 模型目录 | `DeviceModelCatalog` | 启动时读取 `assets/devices/*.json`，运行期按标识取用 |
| 会话 | `DeviceModelSession` | 每台设备一个会话：连接与订阅、FIFO 队列、批量下发、上报去重与新鲜度、下发记录 |
| 动态界面 | `DeviceModelPage` | 按 `ui.renderer` 生成控件，按能力与角色权限决定可用动作，展示上报值、期望值与下发记录 |
| 设备管理 | `DeviceRegistryService` | 登记、扫描、附近设备、当前控制设备；只通过通道收发，不解析设备协议 |
| 通道 | `RemoteGateway` | 远端 MQTT 通道：连接、请求-响应收发、事件转发 |
| 协议 | `GatewayClient` | 帧编解码、请求关联、去重、状态缓存、在线判定 |
| 传输 | `MqttService` | MQTT 连接、订阅与发布，是唯一可替换的传输层 |
| 应用状态 | `AppController` | 本机数据与每台设备的会话；不保存任何灯光面板状态 |

设备不再区分「本地蓝牙」和「远程」两条路线：扫描、连接与读写全部经 MQTT 下发到 ESP32，
报文由 App 内的设备模型编解码，网关只做十六进制读写。

## 设备模型 JSON

一个属性包含逻辑类型、约束、界面渲染器与读写通知操作：

```json
{
  "id": "at5",
  "name": "AT5 智能灯",
  "properties": {
    "channels": {
      "name": "五路灯光",
      "type": "object",
      "default": {"red": 15, "green": 15, "blue": 17, "white": 25, "uv": 0},
      "properties": {
        "red": {"type": "int", "constraints": {"min": 0, "max": 100}}
      },
      "ui": {"renderer": "color"},
      "write": {
        "op": "write",
        "service": "...",
        "characteristic": "...",
        "request": {
          "template": "34438888 03 00 ${length:u8} ${value:object,fields=red:u8;green:u8;blue:u8;white:u8;uv:u8} ${crc16modbus}"
        }
      },
      "notify": {
        "op": "subscribe",
        "service": "...",
        "characteristic": "...",
        "response": {"template": "43348888 03 00 ${skip:u8} 00 ${crc16modbus,at=-2}"}
      }
    }
  }
}
```

- 逻辑类型：`bool`、`int`、`double`、`string`、`enum`、`array`、`object`，支持范围、步长、
  枚举、长度、条数与嵌套必填校验
- 请求帧与响应帧都用**字符串模板**描述，见下一节；`fields[]` / `order` / `match` 不再出现在模型里
- `permissions` 是角色权限，与属性的读写能力分开；AT5 定义见 [assets/devices/at5.json](../assets/devices/at5.json)

## 帧模板

模板里十六进制字节是字面量，`${...}` 是占位符；**出现顺序就是帧内顺序**，不需要再写 `order`，
跨度与校验范围按字段名引用：

```
AA55 ${length:u8} ${seq:u8} 2103 ${value:u16be,scale=0.1} ${crc16modbus}

34438888 06 00 ${length:u8} ${value:u8} ${property.fanSpeed:u8} ${crc16modbus}
43348888 05 00 ${skip:u8} 00 ${crc16modbus,at=-2}   // 响应：字面量自动成为匹配锚点
```

| 写法 | 含义 |
| --- | --- |
| `AA55`、`0xAA 0x55` | 常量字段（响应方向是匹配锚点） |
| `${value:u16be,scale=0.1}` | 本帧主值，可写字段名：`${value.payload:u8}` |
| `${property.fanSpeed:u8}` / `${@fanSpeed:u8}` | 引用同一批次里其它属性的当前值补帧 |
| `${variable.nonce:u16le}` / `${$nonce:u16le}` | 会话级运行时变量 |
| `${sequence:u8}` / `${seq:u8}` | 请求序号 |
| `${timestamp:u32be,unit=seconds}` | 时间戳，单位可为 `seconds` / `milliseconds` |
| `${length:u8}` | 长度字段，默认跨度由模型配置决定，见下 |
| `${crc16modbus}` | 校验字段，默认从帧首统计到本字段之前 |
| `${bitfield:u8,parts=0:const(1);1:value;3..4:property.mode}` | 位域，`0` 表示 1 位，`3..4` 是闭区间 |
| `${skip:u8}` | 响应方向占位，只跳过不取值 |
| `${match:05,mask=0F,at=4}` | 响应方向的显式匹配锚点 |
| `${...:u8?power==true}` | 条件字段，条件不成立时整个字段不参与长度与校验 |

字面量按空白分组：`43348888 05 00` 是三个字段，写回模板时保持同样分组，因此模型文件与
编辑器保存的内容不会出现格式漂移（见 `frame_template_test.dart` 的规范化用例）。

条件支持 `?属性`（存在性）、`?a==b`、`?a!=b`、`?a > >= < <=`、`?a in (1,2)`、`?a & 0x04`
以及 `not` 组合；位域里的每个位段也可以带上同样的条件。对象与数组用
`${value:object,fields=a:u8;b:u16le}`、`${value:array,items=u8,prefix=u8}` 表达。

### 长度与校验的范围

裸写 `${length:u8}` 与 `${crc16modbus}` 时使用模型里的默认跨度，因为不同协议对「长度」的
定义并不一致：

```json
{
  "id": "demo",
  "frame": {"lengthSpan": "body", "checksumSpan": "all"}
}
```

| 跨度写法 | 含义 |
| --- | --- |
| `body` | 长度字段之后到最后一个业务字段（常见 payload 长度，默认） |
| `all` | 整帧，含长度与校验字段自身（校验默认：帧首到本字段之前） |
| `field(名字)` | 某个字段编码后的字节数 |
| `a..b` | 具名闭区间 |

单帧需要覆盖时写 `span=`，例如 `${length:u8,span=field(value),adjust=-1}`；`adjust` 用于
`长度 = 实际长度 + 固定值` 的协议。

### 编译与写回

模板在模型载入时编译成运行时结构（`PacketEncodeSpec` / `PacketDecodeSpec`），编码与解码引擎
不变；`DeviceModel.toJson()` 会把结构写回规范模板，因此模型编辑器保存、备份导出都保持模板
形式，字段名、跨度、端序都会显式写出。编译期错误带行列位置，覆盖未知字段类型或选项、跨度
引用不存在的字段、字段名重复、长度字段不是固定宽度、校验范围包含自身、
响应模板里动态宽度字段之后缺少 `at=` 等情况。

## 界面渲染器

`DeviceModelPage` 按 `ui.renderer` 生成控件，未声明时按类型推断：

| renderer | 控件 |
| --- | --- |
| `switch` | 布尔属性开关 |
| `slider` | 有 min/max 的数值滑杆 |
| `stepper` | 按 step 加减的数值 |
| `segmented` | 枚举分段选择 |
| `color` | 对象属性，每个数值子属性一条通道 |
| `input` / `hexEditor` | 弹出取值对话框，按类型递归生成输入 |
| `scheduleList` | 定时对象，弹出取值对话框 |
| `hidden` | 不生成控件，只参与读写 |

不可写的属性只展示上报状态与「读取」按钮，不生成写入控件。

## 命令下发与响应解析

- 写入值先用 `ValueValidator` 按模型校验，再用 `DeviceModelRuntime.encodeWrite` 编码；
  帧内 `kind = property` 字段从同一批次的取值优先、其次设备已知状态补齐
- 同一批次的属性互相可见，编码结果相同的重复报文只写一条，多步写入合成一次 `batch`
- 写入结果只有 `written`（网关完成 GATT 写入）、`device_ack`（回包命中响应定义）、
  `device_state`（回包同时带来上报属性）三种升级等级，其余为结果未确认
- 缺少任一步骤结果、步骤标识不一致、队列已满、断线都按未确认处理，不冒充成功
- 上报值按连接纪元、设备顺序号、接收时间与有效期判断新鲜度；过期、未校验、
  其它设备和 retained 报文都不参与状态更新

## 应用状态里的属性值

本机数据只保存属性值，没有面板状态：

- 配色（`ScenePreset.properties`）与计划（`SchedulePlan.properties`）保存属性值，
  应用配色与切换计划就是经 `DeviceModelSession` 写入这些属性
- 计划的定时槽位写进模型的 `timer` 对象属性，下发前先写 `time` 属性对时；
  超出模型索引约束的计划只保存在本机
- 输出上限不是持久设置：模型声明可写的 `outputLimit` 属性时写该属性，
  否则把当前数值属性按上限收敛后写回设备
- 配色对话框按当前设备模型的颜色属性生成通道滑杆，卡片摘要由属性值推导
- 控制器只按 `(gatewayId, deviceId)` 缓存设备会话，不保存灯光参数

## 添加新设备

1. 在 `assets/devices/` 新增一份模型 JSON，声明属性、帧字段、响应匹配与界面渲染器
2. 用假 MQTT 测试覆盖编码字节与响应匹配，参考 [AT5 设备定义测试](../test/device_model_at5_test.dart)
3. 运行时也可以「设备页 → 编辑设备模型」或「新建 / 导入物模型」写入本机配置，
   同一份 JSON 可导出、备份与分享
4. 需要新的交互形态时，在模型里声明新的 `ui.renderer` 并在 `DeviceModelPage` 实现渲染，
   不要为单台设备写专用页面

## 验证

```sh
flutter analyze --no-pub
flutter test --no-pub
```

自动测试覆盖模型解析与校验、逐字节编码、响应匹配、队列与断线、上报与期望值分离、
动态页面渲染、配色与计划的属性值往返，以及数据库不再保留设置表。
真实 MQTT 联调测试需要单独启用 `MQTT_SMOKE` 并启动 broker 与模拟器。
