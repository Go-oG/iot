# MQTT 设备管理与 ESP32 控制

App 的扫描、登记、连接、断开、读写、订阅、灯光与定时控制，以及 ESP32 的配置、诊断、备份和重启，统一通过 MQTT 下发。手机不再发起本地蓝牙扫描、连接或控制，也不调用网关 HTTP / WebSocket 管理接口。

## 使用流程

1. 首次使用 ESP32 时，先按固件的热点配网流程连接 Wi-Fi 和 Broker；这是建立 MQTT 通道的前提
2. App → 设备 → 配置连接，填写同一个 Broker 和网关标识
3. 连接并订阅成功后自动请求 `snapshot`，获取网关设备状态
4. 点击“扫描 5 秒”，从 ESP32 附近的 BLE 设备中登记，或手动输入 MAC
5. 设置名称、地址类型、启用状态、连接 / 广播模式、连接间隔和自动订阅策略；保存成功后 ESP32 重启生效
6. 已登记设备可分别连接、断开、编辑、删除和执行原始读写；连接多台设备不会断开上一台
7. 对 AT5 灯具选择“作为 AT5 灯控制”，在首页调节灯光、温控、风扇和两个设备定时槽位

稳定 `deviceId` 用于协议请求；MAC 用于固件登记。编辑、扫描登记和导入保留 `deviceId` / `deviceUuid`。多设备状态同时缓存，首页控制对象单独选择并保存。

“暂停自动连接 / 恢复自动连接”对应固件自动管理器。设备通过 V1 连接后由协议调度器接管，界面改用“连接 / 断开”。关闭 App 或移除 App 的 MQTT 连接不会释放网关上其他设备的 BLE 连接。

## 状态和命令

- 固定主题：`iot/v1/{gatewayId}/down`、`up`、`presence`
- 帧为 `v/gatewayId/clientId/ts/messages[]`，消息类型严格使用 `req/res/event`
- 命令 QoS 1，`retain=false`；App 拒绝保留的上行控制消息
- 使用独立客户端标识和唯一请求标识关联响应；不自动重发执行结果未知的命令
- 重连后恢复订阅和完整快照，每 30 秒请求快照检查状态，长时间无响应时标为离线
- 断线重连从 2 秒起指数退避到 60 秒并加入抖动；用户重新连接时从最短间隔开始
- Android 上前台服务持有唤醒锁，避免息屏后 MQTT 心跳停止。主控制链路和 MQTT 调试页都会申请，按持有者计数，最后一个释放时才关闭前台服务
- 连接中断或 LWT 离线会使待处理命令失败并清除可控制状态
- 重复 / 旧版本增量不回滚缓存；revision 断档、hello 或 overflow 触发重同步
- 完整快照替换旧缓存，读和通知更新特征缓存，写入响应不覆盖设备状态

AT5 控制以 `batch` 执行 `subscribe + write...`，不使用当前固件尚未实现的 `waitNotify`。App 监听对应设备、服务、特征和命令的通知，区分写入成功、收到 ACK、设备拒绝以及超时。AT5 ACK 没有请求序号，不能作为多客户端并发操作时的精确状态回读。界面灯光参数仍是本机最后设置值，不伪装成设备遥测。下发定时前先在同一 batch 中同步设备时间。

## 协议取值的表达方式

协议里出现的字符串取值（消息类型、操作、主题层级、模式、动作、字段名等）在代码内一律用枚举表达，枚举值携带自己的线上文本；只有真正拼装或解析协议 JSON 时才通过 `wire` 取值。帧与消息体字段名见 `GatewayField`，主题层级见 `GatewayTopic`，取值枚举见 `GatewayMessageType`、`GatewayOption`、`GatewayStatus`、`GatewayDelivery`、`GatewayNotifyMode`、`GatewayWriteType`、`GatewayConnectPolicy`、`GatewayScanAction`、`GatewayManageAction`、`GatewayDeviceMode`、`GatewayAddressType`；错误码见 `GatewayErrorCode`（数值码 + 英文名成对声明，未声明的码归入 `unknown` 并保留原始数值）。

设备侧同样如此：`DeviceCommand` 是下发命令，`RemoteConfirmation` 是确认程度，`RemoteStep` 是批量步骤标识，`ConfigurableFunction` 是功能类型，`LightChannel` 是五路通道，`TimerField` 是定时字段。设备配置里由取值决定行为的字段也改用枚举：`WireValueKind`（`as`）、`ByteEndian`、`ChecksumKind`（`crc.type`）、`FrameSpan`（`length.of` / `crc.of`）、`ClockField`、`FrameSegmentKind`、`GenericCommandSource`、`GenericCommandKind`。

通用设备在“读写 / 通知”页面填写服务与特征 UUID，支持 hex/base64/utf8、读、带 / 不带响应写、notify/indicate、stream/latest，以及取消订阅。V1 固件没有 `discover`，页面显示快照中的已缓存特征，不假装提供完整 GATT 发现。

## ESP32 管理扩展

需要同级 `../esp` 项目的固件 `0.7.0` 或以上。旧固件不支持 `manage`，会返回 `1002`，App 显示错误，不回退到 HTTP。

`0.7.0` 之前发布过的合并固件把 `diagnostics` 的固件版本误报为 `0.1.0`（`hello` 报 `0.6.0`），`0.7.0` 起统一为同一个版本号。App 以 `hello` 的 `features.managementActions` 判断网关支持哪些管理动作。

所有管理命令仍使用同一组 V1 主题，例如：

```json
{
  "v": 1,
  "gatewayId": "gw-001",
  "clientId": "app-unique",
  "messages": [{
    "type": "req",
    "reqId": "unique-1",
    "op": "manage",
    "data": {"action": "status"}
  }]
}
```

| action | 附加参数 | 返回 data / 行为 |
| --- | --- | --- |
| `status` | 无 | `version/devices/states/maxFrameBytes`，含暂停、协议接管、连接参数和计数 |
| `upsert` | `device`：一条固件登记对象 | 新增或按 MAC 更新，校验后写入 NVS 并重启 |
| `remove` | `device`：MAC 字符串 | 删除登记并重启 |
| `backup` | 无 | `version:1, devices:[...]`，不包含网络密码 |
| `save` | `registry`：完整备份对象 | 校验并替换全部登记，重启 |
| `pause` / `resume` | `device`：MAC 字符串 | 暂停 / 恢复自动管理器，协议接管设备使用 connect/disconnect |
| `diagnostics` | 无 | 内存、链路和 MQTT 等固件诊断数据 |
| `config.get` | 无 | 网络配置及密码是否已设置，不返回明文密码 |
| `config.set` | `config`：网络配置对象 | 校验并写入 NVS，重启后生效 |
| `restart` | 无 | 延迟重启 |

登记对象与固件原有备份格式一致，最多 32 台设备、每台四条订阅。单次增删改在固件中合并当前登记，App 不用陈旧列表覆盖其他设备。写配置期间互斥，成功响应带 `restarting:true`，网关先回复并缓存去重结果，再延迟重启。App 显示重启结果，重新上线或收到 hello 时同步登记。

`config.set` 字段：`wifiSsid/mqttUri/mqttUsername/gatewayId/wifiPassword/mqttPassword`，以及 `keepWifiPassword/keepMqttPassword/clearWifiPassword/clearMqttPassword`。密码留空默认保留，勾选清空才删除。修改 Broker 或网关标识后，需在 App 的 MQTT 设置中填写新连接信息。

管理扩展固件单帧容量为 65536 字节，覆盖完整设备登记备份加上 Frame 的开销。App 从 hello/status 获取容量，未获取前按原有 16384 字节限制检查。超出容量的导入会明确报错，不拆成无法原子保存的写操作。

## 验证与边界

新增模拟 MQTT 回归测试覆盖请求关联、重复状态、断档重同步、完整快照替换、离线失败、保留消息隔离、关闭会话不释放 BLE、AT5 批处理和管理命令封装。真实 Broker 烟雾检查仍由 `MQTT_SMOKE` 显式启用。

App 已删除直连 BLE 的实现（`ble_service.dart`、`classic_scanner.dart`、`device_driver.dart`、`scan_type.dart`、`device_service.dart`）以及 `universal_ble`、`flutter_classic_bluetooth`、`dio`、`hive_ce`、`archive` 依赖。安卓清单和 iOS `Info.plist` 中的蓝牙、定位权限一并移除：扫描由 ESP32 执行，手机不再需要这些权限。

ESP32 固件 `0.7.0` 使用 ESP-IDF 6.1 完成编译，合并镜像写入 `esp/dist/firmware_merged.bin`，SHA256 记录在 `esp/dist/esp32c5-merged-windows/firmware-info.json`，随附 `SHA256SUMS.txt` 可校验。**未执行设备烧录、实板擦除或真实 BLE / MQTT 联调**，烧录后需要重新配网并重新登记设备。

固件主机侧回归测试（`esp/tests/run_host_tests.py`）需要在 macOS 上运行，本机是 Windows 且只有 RISC-V / Xtensa 工具链，无法链接主机可执行文件，因此未执行。

OTA、配对交互、ESP32 日程引擎仍不在现有固件能力内，App 不提供虚构入口。

通用设备具备远程读写通道：设备配置声明 `chars` / `frame` / `response` / `commands` 并给功能绑定 `write` 之后，App 会按配置把功能值编码成 BLE 报文经 MQTT 下发，订阅到的通知按同一套规则解码并写回功能状态。编解码全部在 App 内完成，网关收到的仍是十六进制报文，固件不需要改动。字段与校验规则见 [通用设备远程读写协议设计](generic-device-codec.md)。没有声明 `commands` 的配置仍然只支持本地配置与预览，不假装可远程控制。
