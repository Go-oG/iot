# BLE Gateway ↔ MQTT ↔ App 双向通信协议设计

版本：`v1.0`

适用场景：

- ESP32-C5 作为 BLE 网关
- 手机 App 通过云端 MQTT 或局域网 WebSocket 控制 BLE 设备
- 网关仅承担 BLE 原子操作、状态缓存和数据转发
- 设备业务协议由 App 或云端解析
- 支持多设备连接、多设备并发、批处理、状态同步与通知推送

---

# 1. 设计目标

本协议的核心目标如下：

1. 网关保持通用，不感知具体 BLE 设备业务语义。
2. MQTT Topic 数量不随 BLE 设备数量增长。
3. 支持统一的请求、响应、事件模型。
4. 支持扫描、连接、断开、读、写、订阅等 BLE 原子操作。
5. 支持多个 BLE 操作组成 `batch`，减少云端往返。
6. 支持多设备并发和单设备串行调度。
7. 支持状态缓存、快照和增量同步。
8. 支持 LAN WebSocket 与云端 MQTT 共用同一套协议。
9. 支持请求去重，避免 MQTT QoS 1 重复投递导致 BLE 操作重复执行。
10. 支持协议扩展，未来可以增加 `discover`、`waitNotify`、OTA 等能力。

---

# 2. 总体架构

```text
                    Internet
                       │
                       │ MQTT
                       ▼
               ┌──────────────┐
               │ MQTT Broker  │
               └──────┬───────┘
                      │
                      ▼
┌─────────┐      ┌──────────────┐
│   App   │──────│ ESP32-C5 GW │
└─────────┘ WS   └──────┬───────┘
        LAN             │
                        │ BLE
                ┌───────┼───────┐
                ▼       ▼       ▼
              Dev A   Dev B   Dev C
```

网关内部建议划分为：

```text
MQTT Transport ─┐
                ├── Protocol Decoder
WebSocket ──────┘        │
                         ▼
                  Request Dispatcher
                         │
                         ▼
                   BLE Scheduler
                         │
                         ▼
                      NimBLE
```

MQTT 与 WebSocket 最终进入相同的请求分发器和 BLE 调度层。

---

# 3. MQTT Topic 设计

不建议按照设备、Service 或 Characteristic 拆分 Topic。

错误示例：

```text
gateway/{gatewayId}/device/{mac}/service/{uuid}/char/{uuid}/...
```

这样设备数量增加后 Topic 会迅速膨胀。

建议每个网关固定使用以下 Topic：

```text
iot/v1/{gatewayId}/down
iot/v1/{gatewayId}/up
iot/v1/{gatewayId}/presence
```

说明：

| Topic | 方向 | 用途 |
|---|---|---|
| `down` | App/Cloud → Gateway | 所有控制请求 |
| `up` | Gateway → App/Cloud | response、notify、state、scan 等 |
| `presence` | Gateway → App/Cloud | 网关在线状态 |

因此：

```text
1 个 BLE 设备   -> 3 个 Topic
100 个 BLE 设备 -> 3 个 Topic
```

设备标识、Service UUID、Characteristic UUID 均放在 Payload 中。

---

# 4. Transport Frame

建议不要将：

```text
一个 MQTT PUBLISH = 一个 BLE 操作
```

而是增加一层 Frame。

一个 MQTT/WebSocket Frame 可以携带多个独立协议消息。

格式：

```json
{
  "v": 1,
  "gatewayId": "gw-001",
  "clientId": "app-a81f",
  "ts": 1712345678901,
  "messages": [
    {
      "type": "req",
      "reqId": "req-001",
      "op": "read",
      "deviceId": "dev-001",
      "service": "fff0",
      "char": "fff1",
      "timeout": 5000
    }
  ]
}
```

字段说明：

| 字段 | 类型 | 必填 | 说明 |
|---|---|---:|---|
| `v` | int | 是 | 协议版本 |
| `gatewayId` | string | 是 | 网关唯一标识 |
| `clientId` | string | 下行建议必填 | 客户端唯一标识 |
| `ts` | int64 | 否 | Unix 时间戳，毫秒 |
| `messages` | array | 是 | 协议消息集合 |

---

# 5. 多消息合并

一次 MQTT 消息可以携带多个独立操作：

```json
{
  "v": 1,
  "gatewayId": "gw-001",
  "clientId": "app-a81f",
  "messages": [
    {
      "type": "req",
      "reqId": "r1",
      "op": "write",
      "deviceId": "dev-001",
      "service": "fff0",
      "char": "fff1",
      "value": "01"
    },
    {
      "type": "req",
      "reqId": "r2",
      "op": "write",
      "deviceId": "dev-002",
      "service": "fff0",
      "char": "fff1",
      "value": "01"
    },
    {
      "type": "req",
      "reqId": "r3",
      "op": "read",
      "deviceId": "dev-003",
      "service": "fff0",
      "char": "fff2"
    }
  ]
}
```

注意：

```text
messages[]
```

表示：

> 多个相互独立的请求合并在一个传输帧中。

而：

```text
op: "batch"
```

表示：

> 同一个设备的一系列 BLE 操作按顺序执行。

两者不是同一个概念。

---

# 6. Message 统一格式

统一消息结构：

```json
{
  "type": "req|res|event",
  "reqId": "req-001",
  "op": "read",
  "deviceId": "dev-001",

  "service": "fff0",
  "char": "fff1",

  "value": "01",
  "format": "hex",

  "timeout": 5000,
  "queueTimeout": 10000,

  "code": 0,
  "message": "ok",

  "data": {},
  "ts": 1712345678901
}
```

字段说明：

| 字段 | req | res | event | 说明 |
|---|---:|---:|---:|---|
| `type` | ✓ | ✓ | ✓ | `req/res/event` |
| `reqId` | ✓ | ✓ | - | 请求关联 ID |
| `op` | ✓ | ✓ | ✓ | 操作类型 |
| `deviceId` | 可选 | 可选 | 可选 | BLE 设备 ID |
| `service` | 可选 | 可选 | 可选 | Service UUID |
| `char` | 可选 | 可选 | 可选 | Characteristic UUID |
| `value` | 可选 | 可选 | 可选 | BLE 原始值 |
| `format` | 可选 | 可选 | 可选 | `hex/base64/utf8` |
| `timeout` | 可选 | - | - | BLE 操作执行超时 |
| `queueTimeout` | 可选 | - | - | 调度队列等待超时 |
| `code` | - | ✓ | 可选 | 协议错误码 |
| `message` | - | ✓ | 可选 | 可读错误信息 |
| `data` | 可选 | 可选 | 可选 | 操作特定扩展参数 |
| `ts` | 可选 | ✓ | ✓ | Unix 时间戳，毫秒 |

默认：

```text
format = hex
```

---

# 7. UUID 格式

为减少 JSON 长度，协议允许 16-bit、32-bit 和 128-bit UUID。

例如：

```text
16-bit:
fff0

32-bit:
12345678

128-bit:
11223344-5566-7788-99aa-bbccddeeff00
```

Bluetooth SIG Base UUID 可以使用短格式：

```text
fff0
```

等价于：

```text
0000fff0-0000-1000-8000-00805f9b34fb
```

网关内部统一 normalize。

---

# 8. 设备唯一标识

不建议仅使用：

```text
Service UUID + MAC
```

作为设备身份。

建议：

```json
{
  "deviceId": "abc123",
  "deviceUuid": "22c51f92-0c73-4fb4-a47d-e6a01001abcd",
  "mac": "AA:BB:CC:DD:EE:01",
  "addrType": "public"
}
```

其中：

- `deviceUuid`：设备自身稳定 UUID。
- `deviceId`：协议使用的稳定设备 ID。
- `mac`：当前 BLE 地址。
- `addrType`：地址类型。

建议设备固件在 Manufacturer Data 或 Service Data 中广播稳定 `deviceUuid`。

推荐：

```text
deviceId = deviceUuid
```

或者：

```text
deviceId = hash(deviceUuid + identityMac)
```

因为 BLE Random Address / RPA 可能变化，所以 MAC 不一定适合作为唯一身份。

---

# 9. BLE 原子操作

V1 定义以下原子操作：

| op | 说明 |
|---|---|
| `scan` | 扫描 BLE 设备 |
| `connect` | 连接设备 |
| `disconnect` | 断开设备 |
| `read` | 读取 Characteristic |
| `write` | 写 Characteristic |
| `subscribe` | 订阅/取消 Notify 或 Indicate |
| `batch` | 顺序执行多个 BLE 操作 |
| `snapshot` | 获取网关当前完整状态 |
| `manage` | 网关自身的管理操作，见第 39 节 |

建议预留：

```text
discover
waitNotify
```

---

# 10. Read

请求：

```json
{
  "type": "req",
  "reqId": "r100",
  "op": "read",
  "deviceId": "dev-01",
  "service": "fff0",
  "char": "fff1",
  "timeout": 3000
}
```

响应：

```json
{
  "type": "res",
  "reqId": "r100",
  "op": "read",
  "deviceId": "dev-01",
  "service": "fff0",
  "char": "fff1",
  "code": 0,
  "message": "ok",
  "value": "64",
  "ts": 1712345678901
}
```

Read 成功后，网关应更新本地状态缓存。

---

# 11. Write

请求：

```json
{
  "type": "req",
  "reqId": "r101",
  "op": "write",
  "deviceId": "dev-01",
  "service": "fff0",
  "char": "fff1",
  "value": "010203",
  "format": "hex",
  "data": {
    "writeType": "withResponse"
  },
  "timeout": 3000
}
```

`writeType`：

```text
withResponse
withoutResponse
```

响应：

```json
{
  "type": "res",
  "reqId": "r101",
  "op": "write",
  "deviceId": "dev-01",
  "code": 0,
  "message": "ok",
  "ts": 1712345678901
}
```

注意：

```text
GATT write success
≠
设备业务状态已经改变
```

因此不建议因为 Write 成功就直接覆盖 Characteristic 状态缓存。

状态缓存建议仅由以下数据更新：

```text
read
notify
indicate
```

---

# 12. Subscribe

请求：

```json
{
  "type": "req",
  "reqId": "r102",
  "op": "subscribe",
  "deviceId": "dev-01",
  "service": "fff0",
  "char": "fff2",
  "data": {
    "enabled": true,
    "mode": "auto",
    "delivery": "stream"
  }
}
```

参数：

```text
enabled:
true
false

mode:
auto
notify
indicate

delivery:
stream
latest
```

取消订阅：

```json
{
  "op": "subscribe",
  "data": {
    "enabled": false
  }
}
```

不需要单独定义 `unsubscribe`。

---

# 13. Notify Delivery 模式

Notify 建议支持两种模式：

```text
stream
latest
```

## 13.1 stream

每一个 Notify 都必须传递。

适用于：

- 私有 BLE 协议
- 数据流
- 指令响应
- OTA 数据
- 事件序列

示例：

```json
{
  "type": "event",
  "op": "notify",
  "deviceId": "dev-01",
  "service": "fff0",
  "char": "fff2",
  "value": "010203",
  "ts": 1712345678901
}
```

网关可以将多个 Notify 合并到一个 Frame：

```text
50ms 内：
notify1
notify2
notify3
```

发送：

```json
{
  "messages": [
    { "...": "notify1" },
    { "...": "notify2" },
    { "...": "notify3" }
  ]
}
```

但不能丢弃中间 Notify。

---

## 13.2 latest

只关心最新状态。

适用于：

- 电量
- 温度
- 亮度
- RSSI
- 开关状态

例如：

```text
30
31
32
33
34
```

可以只上传：

```text
34
```

并进入状态聚合机制。

---

# 14. Gateway 状态缓存

网关内部建议维护：

```text
GatewayState
 ├── Device A
 │    ├── connection
 │    ├── rssi
 │    ├── lastSeen
 │    └── characteristics
 │         ├── fff0/fff1
 │         └── fff0/fff2
 │
 └── Device B
      ...
```

App 首次进入：

```text
snapshot
```

获取完整状态。

之后仅接收：

```text
state delta
```

---

# 15. Snapshot

请求：

```json
{
  "type": "req",
  "reqId": "sync-001",
  "op": "snapshot"
}
```

响应：

```json
{
  "type": "res",
  "reqId": "sync-001",
  "op": "snapshot",
  "code": 0,
  "data": {
    "revision": 1052,
    "devices": [
      {
        "deviceId": "dev-01",
        "deviceUuid": "22c51f92-0c73-4fb4-a47d-e6a01001abcd",
        "mac": "AA:BB:CC:DD:EE:01",
        "addrType": "public",
        "connection": "connected",
        "rssi": -51,
        "lastSeen": 1712345678000,
        "services": [
          {
            "uuid": "fff0",
            "chars": [
              {
                "uuid": "fff1",
                "value": "64",
                "ts": 1712345677000
              },
              {
                "uuid": "fff2",
                "value": "01",
                "ts": 1712345677500
              }
            ]
          }
        ]
      }
    ]
  }
}
```

状态结构按：

```text
Device
  -> Service
      -> Characteristic
```

聚合。

避免重复传输 Service UUID。

---

# 16. 状态增量

网关状态变化后，不需要重新发送完整 Snapshot。

示例：

```json
{
  "type": "event",
  "op": "state",
  "data": {
    "revision": 1053,
    "devices": [
      {
        "deviceId": "dev-01",
        "connection": "connected",
        "services": [
          {
            "uuid": "fff0",
            "chars": [
              {
                "uuid": "fff1",
                "value": "65",
                "ts": 1712345679000
              }
            ]
          }
        ]
      }
    ]
  }
}
```

多台设备变化可以一次性发送：

```json
{
  "data": {
    "devices": [
      { "...": "Device A delta" },
      { "...": "Device B delta" },
      { "...": "Device C delta" }
    ]
  }
}
```

---

# 17. Revision

网关维护状态版本：

```text
1051
1052
1053
1054
```

App 本地记录：

```text
revision = 1052
```

正常收到：

```text
1053
```

则继续应用增量
如果收到：

```text
1058
```

说明状态事件可能丢失 App 应重新请求：

```json
{
  "op": "snapshot"
}
```

这样状态同步不依赖 MQTT 必须完全可靠

---

# 18. Scan

扫描请求：

```json
{
  "type": "req",
  "reqId": "scan-001",
  "op": "scan",
  "data": {
    "action": "start",
    "duration": 5000,
    "active": true
  }
}
```

立即响应：

```json
{
  "type": "res",
  "reqId": "scan-001",
  "op": "scan",
  "code": 0,
  "data": {
    "scanId": "s-001"
  }
}
```

ESP32 本地可能收到：

```text
Device A
Device B
Device A
Device C
Device B
```

不建议逐条上传。

可以在 100~500ms 窗口内聚合和去重：

```json
{
  "type": "event",
  "op": "scan",
  "data": {
    "scanId": "s-001",
    "devices": [
      {
        "deviceId": "dev-a",
        "mac": "AA:BB:CC:DD:EE:01",
        "addrType": "public",
        "rssi": -43,
        "name": "Light"
      },
      {
        "deviceId": "dev-b",
        "mac": "AA:BB:CC:DD:EE:02",
        "addrType": "random",
        "rssi": -62
      }
    ]
  }
}
```

同一个窗口内仅保留该设备最新 RSSI。

---

# 19. Batch

Batch 用于减少：

```text
App
 -> Cloud
 -> Gateway
 -> BLE
 -> Gateway
 -> Cloud
 -> App
```

多次往返。

请求：

```json
{
  "type": "req",
  "reqId": "batch-001",
  "op": "batch",
  "deviceId": "dev-01",
  "timeout": 8000,
  "data": {
    "stopOnError": true,
    "steps": [
      {
        "id": "s1",
        "op": "subscribe",
        "service": "fff0",
        "char": "fff2",
        "data": {
          "enabled": true,
          "delivery": "stream"
        }
      },
      {
        "id": "s2",
        "op": "write",
        "service": "fff0",
        "char": "fff1",
        "value": "01"
      },
      {
        "id": "s3",
        "op": "read",
        "service": "fff0",
        "char": "fff3"
      }
    ]
  }
}
```

执行逻辑：

```text
锁定 Device A 操作队列

subscribe
   ↓
write
   ↓
read

释放 Device A 操作队列
```

Batch 执行期间：

```text
同一个设备的其它请求不能插入 Batch 中间。
```

但是其它设备：

```text
Device B
Device C
```

可以正常并发。

---

# 20. Batch 响应

成功：

```json
{
  "type": "res",
  "reqId": "batch-001",
  "op": "batch",
  "deviceId": "dev-01",
  "code": 0,
  "message": "ok",
  "data": {
    "steps": [
      {
        "id": "s1",
        "code": 0
      },
      {
        "id": "s2",
        "code": 0
      },
      {
        "id": "s3",
        "code": 0,
        "value": "64"
      }
    ]
  }
}
```

失败：

```json
{
  "type": "res",
  "reqId": "batch-001",
  "op": "batch",
  "deviceId": "dev-01",
  "code": 4003,
  "message": "batch failed",
  "data": {
    "steps": [
      {
        "id": "s1",
        "code": 0
      },
      {
        "id": "s2",
        "code": 4201,
        "message": "gatt write failed"
      },
      {
        "id": "s3",
        "code": 4999,
        "message": "skipped"
      }
    ]
  }
}
```

V1 不做 rollback。

---

# 21. WaitNotify

建议预留：

```text
waitNotify
```

很多私有 BLE 协议都是：

```text
subscribe RX
       ↓
write TX
       ↓
等待 RX notify
       ↓
解析 response
```

示例：

```json
{
  "type": "req",
  "reqId": "cmd-001",
  "op": "batch",
  "deviceId": "dev-01",
  "data": {
    "steps": [
      {
        "op": "subscribe",
        "service": "fff0",
        "char": "fff2"
      },
      {
        "op": "write",
        "service": "fff0",
        "char": "fff1",
        "value": "0102"
      },
      {
        "op": "waitNotify",
        "service": "fff0",
        "char": "fff2",
        "timeout": 1000
      }
    ]
  }
}
```

网关依然不理解：

```text
0102 是什么业务命令
Notify 是什么业务响应
```

只负责 BLE transport。

---

# 22. 多设备并发模型

网关内部推荐：

```text
                  ┌── Device A Queue
Incoming Request ─┼── Device B Queue
                  ├── Device C Queue
                  └── Device D Queue
                          │
                          ▼
                  BLE Scheduler
                          │
             ┌────────────┴────────────┐
             │                         │
       Connection Pool           GATT Procedure
```

调度规则：

| 范围 | 规则 |
|---|---|
| 同一设备 | 严格 FIFO |
| 不同设备 | 可并行 |
| Batch | 同设备执行期间不可插队 |
| Connect | 受 Connection Pool 限制 |
| GATT Procedure | 受全局并发限制 |
| Connection 满 | 默认进入等待队列 |

---

# 23. Gateway Capability

网关上线后建议上报能力：

```json
{
  "v": 1,
  "gatewayId": "gw-001",
  "messages": [
    {
      "type": "event",
      "op": "hello",
      "data": {
        "protocol": 1,
        "firmware": "1.0.3",
        "ble": {
          "maxConnections": 5,
          "maxGattOps": 4
        },
        "features": {
          "batch": true,
          "snapshot": true,
          "scan": true,
          "notify": true,
          "waitNotify": false
        },
        "formats": [
          "hex",
          "base64",
          "utf8"
        ]
      }
    }
  ]
}
```

App 不应该写死最大连接数量。

实际最大连接数由固件、BLE Stack 配置、内存和连接参数共同决定。

---

# 24. Connection Pool

例如：

```text
maxConnections = 5
```

当前：

```text
A connected
B connected
C connected
D connected
E connected
```

收到：

```text
connect F
```

默认建议：

```text
F 进入 connectionQueue
```

而不是主动踢掉某个已经连接的设备。

Connect 可以提供：

```json
{
  "data": {
    "policy": "queue",
    "queueTimeout": 10000
  }
}
```

未来可以扩展：

```text
queue
reject
evictIdle
```

V1 默认：

```text
queue
```

---

# 25. AutoConnect

Read、Write、Batch 可以支持：

```json
{
  "data": {
    "autoConnect": true
  }
}
```

例如设备未连接时：

```text
write
 ↓
auto connect
 ↓
write
```

建议默认：

```text
autoConnect = false
```

避免隐式行为。

Batch 示例：

```json
{
  "op": "batch",
  "deviceId": "dev-01",
  "data": {
    "autoConnect": true,
    "steps": []
  }
}
```

---

# 26. Connection Event

连接成功：

```json
{
  "type": "event",
  "op": "connection",
  "deviceId": "dev-01",
  "data": {
    "state": "connected",
    "mtu": 247
  },
  "ts": 1712345678901
}
```

状态定义：

```text
disconnected
connecting
connected
disconnecting
```

异常断开：

```json
{
  "type": "event",
  "op": "connection",
  "deviceId": "dev-01",
  "code": 3101,
  "message": "remote disconnected",
  "data": {
    "state": "disconnected",
    "reason": 19
  }
}
```

---

# 27. 错误码

不要直接将 ESP-IDF/NimBLE 原始错误码作为协议错误码。

协议定义自己的稳定错误空间：

| 范围 | 类型 |
|---:|---|
| `0` | Success |
| `1000-1999` | Protocol |
| `2000-2999` | Gateway / Scheduler |
| `3000-3999` | BLE GAP / Connection |
| `4000-4999` | GATT |
| `5000-5999` | Security / Authentication |

建议错误码：

| code | 名称 |
|---:|---|
| `0` | OK |
| `1001` | INVALID_REQUEST |
| `1002` | UNSUPPORTED_OP |
| `1003` | INVALID_ARGUMENT |
| `2001` | GATEWAY_BUSY |
| `2002` | QUEUE_TIMEOUT |
| `2003` | CONNECTION_LIMIT |
| `3001` | DEVICE_NOT_FOUND |
| `3002` | NOT_CONNECTED |
| `3003` | CONNECT_TIMEOUT |
| `3101` | DISCONNECTED |
| `4001` | SERVICE_NOT_FOUND |
| `4002` | CHAR_NOT_FOUND |
| `4101` | READ_FAILED |
| `4201` | WRITE_FAILED |
| `4301` | SUBSCRIBE_FAILED |
| `4901` | GATT_TIMEOUT |
| `4999` | SKIPPED |

底层错误码放在：

```json
{
  "code": 4201,
  "message": "gatt write failed",
  "data": {
    "nativeCode": 14
  }
}
```

---

# 28. 请求去重

MQTT QoS 1 是：

```text
At Least Once
```

消息可能重复到达。

所以：

```json
{
  "clientId": "app-a81f",
  "reqId": "req-001",
  "op": "write"
}
```

不能只依赖 `reqId`。

推荐请求唯一键：

```text
clientId + reqId
```

ESP32 维护短期请求缓存：

```text
(clientId, reqId) -> response
```

例如缓存最近：

```text
128
256
```

个请求。

如果再次收到相同请求：

```text
不要再次执行 BLE
```

直接返回之前的 response。

这对以下操作尤其重要：

```text
trigger
increment
motor step
OTA chunk
```

---

# 29. Timeout

建议区分：

```text
queueTimeout
timeout
```

例如：

```json
{
  "queueTimeout": 10000,
  "timeout": 3000
}
```

语义：

```text
queueTimeout
=
请求允许在 Gateway Scheduler 中等待的最大时间。

timeout
=
BLE 操作真正开始之后允许执行的最大时间。
```

这样能够明确区分：

```text
QUEUE_TIMEOUT
```

与：

```text
GATT_TIMEOUT
```

---

# 30. MQTT QoS 建议

| 数据 | QoS |
|---|---:|
| command | 1 |
| response | 1 |
| connect/disconnect event | 1 |
| snapshot | 1 |
| 普通 state delta | 0 或 1 |
| `delivery=stream` Notify | 1 |
| 高频 `delivery=latest` | 0 |
| presence | 1 + retained |

对于 latest state：

```text
brightness = 63
```

如果丢失，下一条：

```text
brightness = 64
```

即可覆盖。

发现 `revision` 不连续时重新请求 Snapshot。

---

# 31. Retain 策略

不要给：

```text
down
up
```

使用 retained。

尤其不能 retain：

```text
write
connect
disconnect
batch
```

否则网关重新连接 Broker 时可能重新执行历史控制命令。

建议仅：

```text
presence
```

使用 retained。

---

# 32. Presence 与 LWT

网关上线：

```json
{
  "online": true,
  "ts": 1712345678901
}
```

Topic：

```text
iot/v1/{gatewayId}/presence
```

设置 retained。

MQTT LWT：

```json
{
  "online": false
}
```

Broker 检测到 Gateway 非正常掉线后自动发布。

---

# 33. LAN 通信

同一 WiFi 下建议 App 直接连接 ESP32。

不建议 ESP32 再实现一个本地 MQTT Broker。

更简单：

```text
App
 │
 │ mDNS
 ▼
gateway.local
 │
 │ WebSocket
 ▼
ws://gateway.local/ble/v1
```

WebSocket Payload 使用完全相同的 Frame：

```json
{
  "v": 1,
  "gatewayId": "gw-001",
  "clientId": "app-a81f",
  "messages": []
}
```

这样：

```text
MQTT
WebSocket
```

只是 Transport 不同，协议层完全一致。

---

# 34. Response Routing

MQTT 请求：

```text
MQTT down
   ↓
Gateway
   ↓
MQTT up
```

WebSocket 请求：

```text
WebSocket Client A
   ↓
Gateway
   ↓
原 WebSocket Client A
```

Event 可以同时广播给：

```text
MQTT subscribers
+
LAN WebSocket clients
```

---

# 35. 推荐网关内部模块

ESP32 固件建议划分：

```text
Transport
 ├── MQTT Transport
 └── WebSocket Transport

Protocol
 ├── Frame Decoder
 ├── Message Decoder
 └── Response Encoder

Gateway Core
 ├── Request Dispatcher
 ├── Request Dedup Cache
 ├── Device Registry
 ├── State Cache
 └── Event Aggregator

BLE
 ├── BLE Scheduler
 ├── Device Queue
 ├── Connection Pool
 ├── GATT Manager
 └── Scanner
```

---

# 36. 推荐运行流程

## App 启动

```text
App
 ↓
连接 MQTT / WebSocket
 ↓
请求 snapshot
 ↓
Gateway 返回完整状态
 ↓
App 建立本地缓存
```

之后：

```text
Gateway state/notify event
 ↓
App 更新本地缓存
```

---

## App 控制设备

```text
App
 ↓
write / read / batch
 ↓
Gateway Scheduler
 ↓
BLE
 ↓
Response
```

设备产生 Notify：

```text
BLE Notify
 ↓
Gateway
 ↓
State Cache
 ↓
Event Aggregator
 ↓
MQTT / WebSocket
 ↓
App
```

---

# 37. 推荐协议核心原则

最终协议的核心可以概括为：

```text
Transport
│
├── MQTT
│    ├── /down
│    ├── /up
│    └── /presence
│
└── WebSocket
     └── /ble/v1

            │
            ▼

Frame
{
    v
    gatewayId
    clientId
    ts
    messages[]
}

            │
            ▼

Message
{
    type
    reqId
    op
    deviceId

    service
    char

    value
    format

    timeout
    queueTimeout

    code
    message
    data
    ts
}

            │
            ▼

BLE Operations

scan
connect
disconnect
read
write
subscribe
batch
snapshot
```

Gateway 内部：

```text
Device Registry
      +
State Cache
      +
Connection Pool
      +
Per Device FIFO Queue
      +
Global BLE Scheduler
      +
Request Dedup Cache
      +
Event Aggregator
```

---

# 38. V1 推荐最终能力

首版建议实际实现：

```text
scan
connect
disconnect
read
write
subscribe
batch
snapshot
```

以及：

```text
Frame messages[]
State Cache
State Revision
Per Device Queue
Connection Pool
Request Dedup
MQTT
WebSocket
Presence / LWT
```

预留但可以后续实现：

```text
discover
waitNotify
```

这样可以保证首版复杂度可控，同时不会限制后续私有 BLE 协议和更多设备类型扩展。

---

# 39. Manage 管理扩展

`manage` 用于在**同一组主题**上完成网关自身的配置与登记管理，App 不需要访问网关的 HTTP 接口。

它不针对某条 BLE 链路：`pause` / `resume` / `upsert` / `remove` 的 `device` 参数是登记对象的 MAC，`manage` 不经过 BLE 调度器。

请求：

```json
{
  "v": 1,
  "gatewayId": "gw-001",
  "clientId": "app-a81f",
  "messages": [
    {
      "type": "req",
      "reqId": "m-001",
      "op": "manage",
      "data": { "action": "status" }
    }
  ]
}
```

## 39.1 Action 列表

| action | 附加参数 | 说明 |
|---|---|---|
| `status` | 无 | 登记表与运行状态：暂停、协议接管、连接参数、上报计数，另附 `maxFrameBytes` |
| `backup` | 无 | 返回完整登记备份 `{version, devices:[...]}`，不含网络密码 |
| `save` | `registry`：完整备份对象 | 校验后整体替换登记，重启生效 |
| `upsert` | `device`：一条登记对象 | 按 MAC 新增或更新单台设备，重启生效 |
| `remove` | `device`：MAC 字符串 | 删除单台登记，重启生效 |
| `pause` | `device`：MAC 字符串 | 暂停该设备的自动连接与上报 |
| `resume` | `device`：MAC 字符串 | 恢复自动连接与上报 |
| `diagnostics` | 无 | 内存、链路、MQTT 等固件诊断数据 |
| `config.get` | 无 | 网络配置与密码是否已设置，不返回明文密码 |
| `config.set` | `config`：网络配置对象 | 校验并写入 NVS，重启后生效 |
| `restart` | 无 | 延迟重启 |

写操作之间互斥。成功响应带 `data.restarting: true`；网关**先回复并写入去重缓存**，再延迟重启，因此 App 重连后重发同一 `reqId` 不会重复执行。

`config.set` 字段：

```text
wifiSsid / wifiPassword / mqttUri / mqttUsername / mqttPassword / gatewayId
keepWifiPassword / keepMqttPassword / clearWifiPassword / clearMqttPassword
```

密码留空默认保留，只有 `clear*Password` 为真才清空。修改 Broker 地址或 `gatewayId` 后主题前缀随之改变，App 需要按新信息重新连接。

## 39.2 与设备控制的关系

`upsert` / `remove` / `save` 会重启网关，执行前应确认没有正在进行的 BLE 操作。

已被协议接管（通过 `connect` 连接）的设备不能使用 `pause` / `resume`，否则返回 `2001`，应改用 `connect` / `disconnect`。

## 39.3 能力上报

支持 `manage` 的网关在 `hello` 事件的 `features` 中给出：

```json
{
  "features": {
    "management": true,
    "managementActions": ["status", "backup", "save", "upsert", "remove", "pause", "resume",
                          "diagnostics", "config.get", "config.set", "restart"]
  }
}
```

App 应以该列表决定显示哪些管理入口；遇到不认识的 `manage` 的旧固件返回 `1002`（`UNSUPPORTED_OP`），App 报错而不回退到 HTTP。
