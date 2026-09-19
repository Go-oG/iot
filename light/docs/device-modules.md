# 设备控制模块

设备通过 `Device.onSupportFunctions()` 声明功能组合。首页遍历当前设备的功能列表构建控件，由应用绑定决定命令如何下发，不再直接调用 AT5 的组包方法。

## 职责

| 层级 | 实现 | 职责 |
| --- | --- | --- |
| 功能 | `DeviceFunction<T>`、`ValueDeviceFunction<T>` | 功能状态、优先级、执行与刷新、控制组件 |
| 设备 | `Device<T>`、`At5Client`、`GenericDevice` | 设备身份、功能组合、协议编解码；`At5Client` 同时实现 `RemoteDeviceCodec`，自己生成与解析 AT5 报文 |
| 会话 | `DeviceRemoteSession`、`GenericDeviceSession` | 每台设备一个会话：订阅转发来的网关事件、认领属于自己的回报、组装 `batch` 下发并回报结果 |
| 设备管理 | `DeviceRegistryService` | 登记列表、扫描与附近设备、当前控制设备；只通过通道收发，不解析任何设备协议 |
| 通道 | `RemoteGateway` | 远端 MQTT 通道：连接、请求-响应收发、事件转发 |
| 协议 | `GatewayClient` | 帧编解码、请求关联、去重、状态缓存、在线判定 |
| 传输 | `MqttService` | MQTT 连接、订阅与发布，是唯一可替换的传输层 |
| 应用绑定 | `DeviceControlScope`、`AppController.controlBindings` | 将模块控件接入本机设置、输出限幅与 MQTT 下发 |

设备不再区分“蓝牙优先”和“远程”两条路线：扫描、连接与读写全部经 MQTT 下发到 ESP32 网关，报文由设备客户端自己在 App 内编解码，网关只做十六进制读写。

控制链路是单向的：用户操作设备客户端 → 客户端生成报文 → 会话组装 `batch` → `RemoteGateway` 发到 MQTT；反向则由 `RemoteGateway` 订阅上行事件并原样转发，`AppController` 创建的各设备会话按 `deviceId` 认领、解码并刷新界面。`RemoteGateway` 里既没有具体设备的类型，也不持有设备状态：登记与扫描生命周期属于 `DeviceRegistryService`（经 `AppScope.of(context).deviceRegistry` 访问），界面与设备会话都从这里取设备列表和在线状态。

`supportFunctions` 是不可修改的列表，按 `Priority` 从高到低排列，相同优先级保持声明顺序。每个设备持有独立的功能实例和状态。

## 组装现有功能

在设备中实现 `onSupportFunctions()`，例如只提供电源和灯光：

```dart
@override
List<DeviceFunction> onSupportFunctions() => [
  PowerFunction(executeCall: (_, value) => sendPower(value)),
  LightFunction(executeCall: (_, value) => sendLight(value)),
];
```

回调必须完成实际写入，成功后返回 `true`，失败则抛出异常或返回 `false`。仅生成协议字节不算执行成功。`ValueDeviceFunction.execute()` 在回调成功后更新功能状态。没有实现状态查询时，`refresh()` 返回 `false`。

远端下发通过设备会话完成：

```dart
final session = DeviceRemoteSession(
  gateway: gateway,
  codec: at5Client,          // 设备自己实现 RemoteDeviceCodec
  deviceId: 'AA:BB:CC:DD:EE:01',
);
final result = await session.execute(DeviceCommand.setState, payload);
```

设备未组装对应功能时抛出 `UnsupportedError`，没有连接时拒绝执行。现有 `setPower`、`setLightState`、`setTimer` 等便捷方法通过扩展方法转发到通用入口。

## 从 JSON 创建通用设备

`GenericDevice.fromJson()` 接收已解析的 JSON 对象，`GenericDevice.fromJsonString()` 接收 JSON 字符串。它们会创建现有的功能模块并沿用相同的卡片分组。

配置字段、回调和接入方式见 [通用设备配置](generic-device.md)，完整示例见 [generic-device.json](examples/generic-device.json)。

## 添加新设备或功能

1. 继承 `Device<T>`，实现设备身份、初始化、连接生命周期和功能列表
2. 实现协议编解码：把功能值编码成目标设备的报文或特征值
3. 让设备实现 `RemoteDeviceCodec`（`remoteService`、`remoteCharacteristic`、`buildRemoteSteps`、`decodeRemoteFrame`），由会话按命令字节认领回报；`RemoteGateway` 不需要任何改动
4. 复用已有功能类即可复用现有控件和应用绑定；新增功能可继承 `ValueDeviceFunction<T>` 实现自己的控件
5. 新功能需要本机持久化或远程控制时，在 `AppController.controlBindings` 增加绑定并接入相应业务逻辑和远程协议

模块控件通过 `control(context, device)` 获取读值、预览和提交回调。应用内由绑定负责保存设置及选择传输路线；独立使用设备卡片时，默认绑定更新模块本地值并直接执行设备功能。滑块预览值不代表硬件已确认，提交失败会显示错误。

## 组件组装与视觉规范

模块通过 `controlGroup` 声明视觉分组：电源使用 `primary`，灯光使用 `lighting`，温控与风速使用 `climate`，其他功能默认使用 `other`。同组功能共用一张卡片，组间顺序由首个功能的优先级决定，组内保留功能排序。

组装层统一负责卡片背景、内边距、组间距和组内分隔线，模块本身只构建内容，不再嵌套卡片。隐藏功能不生成占位；单个功能不会附带尾部间距或分隔线。`CardSize.small` 会收紧间距，并省略灯光的通道明细。

新增控件优先复用 `DeviceControlHeading` 和 `DeviceControlValue`，保持图标、标题、状态文字及数值对齐。页面仅给控制区添加外边距。布局测试覆盖 320 像素窄屏、1.6 倍字体和多种模块组合。

## AT5 约束

- 电源、灯光、温度、风速是可见模块
- 定时使用 `TimerFunction` 执行，入口沿用计划页面
- AT5 的温度与风速共用 `0x06` 指令，因此额外组装无独立控件的 `TemperatureFanFunction`，一次写入两个参数
- 单独操作温度或风速时保留另一项最后成功写入的值；写入失败不会更新该记录
- 网关离线时的控制面板仍采用 AT5 组合，用于本机设置；离线时命令不下发，界面给出提示
- 写入成功只表示报文已被网关发给设备，灯具的实时状态回读尚未接通；收到任意一条灯具确认时结果标记为 `device_ack`，否则为 `written`

## 验证

```sh
flutter analyze --no-pub
flutter test --no-pub
```

自动测试覆盖模块排序与缺失能力、控件绑定、输出上限、协议帧与 CRC、温度风速组合、写入失败、定时参数、网关连接，以及仅电源设备的应用控制流程。真实 MQTT 联调测试仍需单独启用 `MQTT_SMOKE` 并启动 broker 和模拟器。
