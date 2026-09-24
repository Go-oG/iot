# HTTP API

## 入口

唯一 JSON API 入口为：

```text
POST http://<网关IP>/api/v1
```

请求体是一条统一请求消息：

```json
{
  "v": 1,
  "type": "req",
  "reqId": "http-001",
  "op": "manage",
  "data": {
    "action": "status"
  }
}
```

响应体是一条统一响应消息：

```json
{
  "v": 1,
  "type": "res",
  "reqId": "http-001",
  "op": "manage",
  "code": 0,
  "message": "ok",
  "ts": 1760000000000,
  "data": {
    "ok": true
  }
}
```

HTTP 请求必须带 `Content-Type: application/json`。浏览器发送 `Origin` 时，其主机必须与 `Host` 一致。HTTP 接口不提供账号认证，不应暴露到互联网。

## 通用字段

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `v` | number | 是 | 固定为 `1` |
| `type` | string | 是 | 固定为 `req` |
| `reqId` | string | 是 | 当前请求 ID，1 至 64 字节 |
| `op` | string | 是 | 操作名，1 至 64 字节 |
| `data` | object | 按操作 | 操作参数 |

HTTP 支持的操作：

| `op` | 说明 |
| --- | --- |
| `manage` | 配置、设备登记、状态、诊断、扫描结果和重启 |
| `scan` | 启动或停止 BLE 扫描 |
| `snapshot` | 获取登记设备的协议状态快照 |

HTTP 的业务错误也使用统一响应：

```json
{
  "v": 1,
  "type": "res",
  "reqId": "http-001",
  "op": "manage",
  "code": 1003,
  "message": "invalid_data",
  "ts": 0
}
```

| HTTP 状态 | 说明 |
| ---: | --- |
| 200 | `code` 为 `0` |
| 400 | JSON、版本、请求 ID、操作参数或业务执行失败 |
| 403 | 非同源请求，`message` 为 `cross_origin_denied` |
| 500 | 网关内存不足或响应生成失败 |

## `manage`

统一管理操作为：

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

支持的 `data.action`：

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
| `diagnostics` | 无 | 固件、内存、Wi-Fi、MQTT 和连接诊断 | 否 |
| `config.get` | 无 | 当前 Wi-Fi / MQTT 配置 | 否 |
| `config.set` | `config` | `{"restarting":true}` | 是 |
| `restart` | 无 | `{"restarting":true}` | 是 |

## 状态

请求：

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

响应 `data`：

```json
{
  "version": 1,
  "devices": [],
  "ok": true,
  "states": [],
  "maxFrameBytes": 65536
}
```

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `version` | number | 设备登记版本，固定为 `1` |
| `devices` | array | 持久化设备登记 |
| `ok` | boolean | 状态快照生成状态 |
| `loadError` | string | 可选；登记分区加载失败原因 |
| `states` | array | 与 `devices` 对应的运行状态 |
| `maxFrameBytes` | number | V1 Frame 最大字节数 |

运行状态字段：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `device` | string | MAC 地址 |
| `state` | string | `disabled`、`paused`、`broadcast`、`connected`、`connecting`、`backoff` |
| `paused` | boolean | 是否被本地管理接口暂停 |
| `protocolOwned` | boolean | 本次启动中是否已由 V1 操作接管 |
| `servicesReady` | boolean | GATT 服务发现是否完成 |
| `rssi` | number | 可选；最近有效 RSSI |
| `lastSeenAgoMs` | number | 距最近发现的毫秒数；未知时为 `-1` |
| `retryInMs` | number | 距离下次自动重连的毫秒数 |
| `failures` | number | 连续连接失败次数 |
| `lastError` | number | 最近一次底层错误码 |
| `lastErrorText` | string | 错误说明 |
| `restoredSubscriptions` | number | 已恢复的自动订阅数量 |
| `intervalStatus` | number | 连接参数更新结果 |
| `actualIntervalMs` | number | 当前连接间隔 |
| `received` | number | 自动上报接收计数 |
| `published` | number | 自动上报已接受计数 |
| `dropped` | number | 自动上报丢弃计数 |

## 配置

### 读取配置

请求：

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

响应 `data`：

```json
{
  "configured": true,
  "wifiSsid": "HomeWiFi",
  "wifiPasswordSet": true,
  "mqttUri": "mqtts://broker.example.com:8883",
  "mqttUsername": "gateway-user",
  "mqttPasswordSet": true,
  "gatewayId": "gw-001"
}
```

### 保存配置

请求：

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
      "wifiPassword": "password123",
      "keepWifiPassword": false,
      "clearWifiPassword": false,
      "mqttUri": "mqtts://broker.example.com:8883",
      "mqttUsername": "gateway-user",
      "mqttPassword": "mqtt-password",
      "keepMqttPassword": false,
      "clearMqttPassword": false,
      "gatewayId": "gw-001"
    }
  }
}
```

配置字段：

| 字段 | 类型 | 必填 | 约束 |
| --- | --- | --- | --- |
| `wifiSsid` | string | 是 | 非空，最多 32 字节 |
| `wifiPassword` | string | 条件 | 最多 64 字节；非空密码至少 8 字节 |
| `keepWifiPassword` | boolean | 否 | 保留现有 Wi-Fi 密码 |
| `clearWifiPassword` | boolean | 否 | 清空 Wi-Fi 密码，优先级最高 |
| `mqttUri` | string | 是 | 非空，最多 191 字节，以 `mqtt://` 或 `mqtts://` 开头 |
| `mqttUsername` | string | 否 | 最多 63 字节 |
| `mqttPassword` | string | 条件 | 最多 127 字节 |
| `keepMqttPassword` | boolean | 否 | 保留现有 MQTT 密码 |
| `clearMqttPassword` | boolean | 否 | 清空 MQTT 密码，优先级最高 |
| `gatewayId` | string | 是 | 1 至 31 字节，只允许字母、数字、`-`、`_` |

成功响应发送后约 1 秒重启。重启前继续使用原网络和 MQTT 连接。

## 设备登记

设备登记结构同时用于 `save`、`backup` 和 `status.devices`。

```json
{
  "version": 1,
  "devices": [
    {
      "device": "AA:BB:CC:DD:EE:01",
      "alias": "温度计",
      "deviceId": "sensor-001",
      "deviceUuid": "0000fff0-0000-1000-8000-00805f9b34fb",
      "addressType": 0,
      "enabled": true,
      "mode": "connection",
      "reportMode": "latest",
      "intervalMinMs": 100,
      "intervalMaxMs": 200,
      "subscriptions": [
        {
          "service": "FFF0",
          "characteristic": "FFF1",
          "indicate": false
        }
      ]
    }
  ]
}
```

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `version` | number | 是 | 固定为 `1` |
| `devices` | array | 是 | 最多 32 台设备 |

设备字段：

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `device` | string | 是 | 17 字节 MAC；清单内不可重复 |
| `alias` | string | 是 | 最多 48 字节 |
| `deviceId` | string | 否 | 1 至 64 字节稳定身份；清单内不可重复 |
| `deviceUuid` | string | 否 | 36 字节带连字符 UUID |
| `addressType` | number | 否 | `0` 至 `3`，默认 `0` |
| `enabled` | boolean | 否 | 默认 `true` |
| `mode` | string | 是 | `connection` 或 `broadcast` |
| `reportMode` | string | 是 | `latest` 或 `stream` |
| `intervalMinMs` | number | 否 | 15 至 4000，且为 5 的倍数，默认 `100` |
| `intervalMaxMs` | number | 否 | 不小于最小值，最大 `4000`，默认 `200` |
| `subscriptions` | array | 是 | 最多 4 条；广播模式必须为空 |

订阅字段：

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `service` | string | 是 | 4、8、32 或 36 位 UUID |
| `characteristic` | string | 是 | 4、8、32 或 36 位 UUID |
| `indicate` | boolean | 否 | 默认 `false` |

### 保存完整登记

```json
{
  "v": 1,
  "type": "req",
  "reqId": "save-001",
  "op": "manage",
  "data": {
    "action": "save",
    "registry": {
      "version": 1,
      "devices": []
    }
  }
}
```

成功响应：

```json
{
  "v": 1,
  "type": "res",
  "reqId": "save-001",
  "op": "manage",
  "code": 0,
  "message": "ok",
  "data": {
    "restarting": true
  }
}
```

保存前会校验全部字段。失败不会覆盖原登记。

### 新增或修改设备

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

### 删除设备

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

### 暂停和恢复

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

`resume` 使用相同结构。设备已由 V1 操作接管时返回 `2001`，消息为 `device_controlled_by_use_connect_disconnect`。

### 下载备份

```json
{
  "v": 1,
  "type": "req",
  "reqId": "backup-001",
  "op": "manage",
  "data": {
    "action": "backup"
  }
}
```

响应 `data` 直接为设备登记对象。备份不包含 Wi-Fi / MQTT 密码、BLE 配对密钥或运行计数。

## 扫描

### 启动扫描

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

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `data.action` | string | 是 | `start` 或 `stop` |
| `data.duration` | number | 否 | 扫描时长，默认 `5000` ms，最大 `120000` ms |
| `data.active` | boolean | 否 | 默认 `true`；`false` 为被动扫描 |

成功响应：

```json
{
  "v": 1,
  "type": "res",
  "reqId": "scan-001",
  "op": "scan",
  "code": 0,
  "message": "ok",
  "data": {
    "scanId": "http-1"
  }
}
```

### 停止扫描

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

### 查询扫描结果

```json
{
  "v": 1,
  "type": "req",
  "reqId": "seen-001",
  "op": "manage",
  "data": {
    "action": "seen"
  }
}
```

响应 `data`：

```json
{
  "devices": [
    {
      "device": "AA:BB:CC:DD:EE:01",
      "name": "Sensor-X",
      "addressType": 1,
      "rssi": -62,
      "lastSeenAgoMs": 850
    }
  ]
}
```

扫描结果只保存在 RAM，最多保留最近 64 项。扫描不会自动连接设备。

## 快照

```json
{
  "v": 1,
  "type": "req",
  "reqId": "snapshot-001",
  "op": "snapshot"
}
```

响应 `data` 与 MQTT `snapshot` 相同：

```json
{
  "revision": 12,
  "devices": [
    {
      "deviceId": "sensor-001",
      "mac": "AA:BB:CC:DD:EE:01",
      "addrType": "public",
      "connection": "connected",
      "services": []
    }
  ]
}
```

快照只包含登记设备。断开后保留最后一次有效特征值和 `ts`。

## 诊断

```json
{
  "v": 1,
  "type": "req",
  "reqId": "diag-001",
  "op": "manage",
  "data": {
    "action": "diagnostics"
  }
}
```

响应 `data` 包含：

| 字段 | 说明 |
| --- | --- |
| `gateway` | 当前网关 ID |
| `firmware` | 固件版本 |
| `chip` | 芯片目标 |
| `maxBleConnections` | BLE 最大连接数 |
| `flashSizeBytes` | Flash 大小 |
| `psramSizeBytes` | PSRAM 大小 |
| `freeInternalHeapBytes` | 当前内部 RAM |
| `largestInternalBlockBytes` | 最大连续内部内存块 |
| `freePsramHeapBytes` | 当前 PSRAM |
| `minimumInternalHeapBytes` | 内部 RAM 最低水位 |
| `uptimeMs` | 运行时间 |
| `wifiConnected` | Wi-Fi 连接状态 |
| `mqttConnected` | MQTT 连接状态 |
| `mqttOutboxBytes` | MQTT outbox 字节数 |
| `mqttRestarts` | MQTT 重建次数 |
| `connectedDevices` | BLE 已连接数量 |
| `connectingDevices` | BLE 连接中数量 |

## 重启

```json
{
  "v": 1,
  "type": "req",
  "reqId": "restart-001",
  "op": "manage",
  "data": {
    "action": "restart"
  }
}
```

HTTP 服务先返回 `{"restarting":true}`，再延迟重启。

## 错误码

HTTP 与 MQTT 使用相同错误码：

| `code` | `message` | 说明 |
| ---: | --- | --- |
| `0` | `ok` | 成功 |
| `1001` | `invalid request` | JSON、版本、请求 ID 或消息结构非法 |
| `1002` | `unsupported operation` | HTTP 未开放该操作或管理动作不支持 |
| `1003` | `invalid argument` | 操作参数、配置或设备登记非法 |
| `2001` | `gateway busy` | 网关忙、内存不足或重启正在进行 |
| `2002` | `queue timeout` | 队列等待超时 |
| `2003` | `connection limit` | 连接名额不足 |
| `3001` | `device not found` | 设备身份未知 |
| `3002` | `not connected` | 设备未连接 |
| `3003` | `connect timeout` | 连接或服务发现失败 |
| `3004` | `device not registered` | 设备未登记 |
| `3101` | `disconnected` | 链路断开 |
| `4001` | `service not found` | 服务不存在 |
| `4002` | `characteristic not found` | 特征不存在 |
| `4003` | `batch failed` | Batch 失败 |
| `4101` | `gatt read failed` | GATT 读取失败 |
| `4201` | `gatt write failed` | GATT 写入失败 |
| `4301` | `gatt subscribe failed` | GATT 订阅失败 |
| `4901` | `gatt timeout` | GATT 超时 |
| `4999` | `skipped` | Batch 步骤跳过 |

配置或设备登记被拒绝时，`message` 可能直接返回具体原因，例如 `invalid_gateway_id`、`duplicate_device` 或 `invalid_subscriptions`。
