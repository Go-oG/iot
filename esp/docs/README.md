# ESP32 网关接口文档

本文档描述 ESP32-C5 BLE 网关当前使用的统一 HTTP / MQTT V1 接口。固件版本为 `0.7.0`。

## 文档索引

| 文档 | 内容 |
| --- | --- |
| [HTTP API](http-api.md) | `POST /api/v1`、管理操作、扫描、快照、设备登记和配置 |
| [MQTT V1 API](mqtt-api.md) | MQTT Topic、Frame、管理操作、BLE 操作、响应和事件 |

## 统一消息结构

HTTP 请求体是一条消息对象，MQTT 将同一条消息对象放入 Frame 的 `messages` 数组。两者使用相同字段和操作参数。

请求消息：

```json
{
  "v": 1,
  "type": "req",
  "reqId": "request-001",
  "op": "manage",
  "data": {
    "action": "status"
  }
}
```

响应消息：

```json
{
  "v": 1,
  "type": "res",
  "reqId": "request-001",
  "op": "manage",
  "code": 0,
  "message": "ok",
  "ts": 1760000000000,
  "data": {
    "ok": true
  }
}
```

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `v` | number | 协议版本，当前固定为 `1`；每个请求都必须携带 |
| `type` | string | 请求固定为 `req`，响应固定为 `res` |
| `reqId` | string | 当前请求 ID，1 至 64 字节；每个请求都必须携带 |
| `op` | string | 操作名，HTTP 和 MQTT 共用 |
| `data` | object | 操作参数；不同 `op` 使用统一定义 |
| `code` | number | 响应状态码，`0` 表示成功 |
| `message` | string | 响应说明 |

同一个 MQTT `clientId` 在去重缓存有效期内，每个不同的操作必须使用不同的 `reqId`。HTTP 请求同样要求 `reqId`，即使 HTTP 服务本身不参与 MQTT 去重。

## 接口入口

| 入口 | 地址 | 说明 |
| --- | --- | --- |
| HTTP 管理 API | `POST http://<网关IP>/api/v1` | 请求体为一条统一请求消息 |
| MQTT 下行 | `iot/v1/{gatewayId}/down` | Frame 的 `messages` 数组承载统一请求消息 |
| MQTT 上行 | `iot/v1/{gatewayId}/up` | Frame 的 `messages` 数组承载统一响应和事件消息 |
| MQTT 在线状态 | `iot/v1/{gatewayId}/presence` | QoS 1 + retained |
| WebSocket | `ws://<网关IP>/ble/v1` | 与 MQTT 相同的 Frame 结构 |

HTML 页面 `/` 和 `/config` 不是 JSON API。

## 操作划分

| `op` | HTTP | MQTT | 说明 |
| --- | --- | --- | --- |
| `manage` | 支持 | 支持 | 配置、设备登记、状态、诊断、扫描结果和重启 |
| `scan` | 支持 | 支持 | 启动或停止 BLE 扫描 |
| `snapshot` | 支持 | 支持 | 获取登记设备状态快照 |
| `connect` | 不支持 | 支持 | MQTT / WebSocket BLE 连接 |
| `disconnect` | 不支持 | 支持 | MQTT / WebSocket BLE 断开 |
| `read` | 不支持 | 支持 | MQTT / WebSocket GATT 读取 |
| `write` | 不支持 | 支持 | MQTT / WebSocket GATT 写入 |
| `subscribe` | 不支持 | 支持 | MQTT / WebSocket 通知订阅 |
| `batch` | 不支持 | 支持 | MQTT / WebSocket Batch 操作 |

HTTP 返回 `1002` 表示该操作未开放到 HTTP；MQTT 和 WebSocket 支持完整 V1 操作集。

## 通用约定

- JSON 使用 UTF-8 编码
- `gatewayId` 仅允许字母、数字、`-`、`_`，长度为 1 至 31 字节
- MAC 地址使用大写冒号格式，例如 `AA:BB:CC:DD:EE:01`
- UUID 支持 4、8、32、36 位十六进制写法
- MQTT 和 WebSocket Frame 中的协议时间戳使用 Unix 毫秒，同步前为 `0`
- HTTP 接口没有账号认证，仅应在可信局域网使用
