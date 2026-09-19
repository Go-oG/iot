# JSON 初始化通用设备

`lib/src/core/device/generic_device.dart` 提供 `GenericDevice extends Device<Map<String, Object>>`，可直接从配置创建身份、BLE 服务、功能模块和初始状态。它复用现有的 `PowerFunction`、`LightFunction` 等具体类型，支持既有的功能查找、通用执行入口和卡片分组。

配置描述设备的语义（有哪些功能、初值是什么）和字节层（命令怎么编码）。只写语义时设备仅支持本地配置与预览；补上 `chars` / `frame` / `response` / `commands` 并给功能绑定 `write` 之后，App 就能把功能值编码成 BLE 报文经 MQTT 网关下发。字段与校验规则见 [通用设备远程读写协议设计](generic-device-codec.md)。

## 创建对象

```dart
import 'package:light/src/core/device/generic_device.dart';

final device = GenericDevice.fromJson({
  'id': 'lamp-01',
  'name': '书房灯',
  'functions': [
    {'type': 'power', 'status': true},
    {'type': 'temperature', 'status': 31},
    {'type': 'fanSpeed', 'status': 'low'},
  ],
});
```

已有 JSON 字符串时，使用 `GenericDevice.fromJsonString(jsonText)`。两种入口都是同步构造，返回时功能初值和 `device.status` 已就绪，无需先调用 `init()` 才能构建卡片：

```dart
final panel = device.buildDeviceCart(context, CardSize.large);
```

完整配置见 [generic-device.json](examples/generic-device.json)。配置文件无需写任何 Dart 类型名。

## 在应用中编辑配置

入口位于 **设备 → 功能配置 → 新建 / 导入**。已有配置可点击名称继续编辑，已保存设备的更多操作菜单也提供 **编辑功能** 入口。

- 编辑设备名称、标识和地址
- 添加、修改或删除六种内置功能，同种功能不能重复添加
- 使用开关、亮度滑块、风速选项和时间选择器调整初始值
- 删除草稿中的功能后可撤销
- 在“效果预览”查看实际模块分组和初始状态
- 从 JSON 文件导入，或粘贴 JSON 文本；非法配置会保留当前草稿
- 在“JSON”页查看、编辑和复制完整配置，包括 BLE 服务信息
- 导出当前草稿为可直接传给 `GenericDevice.fromJsonString()` 的 JSON

导入操作只载入编辑草稿，点击“保存”后才写入本机。更改设备标识会更新原配置；如果与其他已保存配置冲突，保存会报错并保留原数据。离开未保存的编辑页时会询问是否放弃修改。

配置保存在 SQLite 中，重启后仍可编辑，也会随应用的整包备份导出、恢复。预览展示初始值，实际设备控制仍由协议回调负责。

## 字段

| 字段 | 是否必填 | 说明 |
| --- | --- | --- |
| `id` | 是 | 非空设备标识 |
| `name` | 是 | 非空设备名称 |
| `macd` | 否 | 地址或 MAC，默认使用 `id` |
| `bleServices` | 否 | 服务数组，默认空数组 |
| `functions` | 是 | 功能数组，允许为空，同种功能不能重复声明 |

每个 BLE 服务包含 `uuid`、`name` 和 `characteristicList`，每个特征包含 `uuid`、`name`。服务和特征描述用于设备元数据；真实传输由回调负责。

每个功能包含必填的 `type` 和可选的 `status`。省略 `status` 时使用原功能模块的默认初值；显式填写时必须符合以下结构：

| `type` | `status` 格式 | 校验范围 | 对应模块 |
| --- | --- | --- | --- |
| `power` | `true` / `false` | 布尔值 | `PowerFunction` |
| `light` | `{ "red": 15, "green": 15, "blue": 17, "white": 25, "uv": 0 }` | 五路均为 0～100 整数，字段必须完整 | `LightFunction` |
| `temperature` | `31` | 20～80 数值，单位 ℃ | `TemperatureFunction` |
| `fanSpeed` | `"low"` / `"high"` | 两档风速 | `FanSpeedFunction` |
| `fanSpeedPercent` | `50` | 0～100 整数 | `FanSpeedFunction2` |
| `timer` | 定时对象，见完整配置 | 编号 1～2，小时 0～23，分钟 0～59，渐变分钟 0～255 | `TimerFunction` |

模块保留既有的优先级、视觉分组和控件样式。定时仍通过计划页面操作，无独立卡片。未知功能、重复功能、缺少必填字段或非法状态会抛出含字段路径的 `FormatException`，例如 `functions[1].status.red`。

## 接入执行与连接

配置负责描述设备。构造函数的可选回调负责连接与具体协议：

| 回调 | 参数 | 返回值 |
| --- | --- | --- |
| `execute` | 设备、功能 `type`、JSON 状态值 | 成功返回 `true`，失败返回 `false` 或抛出异常 |
| `refresh` | 设备、功能 `type` | 新的 JSON 状态值，无可用数据时返回 `null` |
| `connect` | 设备 | 连接成功返回 `true` |
| `disconnect` | 设备 | 断开成功返回 `true` |

**配置里声明了 `commands` 时通常不用手写这些回调**：`GenericDeviceSession` 会按配置自动接上，把功能值编码后经 MQTT 网关下发，并把设备回报的状态写回功能。只有自定义传输（例如不经网关直连）才需要自己实现。

所有回调均支持同步或异步返回。`execute` 和 `refresh` 的状态格式与配置的 `status` 一致，例如风扇使用字符串 `high`，灯光使用五路通道对象。执行值和刷新值都会验证范围。

下面是仅支持电源的设备适配示例，`writePower` 由调用方提供，完成实际传输后才返回：

```dart
GenericDevice createPowerDevice(Future<void> Function(bool) writePower) {
  return GenericDevice.fromJson(
    {
      'id': 'switch-01',
      'name': '通用开关',
      'functions': [
        {'type': 'power', 'status': false},
      ],
    },
    execute: (device, type, value) async {
      if (type != 'power') throw UnsupportedError('未适配功能：$type');
      await writePower(value as bool);
      return true;
    },
  );
}
```

使用流程：

```dart
await device.connection();
await device.execute<bool, PowerFunction>(true);
await device.requireFunction<PowerFunction>().refresh(device);
await device.disConnection();
device.dispose();
```

未提供 `execute` 的实例可以解析配置和预览界面，调用 `connection()` 会报错。提供 `execute` 但省略连接回调时，连接仅表示执行通道在逻辑上可用，适合无独立连接步骤或已经由外部网关建立连接的传输方式。需要真实建连、断连时，请同时注入对应回调。

接入 `UniversalBleGateway` 时，在自定义 `DeviceDriver.createClient()` 中创建 `GenericDevice`，让 `execute` 回调编码协议并调用网关注入的 `write`，让 `disconnect` 回调调用网关注入的断开函数。广播识别和服务匹配仍由驱动负责。

## 状态语义

- 功能模块的 `status` 包含控件当前编辑值
- `device.status` 是以功能 `type` 为键的只读 JSON 快照，初始值来自配置，后续仅在执行或刷新成功时更新
- 拖动预览、执行失败、无刷新结果和非法刷新结果不会覆盖设备快照
- 构造后修改原始 JSON 不会影响已创建的设备，不同实例之间不共享功能状态
- 执行结果代表回调定义的成功级别；需要硬件确认时，应由回调等待该确认
