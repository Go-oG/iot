# 网关 V1 实现与接入

固件 `0.7.0` 根据项目根目录 `ble_gateway_mqtt_app_protocol.md` 实现 V1 协议。继续使用项目已经配置的 Bluedroid，不迁移蓝牙协议栈。

## 入口

| 入口 | 地址 | 行为 |
| --- | --- | --- |
| MQTT 下行 | `iot/v1/{gatewayId}/down` | QoS 1，拒绝 retained 控制消息，支持分片重组 |
| MQTT 上行 | `iot/v1/{gatewayId}/up` | 响应、hello、connection、scan、notify、state、overflow |
| 在线状态 | `iot/v1/{gatewayId}/presence` | QoS 1 + retained，配置离线 LWT |
| HTTP API | `POST http://<网关IP>/api/v1` | 请求体直接使用一条 V1 请求消息，响应结构相同 |
| WebSocket | `ws://<网关IP>/ble/v1` | 同一 Frame 格式，响应只发回原会话，事件广播 |
| mDNS | `_blegw._tcp` | TXT 包含 `path=/ble/v1`、`protocol=1`、`gatewayId` |

mDNS 主机名为 `blegw-<STA MAC 的十二位小写十六进制>.local`，使用 MAC 避免多网关名称冲突。WebSocket 接收完整文本帧，最大 64 KiB；不支持 WebSocket continuation 分片。MQTT 包在底层分片时会按偏移重组。

Frame 必须包含 `v:1`、匹配本机的 `gatewayId`、非空 `clientId` 和 `messages` 数组；每条请求必须包含 `v:1`、`type:"req"`、非空 `reqId` 和 `op`。标识最大 64 字节。同一客户端必须在缓存有效期内使用不同的 reqId 标识不同操作。

```json
{
  "v": 1,
  "gatewayId": "gw-001",
  "clientId": "app-001",
  "messages": [
    {
      "v": 1,
      "type": "req",
      "reqId": "connect-001",
      "op": "connect",
      "deviceId": "sensor-001",
      "data": {
        "mac": "AA:BB:CC:DD:EE:01",
        "addrType": "public",
        "policy": "queue"
      }
    }
  ]
}
```

只有用户在设备管理面板登记过的设备可以被连接和操作，登记身份以 deviceId 优先，未配置时依次使用 deviceUuid、MAC。未登记设备不会自动连接：connect 对完全未知的 deviceId 返回 `3001`，对扫描发现但未登记的地址返回 `3004`，请求中的 `mac`/`addrType` 必须与登记地址一致。

scan 结果只描述发现信息，包含 `deviceId`、`mac`、`addrType`、`rssi`、`lastSeen`、`name`、`advertisement` 和 `registered` 标记，不进入状态缓存，也不会触发连接。客户端需要先登记设备，再使用 connect。

## 执行语义

- 支持 `scan`、`connect`、`disconnect`、`read`、`write`、`subscribe`、`batch`、`snapshot`
- `discover`、`waitNotify` 在 V1 返回 `1002`，hello 中 `waitNotify:false`
- 同设备严格 FIFO，Batch 执行中不释放该设备队列，不支持回滚
- Batch 步骤允许 `connect`/`disconnect`，可以实现“连接→订阅→读写”的一次下发
- 不同设备最多同时推进 4 个协议操作，管理器的自动 CCCD 操作也计入预算
- CCCD 注册因 Bluedroid 回调不携带连接标识而继续全局串行
- 默认连接名额不足时排队，可指定 `data.policy:"reject"` 立即得到 `2003`
- `autoConnect` 默认关闭，可对 read/write/batch 设置 `data.autoConnect:true`
- `queueTimeout` 默认 10000 ms，从进入调度队列开始计时；connect 也支持文档定义的 `data.queueTimeout`
- 普通操作 `timeout` 默认 5000 ms，connect 默认 15000 ms，Batch 默认总计 10000 ms
- Batch 支持每步 timeout，不能超过 Batch 剩余总时间
- 真正的 read/write/CCCD 完成回调到达后才返回结果；connect 等待服务发现完成
- `withoutResponse` 成功只表示本地协议栈完成提交，不表示外设确认业务执行
- 超时操作会关闭链路，并在收到断开/取消完成之前隔离后续请求，防止迟到回调串台
- 隔离最长 5 秒，到期无条件放行一次重连，避免断开回调丢失导致设备永久不可用
- connect 建立失败返回 `3003`，其它操作在链路断开时返回 `3101`
- 单次 write 不能超过协商后的 ATT 载荷，超长写入返回 `1003`，需要客户端自行分片
- 底层错误放在 `data.nativeCode`，协议使用稳定错误码；Batch 总体失败为 `4003`

subscribe 默认 `enabled:true`、`mode:auto`、`delivery:stream`。auto 优先 notify，仅支持 indicate 时选 indicate。`enabled:false` 取消订阅。

支持 hex/base64/utf8 写入及 read 响应格式，省略 format 时使用 hex。缓存与 notify 使用 hex。UTF-8 read 值包含零字节或非法编码时返回 `1003`，可改用 hex/base64 读取。16/32/128 位 UUID 统一归一化，SIG Base UUID 与短格式映射到同一个缓存项。

## 状态、去重与缓冲

read 成功及 notify/indicate 更新 Characteristic 缓存，write 成功不会改变缓存。snapshot 按 Device → Service → Characteristic 输出，断开后保留最后已知值及其时间，同时将 connection 标记为 disconnected。状态与 snapshot 只包含登记设备。

state 与 scan 按 200 ms 窗口聚合，scan 同窗口同 MAC 保留最新 RSSI。state 只反映连接、订阅和特征值变化，扫描不会产生状态增量。每个 state 聚合事件只递增一次 revision。snapshot 会先提交当前待聚合变更，再返回对应 revision；接收方遇到版本跳跃或网关重新 hello 时应重新 snapshot。scan 的 stop 会保留一个聚合窗口，把停止前最后发现的结果发出。

SNTP 使用 `pool.ntp.org` 校时，协议 ts 为 Unix 毫秒。首次校时完成前 ts 为 `0`，hello 的 `timeSynced` 表示生成 hello 时的校时状态。内部超时只使用单调时钟，不受网络校时影响。

去重键为 `(clientId, reqId)`，覆盖执行中请求与最近完成结果。相同键不会再次执行 BLE；重试执行中请求时最终响应转向该客户端最新的来源会话。完成缓存同时受 128 条及 256 KiB 限制，按完成顺序淘汰，存放于 RAM，重启后清空；这不是跨重启的 exactly-once 保证。

| 资源 | 上限 |
| --- | ---: |
| MQTT/WebSocket 下行 Frame | 64 KiB |
| Frame 消息数 / 待处理请求数 | 64 |
| Batch 步数 | 32 |
| 运行态已知设备 | 64 |
| 持久化登记设备 / BLE 连接池 | 32 |
| Characteristic 缓存项（全局） | 192 |
| 单个 Characteristic 值 | 512 字节 |
| 回调与接收队列 | 128 条 |
| MQTT stream 待发送队列 | 128 条 |

stream 保留通知次序，以 QoS 1 入 MQTT outbox，离线期间保留有界待发队列；LAN 会话直接接收事件。latest 更新缓存并参与 state 聚合。达到缓冲上限会计数并发出 `op:"overflow", code:2001` 事件，同时关闭相关 stream 连接；客户端应重新建立会话/订阅并按业务协议恢复，不把已溢出的流当作完整数据。没有无限缓冲或掉电持久化的承诺。扫描事件会在输入队列紧张时优先让出空间。

设备表与特征表达到上限时会回收：运行态设备表优先淘汰最久未出现的扫描临时设备，登记设备始终保留；特征表优先淘汰最久未使用、未被订阅且没有请求正在使用的缓存项，操作失败时立即释放本次新建的空缓存项。无法归属到任何订阅句柄的通知不返回错误，计数汇总在 hello 的 `counters.unmatchedNotify`。

## 设备管理与协议调度

MQTT 仅使用上述三个 `iot/v1` 主题，不订阅旧 RPC 主题，也不发送旧格式响应或事件。所有控制请求都必须使用 Frame + messages 格式；未支持的操作返回 `1002`。配置、运行诊断和设备登记可作为 `manage` 操作通过 MQTT 下发；本地 HTTP 写请求要求同源且 `Content-Type: application/json`。

自动管理设备的通知同样进入统一协议层，登记的 reportMode 仅接受 latest/stream，使用同一状态缓存、通知缓冲和 V1 输出格式。已移除 all 模式及设备级 reportIntervalMs，状态聚合窗口统一为 200 ms。

已登记设备首次收到有效 V1 请求后，本次启动中由 V1 接管调度。管理面板的暂停/恢复对该设备返回 `device_controlled_by_v1`，管理器停止对其执行自动连接、自动订阅和连接参数更新，防止插入 Batch。此时应使用 V1 connect/disconnect/subscribe。未接管设备继续自动连接和订阅策略；重启清除运行态接管标记。管理器只为登记设备自动连接，扫描结果不会触发连接。

设备登记 JSON 新增可选 `deviceId`、`deviceUuid`，导入、导出和面板编辑会保留。没有 deviceId 时优先使用 deviceUuid，否则使用 MAC。登记身份写入原 registry NVS。connect 临时建立的绑定只保存在 RAM。网关不会猜测厂商广播数据中的 UUID，也不会自动解析设备业务协议；随机地址变化需更新登记中的地址映射。

## 验证

```sh
python3 tests/run_host_tests.py
source /Users/wzp/.espressif/tools/activate_idf_v6.1.sh
idf.py -B build/v1-check build
```

主机测试通过模拟 BLE 回调、时间和 MQTT 检查实际协议调度代码，并启用 ASan/UBSan，覆盖登记校验、扫描表回收、隔离超时放行、Batch 连接步骤和扫描元数据。测试不替代实板验证；WebSocket/mDNS、MQTT 重连与分片、真实 BLE 通知/长写入、32 路连接吞吐和长时间运行仍需接入设备验证。Base64 由固件链接的 mbedTLS 提供，主机调度测试不覆盖该库自身。
