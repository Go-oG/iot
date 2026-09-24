# ESP32-C5 N32R8 BLE 网关

固件版本 `0.7.0`，基于本地 ESP-IDF 6.1，面向 32 MiB Flash + 8 MiB Quad PSRAM 的 N32R8 设备。支持最多 32 个 BLE 连接，以及设备登记、重启恢复、错峰重连、自动订阅、上报调度、本地管理面板和设备配置备份。

除 BLE 原子操作外，`manage` 操作把设备登记的增删改、暂停恢复、诊断、网络配置和重启也放到同一组 MQTT 主题上下发，App 不需要访问网关的 HTTP 接口。

使用统一 MQTT/WebSocket V1 协议，支持原始数据透明转发、网页配网和 NVS 配置。没有 OTA、经典蓝牙 SPP/A2DP 或红外驱动。

## ESP-IDF 组件结构

```text
main/
  main.c                            app_main 启动入口
  CMakeLists.txt                    主组件，仅依赖 gateway_core
components/
  gateway_core/
    gateway_core.c                  Wi-Fi、MQTT、BLE GATT、配网和硬件适配
    gateway_protocol.c              V1 Frame、逐设备调度、去重、状态缓存与 WebSocket
    include/gateway_core.h          网关启动接口
    Kconfig.projbuild               配网按键配置
    idf_component.yml               MQTT、mDNS 依赖
    CMakeLists.txt
  device_registry/
    device_config.c                 设备配置校验、JSON 导入导出、退避策略
    include/device_config.h         设备配置模型
    include/report_buffer.h         有界 FIFO 与按特征合并的上报队列
    idf_component.yml               cJSON 依赖
    CMakeLists.txt
  device_manager/
    gateway_manager.c               NVS 登记、连接和上报调度、管理 HTTP API
    include/gateway_manager.h       管理器接口与 BLE/MQTT 适配约定
    dashboard.html                  完全本地的中文设备管理面板
    CMakeLists.txt
tests/
  run_host_tests.py                  编译并运行主机检查
  test_policy.c                     配置、容量、导入导出和队列检查
  test_manager.c                    使用模拟时间和 BLE/MQTT 适配器检查调度
  test_protocol.c                   V1 异步响应、FIFO、Batch、去重与状态同步检查
```

`gateway_core` 提供底层适配函数，管理器通过这些接口访问连接池和 MQTT。管理器不会直接修改 BLE 连接池。各组件的公开头文件统一放在自己的 `include/` 目录，网页由组件构建时嵌入固件，无 CDN 或外部网站依赖。

## 本机构建与烧录

macOS：

```sh
cd /Users/wzp/Develop/esp
source /Users/wzp/.espressif/tools/activate_idf_v6.1.sh
idf.py build
idf.py -p /dev/cu.usbmodemXXXX flash monitor
```

替换为开发板的实际串口。环境脚本使用本机 `sdk/.espressif/v6.1/esp-idf`、RISC-V 工具链和 Python 环境。其他机器使用各自的 ESP-IDF 激活方式。

Windows（本机已验证的路径，IDF 位于 `E:\ESPSdk\.espressif\v6.1\esp-idf`）：

```bash
cd /e/Code/ESP/iot/esp
source tools/env.sh                                   # 设置 IDF_PATH、工具链 PATH 与版本变量
python tools/idf_win.py -B build-mqtt-check build      # 用 Python 环境里的解释器执行
```

`tools/env.sh` 用 MSYS 风格路径导出 `PATH`：Git Bash 会把 `C:/...` 这样的条目当成路径列表改写，导致子进程里找不到 `cmake` 和 `ninja`。`tools/idf_win.py` 在导入前移除 `MSYSTEM`：ESP-IDF 6.1 的 `tools/idf.py` 检测到该变量时只打印一条警告就结束，不调用 `main()`，表现为构建静默成功却没有任何产物。

## 生成合并固件

`dist/firmware_merged.bin` 由构建产物合并而成，从 `0x0` 写入：

```bash
cd /e/Code/ESP/iot/esp
source tools/env.sh
B=build-mqtt-check
python -m esptool --chip esp32c5 merge-bin -o "$B/firmware_merged.bin" \
  --flash-mode dio --flash-freq 80m --flash-size 32MB \
  0x2000 "$B/bootloader/bootloader.bin" \
  0x8000 "$B/partition_table/partition-table.bin" \
  0x20000 "$B/esp32c5_ble_gateway.bin"
cp "$B/firmware_merged.bin" dist/firmware_merged.bin
cp "$B/firmware_merged.bin" dist/esp32c5-merged-windows/firmware_merged.bin
```

两个 `dist` 路径是同一份镜像：`dist/firmware_merged.bin` 供直接取用，`dist/esp32c5-merged-windows/` 是带烧录脚本的完整发行目录。替换固件后需要同步更新该目录的 `firmware-info.json`、`Windows烧录说明.txt` 和 `SHA256SUMS.txt`。

面向 Windows 的预编译合并固件在 `dist/esp32c5-merged-windows/`，目录内附一键烧录脚本、`firmware-info.json` 和烧录说明。合并镜像从 `0x0` 写入，会同时覆盖 bootloader、分区表和 NVS，烧录后需要重新配网并重新登记设备。

默认构建目标为 `esp32c5`，加载 `sdkconfig.defaults` 和 `sdkconfig.defaults.esp32c5`。已有 `sdkconfig` 不会被 defaults 覆盖，迁移到其他旧工程时需要同步配置。依赖版本由 `dependencies.lock` 锁定。

**`registry` NVS 分区位于 `0x420000`，在 `factory` 分区之后，合并镜像不覆盖它。** 从早于 `registry` 的版本迁移时仍需执行完整的 `idf.py flash`，不要只烧录应用镜像。建议事先记录已有配网参数。

## 主机侧测试

```bash
cd /e/Code/ESP/iot/esp
PYTHONUTF8=1 python tests/run_host_tests.py
```

需要本机可用的 `clang`（macOS 自带）。脚本以默认编码读源码，Windows 上不加 `PYTHONUTF8=1` 会报 `UnicodeDecodeError`。ESP-IDF 自带的 `esp-clang` 只能生成 RISC-V 与 Xtensa 目标，不能链接主机可执行文件，因此 Windows 上无法运行这组测试。

## 首次使用

首次启动、启动后 Wi-Fi 连接超过 30 秒未成功，或运行时按住 BOOT 三秒，会开启配网热点：

- SSID：`BTGW-XXXXXX`，后缀为 AP MAC 地址后三字节的大写十六进制
- 密码：`btgw-xxxxxx`，同一后缀的小写形式
- 管理面板：`http://192.168.4.1/`
- 网络配置：点击面板中的“Wi-Fi / MQTT 设置”，或访问 `/config`

连接家庭 Wi-Fi 后，也可以通过路由器分配给网关的 IP 打开管理面板。MQTT 支持 `mqtt://` 和 `mqtts://`，保留 TLS 公共根证书包。BOOT 默认 GPIO28，可在 `idf.py menuconfig` → `BLE Gateway` 中调整。

## 设备登记和自动恢复

在面板中手动添加设备，或点击“扫描 5 秒”，从附近设备列表点击“登记”。每台设备可设置：

- 名称：最长 48 字节，中文通常每字占 3 字节
- 蓝牙地址与地址类型
- 是否启用，以及持续连接或广播监听模式
- 最小和最大连接间隔
- 通知传递模式 latest / stream
- 最多四条按服务 UUID、特征 UUID 标识的 notify/indicate 订阅

保存、删除或导入设备清单后，配置先提交到独立 NVS 分区，再重启生效。运行中的配置在重启前保持一致，非法配置不会覆盖现有清单。保存设备配置不要求 MQTT 在线。

启用的持续连接型设备会自动恢复：

1. 启动后错峰连接，整个网关同时只发起一个连接尝试
2. 连接失败后按约 2、4、8、16……256 秒退避，并加上按设备区分的错峰时间
3. 成功后交换 MTU、发现服务，按保存的 UUID 重新解析句柄并恢复订阅
4. 连接参数按设备配置提交协商，实际间隔和失败状态显示在面板中
5. 待连接超过约 15 秒时请求取消；服务发现或订阅超时则请求断开后重试

订阅操作全局串行执行，避免不同设备使用相同句柄时将注册回调匹配错误。取消连接、断开等请求仍需等待协议栈回调完成，不能将“已请求取消”当作链路已释放。

“暂停 / 恢复”立即作用于运行状态，无需重启。暂停会停止自动连接、断开现有链路；重启后仍按保存的“启用”选项运行。需要长期关闭设备时编辑并取消“启用”。使用 V1 控制的设备由协议调度器接管，使用 connect/disconnect/subscribe 操作；未登记设备不会自动恢复。

连接入口只认登记设备：管理器的自动连接和 V1 的 `connect` 都只能操作已登记设备，扫描结果不会触发连接，仅用于面板展示和登记。`connect` 未登记设备时，未知 deviceId 返回 `3001`，扫描发现但未登记返回 `3004`。

广播型设备不建立连接，在没有待连接操作时约每 15 秒启动一次 5 秒扫描；扫描和连接尝试错开。手动扫描也进入此调度。附近设备最多保留 64 条最近发现记录。

对采用轮换隐私地址的设备，保存某次扫描得到的临时地址不能保证长期恢复，需要使用合适的身份地址及绑定方式。当前没有新增口令输入或配对确认界面。

## 上报调度和诊断计数

自动管理器将通知直接送入 V1 协议层，自动订阅的 reportMode 映射为 `latest` 或 `stream`。协议层每 200 ms 聚合状态，stream 按顺序以 QoS 1 输出，并在 MQTT 离线期间使用有界缓冲，不再执行旧的离线清队列策略。缓冲耗尽时报告 overflow 并断开相关 stream 连接。详见 [V1 实现说明](components/gateway_core/PROTOCOL_V1.md)。

管理面板中的 received/published/dropped 分别表示管理器收到、成功交给协议队列、未能交给协议队列的条数；published 不代表 broker 已确认送达。

## 配置备份格式

点击“导出设备配置”下载 JSON；“导入配置”校验后替换全部设备登记并重启。最多 32 台设备、每台四条订阅，文件最大 32 KiB。备份只包含设备和订阅策略，不包含网关 Wi-Fi / MQTT 密码、蓝牙绑定密钥或运行计数。

```json
{
  "version": 1,
  "devices": [
    {
      "device": "AA:BB:CC:DD:EE:01",
      "alias": "客厅电量传感器",
      "addressType": 0,
      "enabled": true,
      "mode": "connection",
      "intervalMinMs": 100,
      "intervalMaxMs": 200,
      "reportMode": "latest",
      "subscriptions": [
        {"service": "180F", "characteristic": "2A19", "indicate": false}
      ]
    }
  ]
}
```

`mode` 为 `connection` 或 `broadcast`；广播模式必须使用空订阅数组。连接间隔为 15～4000 ms、5 ms 的倍数，最小值不得大于最大值。UUID 支持 16、32 和 128 位写法，保存时统一大小写；重复地址和重复订阅会被拒绝。示例 UUID 仅表示标准电量服务，实际设备需支持相应特征及通知属性。

## HTTP / MQTT 接口

HTTP 管理 API 统一使用 `POST /api/v1`，请求体是一条 V1 请求消息：

```json
{"v":1,"type":"req","reqId":"status-001","op":"manage","data":{"action":"status"}}
```

每个请求都必须携带版本号 `v:1` 和当前请求 ID `reqId`。响应同样包含 `v`、`reqId`、`op`、`code`、`message` 和可选的 `data`。设备登记、配置、诊断、扫描、暂停恢复和重启均通过 `manage` 的 `data.action` 区分。

MQTT 仅使用 `iot/v1/<gateway-id>/down`、`up`、`presence`，局域网使用 `/ble/v1` WebSocket。MQTT 的 `messages` 数组复用与 HTTP 完全相同的请求和响应消息结构。详细接口见 [HTTP API](docs/http-api.md)、[MQTT V1 API](docs/mqtt-api.md) 和 [V1 实现说明](components/gateway_core/PROTOCOL_V1.md)。

## N32R8 与容量设置

控制器、Bluedroid ACL 和应用连接池统一为 32；通知注册容量 128，配对记录容量 32。BLE 4.2 扫描 API、MTU 247、25% 扫描占空比和 Wi-Fi / BLE 软件共存继续保留。

PSRAM 为 Quad 80 MHz，启动时探测并测试。Bluedroid 动态内存、MQTT 缓冲及可迁移的 Wi-Fi/LWIP 内存优先使用 PSRAM；普通 `malloc()` 大于 1024 字节优先尝试 PSRAM。预留 64 KiB 内部内存池给内部 RAM / DMA 分配，控制器及任务栈仍使用内部 RAM。

TLS 使用默认内存分配策略，mDNS 动态数据使用 PSRAM。关闭 Wi-Fi 的 IRAM、额外 IRAM 和 RX IRAM 吞吐优化，将静态 TX 缓冲数量设为 8，为 Wi-Fi 管理帧和 STA 转 APSTA 配网热点留出内部内存；代价是降低峰值 Wi-Fi 吞吐。启动日志记录各阶段内部内存、最大连续块、DMA 内存和 PSRAM 余量，并输出 Wi-Fi 断线原因及实际管理地址。

| Flash 分区 | 起始地址 | 大小 | 用途 |
| --- | --- | --- | --- |
| nvs | `0x9000` | 64 KiB | 网关、Wi-Fi 和蓝牙持久化信息 |
| phy_init | `0x19000` | 4 KiB | PHY 数据 |
| factory | `0x20000` | 4 MiB | 唯一应用镜像 |
| registry | `0x420000` | 128 KiB | 本版本新增的设备配置 NVS |
| storage | `0x440000` | 27.75 MiB | 未来红外码库、历史数据，尚未使用 |

## 验证

```sh
python3 tests/run_host_tests.py
```

主机检查直接编译设备配置和上报队列代码，并提取实际管理器调度代码，使用模拟时间、BLE 和 MQTT 适配器运行。覆盖：配置拒绝与 32 台设备往返序列化、退避和错峰、待连接串行化、暂停、订阅恢复与超时、不同特征合并、FIFO 溢出、多设备通知转交、入队失败计数和广播扫描优先调度。V1 检查覆盖异步完成、逐设备 FIFO、跨设备并发、执行中和完成后去重、Batch 错误跳过、排队/执行超时隔离、快照版本、离线 stream 顺序补发、UUID 归一化与 UTF-8 校验，以及登记校验、扫描设备不进入状态、设备表和特征表回收、隔离超时放行、Batch 连接步骤、扫描名称与广播原文。使用 AddressSanitizer / UndefinedBehaviorSanitizer。

另有 ESP32-C5 的 `idf.py build` / `idf.py size` 验证，以及用模拟 HTTP 数据检查面板展示、从扫描结果登记设备和表单提交。本地浏览器预览数据不来自真实开发板。

仍需实板验证：独立 NVS 的掉电恢复、PSRAM 实际容量、32 路 BLE 的配对和连接、重连及订阅时序、与 Wi-Fi 并发的吞吐和长期稳定性。
