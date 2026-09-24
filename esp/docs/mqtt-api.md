# MQTT V1 API

## Topic

| Topic | 方向 | QoS | Retain | 说明 |
| --- | --- | ---: | --- | --- |
| `iot/v1/{gatewayId}/down` | 网关订阅 | 1 | 拒绝 retained 下行 | 接收客户端 Frame |
| `iot/v1/{gatewayId}/up` | 网关发布 | 按消息类型 | 否 | 响应和事件 |
| `iot/v1/{gatewayId}/presence` | 网关发布 | 1 | 是 | 在线状态和 LWT |

配置支持 `mqtt://` 和 `mqtts://`。`mqtts://` 使用 ESP-IDF 公共根证书包。MQTT Keep Alive 为 30 秒。

## Frame

MQTT 下行 Frame：

```json
{
  "v": 1,
  "gatewayId": "gw-001",
  "clientId": "app-001",
  "messages": [
    {
      "v": 1,
      "type": "req",
      "reqId": "status-001",
      "op": "manage",
      "data": {
        "action": "status"
      }
    }
  ]
}
```

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| 外层 `v` | number | 是 | Frame 版本，固定为 `1` |
| `gatewayId` | string | 是 | 必须等于当前网关 ID |
| `clientId` | string | 是 | 1 至 64 字节 |
| `messages` | array | 是 | 最多 64 条请求消息 |

每条请求消息必须包含：

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `v` | number | 是 | 请求消息版本，固定为 `1` |
| `type` | string | 是 | 固定为 `req` |
| `reqId` | string | 是 | 当前请求 ID，1 至 64 字节 |
| `op` | string | 是 | 操作名 |
| `deviceId` | string | 按操作 | 已登记设备身份 |
| `service` | string | 按操作 | 4、8、32 或 36 位 UUID |
| `char` | string | 按操作 | 4、8、32 或 36 位 UUID |
| `value` | string | write | 写入值 |
| `format` | string | 否 | `hex`、`base64`、`utf8` |
| `timeout` | number | 否 | 1 至 120000 ms |
| `queueTimeout` | number | 否 | 1 至 120000 ms |
| `data` | object | 按操作 | 操作参数 |

响应 Frame：

```json
{
  "v": 1,
  "gatewayId": "gw-001",
  "clientId": "app-001",
  "ts": 1760000000000,
  "messages": [
    {
      "v": 1,
      "type": "res",
      "reqId": "status-001",
      "op": "manage",
      "code": 0,
      "message": "ok",
      "ts": 1760000000000,
      "data": {
        "ok": true
      }
    }
  ]
}
```

响应消息和 HTTP 的响应消息使用完全相同的字段。

## 操作汇总

| `op` | 说明 |
| --- | --- |
| `manage` | 配置、设备登记、状态、诊断、扫描结果和重启 |
| `scan` | 启动或停止扫描 |
| `connect` | 连接登记设备 |
| `disconnect` | 断开连接 |
| `read` | 读取 Characteristic |
| `write` | 写入 Characteristic |
| `subscribe` | 订阅或取消通知 |
| `batch` | 顺序执行最多 32 步 |
| `snapshot` | 获取状态快照 |

`discover`、`waitNotify` 不支持，返回 `1002`。`features.waitNotify` 固定为 `false`。

## `manage`

请求：

```json
{
  "v": 1,
  "type": "req",
  "reqId": "mg-001",
  "op": "manage",
  "data": {
    "action": "status"
  }
}
```

支持的动作：

| `action` | 参数 | 返回 `data` | 重启 |
| --- | --- | --- | --- |
| `status` | 无 | 设备登记、`states` 和 `maxFrameBytes` | 否 |
| `backup` | 无 | 完整设备登记 JSON | 否 |
| `save` | `registry` | `{"restarting":true}` | 是 |
| `upsert` | `device` | `{"restarting":true}` | 是 |
| `remove` | `device` | `{"restarting":true}` | 是 |
| `pause` | `device` | 最新设备状态 | 否 |
| `resume` | `device` | 最新设备状态 | 否 |
| `seen` | 无 | 最近扫描发现设备 | 否 |
| `diagnostics` | 无 | 诊断对象 | 否 |
| `config.get` | 无 | 当前 Wi-Fi / MQTT 配置 | 否 |
| `config.set` | `config` | `{"restarting":true}` | 是 |
| `restart` | 无 | `{"restarting":true}` | 是 |

`manage` 的参数、设备登记和配置格式与 [HTTP API](http-api.md) 完全一致。

### 状态

```json
{
  "v": 1,
  "type": "req",
  "reqId": "status-001",
  "op": "manage",
  "data": {
    "action": "status"
  }
}
```

### 配置

读取：

```json
{
  "v": 1,
  "type": "req",
  "reqId": "config-get-001",
  "op": "manage",
  "data": {
    "action": "config.get"
  }
}
```

保存：

```json
{
  "v": 1,
  "type": "req",
  "reqId": "config-set-001",
  "op": "manage",
  "data": {
    "action": "config.set",
    "config": {
      "wifiSsid": "HomeWiFi",
      "keepWifiPassword": true,
      "mqttUri": "mqtts://broker.example.com:8883",
      "mqttUsername": "gateway-user",
      "keepMqttPassword": true,
      "gatewayId": "gw-001"
    }
  }
}
```

配置保存成功后先返回响应，再延迟重启。

### 设备登记

新增或修改：

```json
{
  "v": 1,
  "type": "req",
  "reqId": "upsert-001",
  "op": "manage",
  "data": {
    "action": "upsert",
    "device": {
      "device": "AA:BB:CC:DD:EE:01",
      "alias": "温度计",
      "enabled": true,
      "mode": "connection",
      "reportMode": "latest",
      "intervalMinMs": 100,
      "intervalMaxMs": 200,
      "subscriptions": []
    }
  }
}
```

删除：

```json
{
  "v": 1,
  "type": "req",
  "reqId": "remove-001",
  "op": "manage",
  "data": {
    "action": "remove",
    "device": "AA:BB:CC:DD:EE:01"
  }
}
```

暂停和恢复：

```json
{
  "v": 1,
  "type": "req",
  "reqId": "pause-001",
  "op": "manage",
  "data": {
    "action": "pause",
    "device": "AA:BB:CC:DD:EE:01"
  }
}
```

设备已被 V1 操作接管时，`pause` / `resume` 返回 `2001`。

## `scan`

启动：

```json
{
  "v": 1,
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

停止：

```json
{
  "v": 1,
  "type": "req",
  "reqId": "scan-stop-001",
  "op": "scan",
  "data": {
    "action": "stop"
  }
}
```

成功响应 `data.scanId` 为当前扫描 ID。扫描结果通过 `scan` 事件上报；HTTP 也可通过 `manage.seen` 查询同一扫描结果缓存。

## `connect`

```json
{
  "v": 1,
  "type": "req",
  "reqId": "connect-001",
  "op": "connect",
  "deviceId": "sensor-001",
  "data": {
    "mac": "AA:BB:CC:DD:EE:01",
    "addrType": "public",
    "policy": "queue",
    "queueTimeout": 10000
  }
}
```

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `deviceId` | string | 已登记设备身份 |
| `data.mac` | string | 可选，必须与登记地址一致 |
| `data.addrType` | string | `public` 或 `random` |
| `data.policy` | string | `queue` 或 `reject` |
| `data.queueTimeout` | number | 默认 `10000` ms |
| `timeout` | number | 连接超时，默认 `15000` ms |

## `disconnect`

```json
{
  "v": 1,
  "type": "req",
  "reqId": "disconnect-001",
  "op": "disconnect",
  "deviceId": "sensor-001"
}
```

## `read`

```json
{
  "v": 1,
  "type": "req",
  "reqId": "read-001",
  "op": "read",
  "deviceId": "sensor-001",
  "service": "FFF0",
  "char": "FFF1",
  "format": "hex"
}
```

读取成功时，响应消息顶层包含 `value` 和 `format`：

```json
{
  "v": 1,
  "type": "res",
  "reqId": "read-001",
  "op": "read",
  "deviceId": "sensor-001",
  "service": "fff0",
  "char": "fff1",
  "code": 0,
  "message": "ok",
  "value": "01A0",
  "format": "hex"
}
```

`format` 支持 `hex`、`base64`、`utf8`，默认 `hex`。UTF-8 结果含零字节或非法编码时返回 `1003`。

## `write`

```json
{
  "v": 1,
  "type": "req",
  "reqId": "write-001",
  "op": "write",
  "deviceId": "sensor-001",
  "service": "FFF0",
  "char": "FFF1",
  "value": "01A0",
  "format": "hex",
  "data": {
    "writeType": "withResponse"
  }
}
```

`writeType` 支持 `withResponse` 和 `withoutResponse`。单次写入不能超过协商后的 ATT 载荷和 512 字节，超长数据需要客户端分片。

## `subscribe`

```json
{
  "v": 1,
  "type": "req",
  "reqId": "subscribe-001",
  "op": "subscribe",
  "deviceId": "sensor-001",
  "service": "FFF0",
  "char": "FFF1",
  "data": {
    "enabled": true,
    "mode": "auto",
    "delivery": "stream"
  }
}
```

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `data.enabled` | boolean | 默认 `true`；`false` 取消订阅 |
| `data.mode` | string | `auto`、`notify`、`indicate` |
| `data.delivery` | string | `latest` 或 `stream` |

`latest` 只更新缓存和状态；`stream` 额外产生 `notify` 事件。

## `batch`

```json
{
  "v": 1,
  "type": "req",
  "reqId": "batch-001",
  "op": "batch",
  "deviceId": "sensor-001",
  "timeout": 15000,
  "data": {
    "stopOnError": true,
    "autoConnect": true,
    "steps": [
      {
        "id": "connect",
        "op": "connect"
      },
      {
        "id": "subscribe",
        "op": "subscribe",
        "service": "FFF0",
        "char": "FFF1",
        "data": {
          "mode": "auto",
          "delivery": "stream"
        }
      },
      {
        "id": "read",
        "op": "read",
        "service": "FFF0",
        "char": "FFF1"
      }
    ]
  }
}
```

Batch 最多 32 步。任一失败时总体 `code` 为 `4003`；`stopOnError` 为 `true` 时，未执行步骤返回 `4999`。

响应中的 `data.steps` 示例：

```json
{
  "steps": [
    {
      "id": "connect",
      "code": 0
    },
    {
      "id": "read",
      "code": 0,
      "value": "01",
      "format": "hex"
    }
  ]
}
```

## `snapshot`

```json
{
  "v": 1,
  "type": "req",
  "reqId": "snapshot-001",
  "op": "snapshot"
}
```

响应：

```json
{
  "revision": 12,
  "devices": [
    {
      "deviceId": "sensor-001",
      "mac": "AA:BB:CC:DD:EE:01",
      "addrType": "public",
      "connection": "connected",
      "services": [
        {
          "uuid": "fff0",
          "chars": [
            {
              "uuid": "fff1",
              "value": "01",
              "ts": 1760000000000
            }
          ]
        }
      ]
    }
  ]
}
```

## 响应字段

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `v` | number | 固定为 `1` |
| `type` | string | 固定为 `res` |
| `reqId` | string | 对应的请求 ID |
| `op` | string | 对应操作 |
| `deviceId` | string | 对应设备 |
| `service` | string | 对应服务 UUID |
| `char` | string | 对应特征 UUID |
| `code` | number | 稳定错误码 |
| `message` | string | 响应说明 |
| `ts` | number | Unix 毫秒时间戳 |
| `data` | object | 扩展结果 |
| `value` | string | 读取结果 |
| `format` | string | 读取结果编码 |

底层 Bluedroid、GATT 或 ESP-IDF 错误通过 `data.nativeCode` 返回。

## 事件

事件与响应一样放在 Frame 的 `messages` 中：

| `op` | QoS | 说明 |
| --- | ---: | --- |
| `hello` | 1 | MQTT 连接后的能力信息 |
| `connection` | 1 | 连接状态变化 |
| `scan` | 0 | 扫描发现聚合结果 |
| `notify` | 1 | stream 通知 |
| `state` | 0 | 状态增量 |
| `overflow` | 1 | 缓冲溢出 |

### `hello`

```json
{
  "v": 1,
  "gatewayId": "gw-001",
  "ts": 1760000000000,
  "messages": [
    {
      "v": 1,
      "type": "event",
      "op": "hello",
      "ts": 1760000000000,
      "data": {
        "protocol": 1,
        "firmware": "0.7.0",
        "timeSynced": true,
        "ble": {
          "maxConnections": 32,
          "maxGattOps": 4,
          "requireRegistration": true
        },
        "features": {
          "management": true,
          "batch": true,
          "snapshot": true,
          "scan": true,
          "notify": true,
          "waitNotify": false,
          "managementActions": [
            "status",
            "backup",
            "save",
            "upsert",
            "remove",
            "pause",
            "resume",
            "seen",
            "diagnostics",
            "config.get",
            "config.set",
            "restart"
          ]
        },
        "formats": [
          "hex",
          "base64",
          "utf8"
        ],
        "maxFrameBytes": 65536,
        "dedupEntries": 128,
        "dedupBytes": 262144,
        "counters": {
          "unmatchedNotify": 0
        }
      }
    }
  ]
}
```

### `connection`

```json
{
  "v": 1,
  "gatewayId": "gw-001",
  "messages": [
    {
      "v": 1,
      "type": "event",
      "op": "connection",
      "deviceId": "sensor-001",
      "ts": 1760000000000,
      "data": {
        "state": "connected",
        "mtu": 247
      }
    }
  ]
}
```

### `scan`

```json
{
  "v": 1,
  "gatewayId": "gw-001",
  "messages": [
    {
      "v": 1,
      "type": "event",
      "op": "scan",
      "ts": 1760000000000,
      "data": {
        "scanId": "s-1",
        "devices": [
          {
            "deviceId": "AA:BB:CC:DD:EE:01",
            "mac": "AA:BB:CC:DD:EE:01",
            "addrType": "public",
            "rssi": -55,
            "lastSeen": 1760000000000,
            "name": "Sensor-X",
            "advertisement": "0201060509424C45",
            "registered": false
          }
        ]
      }
    }
  ]
}
```

### `notify`

```json
{
  "v": 1,
  "gatewayId": "gw-001",
  "messages": [
    {
      "v": 1,
      "type": "event",
      "op": "notify",
      "deviceId": "sensor-001",
      "service": "fff0",
      "char": "fff1",
      "value": "01A0",
      "format": "hex",
      "ts": 1760000000000
    }
  ]
}
```

### `state`

```json
{
  "v": 1,
  "gatewayId": "gw-001",
  "messages": [
    {
      "v": 1,
      "type": "event",
      "op": "state",
      "ts": 1760000000000,
      "data": {
        "revision": 13,
        "devices": []
      }
    }
  ]
}
```

状态每 200 ms 聚合一次。发现版本跳跃或收到新的 hello 后，应重新请求 snapshot。

### `overflow`

```json
{
  "v": 1,
  "gatewayId": "gw-001",
  "messages": [
    {
      "v": 1,
      "type": "event",
      "op": "overflow",
      "code": 2001,
      "message": "gateway busy",
      "ts": 1760000000000,
      "data": {
        "dropped": 1
      }
    }
  ]
}
```

## Presence

在线 retained 消息：

```json
{
  "online": true,
  "ts": 1760000000000,
  "gateway": "gw-001",
  "firmware": "0.7.0",
  "ble": true,
  "classic": false
}
```

离线 LWT：

```json
{
  "online": false,
  "gateway": "gw-001"
}
```

## 错误码

| `code` | `message` | 说明 |
| ---: | --- | --- |
| `0` | `ok` | 成功 |
| `1001` | `invalid request` | Frame 或请求消息结构非法 |
| `1002` | `unsupported operation` | 操作不支持 |
| `1003` | `invalid argument` | 参数非法 |
| `2001` | `gateway busy` | 网关忙或资源不足 |
| `2002` | `queue timeout` | 队列超时 |
| `2003` | `connection limit` | 连接名额不足 |
| `3001` | `device not found` | 设备未知 |
| `3002` | `not connected` | 未连接 |
| `3003` | `connect timeout` | 连接失败或超时 |
| `3004` | `device not registered` | 设备未登记 |
| `3101` | `disconnected` | 链路断开 |
| `4001` | `service not found` | 服务不存在 |
| `4002` | `characteristic not found` | 特征不存在 |
| `4003` | `batch failed` | Batch 失败 |
| `4101` | `gatt read failed` | GATT 读取失败 |
| `4201` | `gatt write failed` | GATT 写入失败 |
| `4301` | `gatt subscribe failed` | 订阅失败 |
| `4901` | `gatt timeout` | GATT 超时 |
| `4999` | `skipped` | Batch 跳过 |

## 执行限制

| 资源 | 上限 |
| --- | ---: |
| Frame | 65536 字节 |
| `messages` | 64 条 |
| 待处理请求 | 64 条 |
| Batch 步数 | 32 |
| 运行态设备 | 64 |
| 持久化登记设备 | 32 |
| BLE 连接 | 32 |
| Characteristic 缓存 | 192 |
| 单特征值 | 512 字节 |
| 回调队列 | 128 条 |
| stream 队列 | 128 条 |
| 去重缓存 | 128 条且最多 256 KiB |
| MQTT outbox | 256 KiB |

同一设备严格 FIFO。不同设备最多同时推进 4 个 GATT 操作。超时操作会关闭链路并隔离最迟 5 秒，避免迟到回调串到后续请求。

去重键为 `(clientId, reqId)`。完成结果只保存在 RAM，重启后清空。

## WebSocket

启用 HTTP WebSocket 后提供：

```text
ws://<网关IP>/ble/v1
```

WebSocket 与 MQTT 使用相同 Frame、请求消息和响应消息。响应只返回请求会话，事件广播给所有会话。WebSocket 不支持 continuation，单条文本 Frame 最大 65536 字节。
