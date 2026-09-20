"""BLE 网关协议模拟器，不连接真实灯具

实现 ble_gateway_mqtt_app_protocol.md 的网关侧：固定三个主题、帧与消息编解码、
BLE 原子操作、批处理、状态缓存、版本号、请求去重与在线状态

灯具部分是内置的 AT5 模拟器，只按 BLE 报文回执，不包含任何业务含义
"""

import argparse
import json
import os
import threading
import time
import uuid
from collections import OrderedDict, deque

import paho.mqtt.client as mqtt

PROTOCOL_VERSION = 1
MAX_DEDUP = 256

OK = 0
INVALID_REQUEST = 1001
UNSUPPORTED_OP = 1002
INVALID_ARGUMENT = 1003
QUEUE_TIMEOUT = 2002
DEVICE_NOT_FOUND = 3001
NOT_CONNECTED = 3002
CONNECT_TIMEOUT = 3003
SERVICE_NOT_FOUND = 4001
CHAR_NOT_FOUND = 4002
WRITE_FAILED = 4201
SUBSCRIBE_FAILED = 4301
GATT_TIMEOUT = 4901
SKIPPED = 4999

# AT5 灯具协议，只用于模拟 BLE 回执
AT5_SERVICE = "8332af20-6d0e-4eea-bb35-665544332211"
AT5_CHARACTERISTIC = "8332af20-6d0e-4eea-bb35-665544332211"
AT5_REQUEST_HEADER = bytes([0x34, 0x43, 0x88, 0x88])
AT5_RESPONSE_HEADER = bytes([0x43, 0x34, 0x88, 0x88])
AT5_COMMAND_SYNC_TIME = 0x01


def crc16_modbus(data):
    crc = 0xFFFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            if crc & 0x0001:
                crc = (crc >> 1) ^ 0xA001
            else:
                crc >>= 1
    return crc & 0xFFFF


def at5_response(command, payload):
    """构造 AT5 -> 手机的响应帧，线上 CRC 顺序为高字节在前"""
    frame = bytearray(AT5_RESPONSE_HEADER)
    frame.append(command)
    frame.append(0x00)
    frame.append(len(payload))
    frame.extend(payload)
    crc = crc16_modbus(frame)
    frame.append((crc >> 8) & 0xFF)
    frame.append(crc & 0xFF)
    return bytes(frame)


def at5_command(packet):
    """从手机 -> AT5 的报文中取出命令字，非法报文返回 None"""
    if len(packet) < 9 or bytes(packet[:4]) != AT5_REQUEST_HEADER:
        return None
    return packet[4]


class SimulatedLamp:
    """模拟 AT5 灯具，只负责对 BLE 报文回执"""

    def respond(self, packet):
        command = at5_command(packet)
        if command is None:
            return None
        if command == AT5_COMMAND_SYNC_TIME:
            return at5_response(command, bytes([0x01, 0x00, 0x1F, 0x02, 0x1E, 0x00, 0x0A, 0x14]))
        return at5_response(command, bytes([0x00]))


class SimulatedDevice:
    def __init__(self, device_id, mac, name=""):
        self.device_id = device_id
        self.mac = mac or device_id
        self.name = name
        self.connection = "disconnected"
        self.subscriptions = {}
        self.characteristics = {}
        self.pending_notify = deque()
        self.rssi = -51

    def connection_event(self, state, code=0, message=None, reason=None):
        event = {
            "type": "event",
            "op": "connection",
            "deviceId": self.device_id,
            "data": {"state": state},
            "ts": int(time.time() * 1000),
        }
        if state == "connected":
            event["data"]["mtu"] = 247
        if reason is not None:
            event["data"]["reason"] = reason
        if code:
            event["code"] = code
        if message:
            event["message"] = message
        return event

    def snapshot(self):
        services = {}
        for (service, characteristic), entry in self.characteristics.items():
            services.setdefault(service, []).append(
                {"uuid": characteristic, "value": entry["value"], "ts": entry["ts"]}
            )
        return {
            "deviceId": self.device_id,
            "mac": self.mac,
            "name": self.name,
            "addrType": "public",
            "connection": self.connection,
            "rssi": self.rssi,
            "lastSeen": int(time.time() * 1000),
            "services": [{"uuid": service, "chars": chars} for service, chars in services.items()],
        }


class Gateway:
    def __init__(self, gateway_id, lamp=None, max_connections=5, debug=False):
        self.gateway_id = gateway_id
        self.lamp = lamp or SimulatedLamp()
        self.max_connections = max_connections
        self.debug = debug
        self.lock = threading.RLock()
        self.devices = OrderedDict()
        self.revision = 0
        self.dedup = OrderedDict()
        self.publish = None
        self.extra_events = []

    def topics(self):
        prefix = f"iot/v1/{self.gateway_id}"
        return f"{prefix}/down", f"{prefix}/up", f"{prefix}/presence"

    def device(self, device_id):
        device = self.devices.get(device_id)
        if device is None:
            device = SimulatedDevice(device_id, device_id)
            self.devices[device_id] = device
            self.devices.move_to_end(device_id)
            if len(self.devices) > 16:
                self.devices.popitem(last=False)
        return device

    def hello(self):
        return {
            "type": "event",
            "op": "hello",
            "data": {
                "protocol": PROTOCOL_VERSION,
                "firmware": "sim-1.0",
                "ble": {"maxConnections": self.max_connections, "maxGattOps": 4},
                "features": {"batch": True, "snapshot": True, "scan": True, "notify": True, "waitNotify": True},
                "formats": ["hex", "base64", "utf8"],
            },
        }

    def handle_down(self, client_id, messages, retained=False):
        """处理一个下行帧，返回需要回复的响应消息列表"""
        responses = []
        for message in messages:
            if not isinstance(message, dict):
                continue
            if message.get("type") != "req":
                continue
            if retained:
                responses.append(
                    self.reply(message, INVALID_REQUEST, "retained_command")
                )
                continue
            key = (client_id or "", message.get("reqId"))
            cached = self.dedup.get(key)
            if cached is not None:
                # 去重命中时不重复执行，直接重发上一次响应
                responses.append(cached)
                continue
            response = self.dispatch(message)
            if response is not None and key[1]:
                self.dedup[key] = response
                self.dedup.move_to_end(key)
                if len(self.dedup) > MAX_DEDUP:
                    self.dedup.popitem(last=False)
                responses.append(response)
        return responses

    def reply(self, request, code=OK, message=None, data=None, **extra):
        response = {"type": "res", "reqId": request.get("reqId"), "op": request.get("op"), "code": code}
        for field in ("deviceId", "service", "char"):
            if field in request:
                response[field] = request[field]
        response["message"] = message if message is not None else ("ok" if code == OK else None)
        if data is not None:
            response["data"] = data
        response["ts"] = int(time.time() * 1000)
        response.update(extra)
        return response

    def dispatch(self, request):
        op = request.get("op")
        if op == "snapshot":
            return self.reply(request, data=self.state_snapshot())
        if op == "scan":
            return self.handle_scan(request)
        if op == "connect":
            return self.handle_connect(request)
        if op == "disconnect":
            return self.handle_disconnect(request)
        if op == "subscribe":
            return self.handle_subscribe(request)
        if op == "write":
            return self.handle_write(request)
        if op == "read":
            return self.handle_read(request)
        if op == "waitNotify":
            return self.handle_wait_notify(request)
        if op == "batch":
            return self.handle_batch(request)
        return self.reply(request, UNSUPPORTED_OP, "unsupported_op")

    def state_snapshot(self):
        with self.lock:
            return {
                "revision": self.revision,
                "devices": [device.snapshot() for device in self.devices.values()],
            }

    def handle_scan(self, request):
        data = request.get("data") or {}
        if data.get("action", "start") != "start":
            return self.reply(request, data={"scanId": data.get("scanId", ""), "stopped": True})
        scan_id = f"s-{uuid.uuid4().hex[:8]}"
        device = self.device(data.get("deviceId") or "sim-device")
        self.extra_events.append(
            {
                "type": "event",
                "op": "scan",
                "data": {
                    "scanId": scan_id,
                    "devices": [
                        {
                            "deviceId": device.device_id,
                            "mac": device.mac,
                            "addrType": "public",
                            "rssi": device.rssi,
                            "name": "AT5 模拟灯",
                        }
                    ],
                },
                "ts": int(time.time() * 1000),
            }
        )
        return self.reply(request, data={"scanId": scan_id})

    def handle_connect(self, request):
        device_id = request.get("deviceId")
        if not device_id:
            return self.reply(request, INVALID_ARGUMENT, "missing_device_id")
        device = self.device(device_id)
        data = request.get("data") or {}
        if data.get("mac"):
            device.mac = data["mac"]
        if device.connection != "connected":
            device.connection = "connected"
            self.extra_events.append(device.connection_event("connected"))
        return self.reply(request, data={"state": device.connection, "mtu": 247})

    def handle_disconnect(self, request):
        device = self.devices.get(request.get("deviceId"))
        if device is None:
            return self.reply(request, DEVICE_NOT_FOUND, "device_not_found")
        device.connection = "disconnected"
        device.subscriptions.clear()
        self.extra_events.append(device.connection_event("disconnected"))
        return self.reply(request, data={"state": device.connection})

    def handle_subscribe(self, request):
        device = self.devices.get(request.get("deviceId"))
        if device is None:
            return self.reply(request, DEVICE_NOT_FOUND, "device_not_found")
        if device.connection != "connected":
            return self.reply(request, NOT_CONNECTED, "not_connected")
        service = request.get("service")
        characteristic = request.get("char")
        if not service or not characteristic:
            return self.reply(request, INVALID_ARGUMENT, "missing_characteristic")
        data = request.get("data") or {}
        enabled = data.get("enabled", True)
        if enabled:
            device.subscriptions[(service, characteristic)] = {
                "mode": data.get("mode", "auto"),
                "delivery": data.get("delivery", "stream"),
            }
        else:
            device.subscriptions.pop((service, characteristic), None)
        return self.reply(request, data={"enabled": enabled, "count": len(device.subscriptions)})

    def handle_read(self, request):
        device = self.devices.get(request.get("deviceId"))
        if device is None:
            return self.reply(request, DEVICE_NOT_FOUND, "device_not_found")
        entry = self.lookup(device, request)
        if entry is None:
            return self.reply(request, CHAR_NOT_FOUND, "char_not_found")
        return self.reply(request, data={"value": entry["value"], "format": "hex", "ts": entry["ts"]})

    def handle_write(self, request):
        device = self.devices.get(request.get("deviceId"))
        if device is None:
            return self.reply(request, DEVICE_NOT_FOUND, "device_not_found")
        if device.connection != "connected":
            return self.reply(request, NOT_CONNECTED, "not_connected")
        value = request.get("value")
        if not isinstance(value, str):
            return self.reply(request, INVALID_ARGUMENT, "missing_value")
        service, characteristic = request.get("service"), request.get("char")
        if not service or not characteristic:
            return self.reply(request, INVALID_ARGUMENT, "missing_characteristic")
        try:
            packet = bytes.fromhex(value)
        except ValueError:
            return self.reply(request, INVALID_ARGUMENT, "invalid_value")
        # 网关只做 BLE 传输，灯具业务协议由 App 解析
        if service.lower() == AT5_SERVICE and characteristic.lower() == AT5_CHARACTERISTIC:
            response = self.lamp.respond(packet)
            if response is not None:
                self.record_notify(device, service, characteristic, response)
        if self.debug:
            print(f"write {device.device_id} {value}", flush=True)
        return self.reply(request, data={"written": True, "writeType": (request.get("data") or {}).get("writeType", "withResponse")})

    def handle_wait_notify(self, request):
        device = self.devices.get(request.get("deviceId"))
        if device is None:
            return self.reply(request, DEVICE_NOT_FOUND, "device_not_found")
        timeout = request.get("timeout") or 1000
        deadline = time.time() + timeout / 1000
        while True:
            with self.lock:
                for index, entry in enumerate(device.pending_notify):
                    if entry["service"] == request.get("service") and entry["char"] == request.get("char"):
                        device.pending_notify.remove(entry)
                        return self.reply(request, data={"value": entry["value"], "format": "hex", "ts": entry["ts"]})
            if time.time() >= deadline:
                return self.reply(request, GATT_TIMEOUT, "wait_notify_timeout")
            time.sleep(0.01)

    def handle_batch(self, request):
        device_id = request.get("deviceId")
        data = request.get("data") or {}
        steps = data.get("steps")
        if not isinstance(steps, list) or not steps:
            return self.reply(request, INVALID_ARGUMENT, "missing_steps")
        if data.get("autoConnect") and device_id:
            device = self.device(device_id)
            if device.connection != "connected":
                device.connection = "connected"
                self.extra_events.append(device.connection_event("connected"))
        stop_on_error = bool(data.get("stopOnError", False))
        results = []
        failed = False
        for index, step in enumerate(steps):
            if not isinstance(step, dict):
                results.append({"id": f"s{index}", "code": INVALID_ARGUMENT, "message": "invalid_step"})
                failed = True
                continue
            step_id = str(step.get("id", f"s{index}"))
            if failed and stop_on_error:
                results.append({"id": step_id, "code": SKIPPED, "message": "skipped"})
                continue
            nested = dict(step)
            nested.setdefault("type", "req")
            nested["reqId"] = None
            nested["deviceId"] = nested.get("deviceId", device_id)
            response = self.dispatch(nested)
            result = {"id": step_id, "code": response.get("code", OK)}
            if response.get("message") not in (None, "ok"):
                result["message"] = response["message"]
            payload = response.get("data") or {}
            if "value" in payload:
                result["value"] = payload["value"]
                result["format"] = payload.get("format", "hex")
            results.append(result)
            if result["code"] != OK:
                failed = True
        code = OK if not failed else WRITE_FAILED
        return self.reply(request, code, None if code == OK else "batch_failed", data={"steps": results})

    def lookup(self, device, request):
        for (service, characteristic), entry in device.characteristics.items():
            if service == request.get("service") and characteristic == request.get("char"):
                return entry
        return None

    def record_notify(self, device, service, characteristic, packet):
        value = packet.hex()
        with self.lock:
            device.characteristics[(service, characteristic)] = {"value": value, "ts": int(time.time() * 1000)}
            self.revision += 1
            device.pending_notify.append(
                {"service": service, "char": characteristic, "value": value, "ts": int(time.time() * 1000)}
            )
            subscription = device.subscriptions.get((service, characteristic))
            delta = {
                "revision": self.revision,
                "devices": [
                    {
                        "deviceId": device.device_id,
                        "services": [
                            {
                                "uuid": service,
                                "chars": [
                                    {"uuid": characteristic, "value": value, "ts": int(time.time() * 1000)}
                                ],
                            }
                        ],
                    }
                ],
            }
            if subscription and subscription.get("delivery", "stream") == "stream":
                self.extra_events.append(
                    {
                        "type": "event",
                        "op": "notify",
                        "deviceId": device.device_id,
                        "service": service,
                        "char": characteristic,
                        "value": value,
                        "format": "hex",
                        "ts": int(time.time() * 1000),
                    }
                )
                self.extra_events.append({"type": "event", "op": "state", "data": delta, "ts": int(time.time() * 1000)})


def main():
    parser = argparse.ArgumentParser(description="BLE 网关协议模拟器，不连接真实灯具")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=18883)
    parser.add_argument("--gateway", default="gw-001", help="网关标识，对应主题中的 gatewayId")
    parser.add_argument("--username", default="")
    parser.add_argument("--tls", action="store_true")
    parser.add_argument("--debug", action="store_true")
    args = parser.parse_args()

    gateway = Gateway(args.gateway, debug=args.debug)
    down_topic, up_topic, presence_topic = gateway.topics()
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=f"gw_{uuid.uuid4().hex[:12]}", clean_session=True)
    if args.username:
        client.username_pw_set(args.username, os.environ.get("LIGHT_MQTT_PASSWORD", ""))
    if args.tls:
        client.tls_set()
    client.will_set(presence_topic, json.dumps({"online": False, "ts": int(time.time() * 1000)}), qos=1, retain=True)

    def publish_messages(messages, retained=False):
        if not messages:
            return
        frame = {
            "v": PROTOCOL_VERSION,
            "gatewayId": args.gateway,
            "ts": int(time.time() * 1000),
            "messages": messages,
        }
        client.publish(up_topic, json.dumps(frame), qos=1, retain=retained)

    def on_connect(client, userdata, flags, reason_code, properties):
        if reason_code.is_failure:
            print("网关连接 Broker 失败", flush=True)
            return
        client.subscribe(down_topic, qos=1)
        client.publish(
            presence_topic,
            json.dumps({"online": True, "ts": int(time.time() * 1000)}),
            qos=1,
            retain=True,
        )
        publish_messages([gateway.hello()])
        print(f"网关 {args.gateway} 已连接，主题 {down_topic}", flush=True)

    def on_message(client, userdata, message):
        if message.retain:
            # retain 的下行命令不执行，只回复协议错误
            try:
                frame = json.loads(message.payload)
            except (ValueError, UnicodeDecodeError):
                return
            if isinstance(frame, dict):
                gateway.handle_down(frame.get("clientId", ""), frame.get("messages", []), retained=True)
            return
        try:
            frame = json.loads(message.payload)
        except (ValueError, UnicodeDecodeError):
            return
        if not isinstance(frame, dict) or frame.get("v") != PROTOCOL_VERSION:
            return
        if frame.get("gatewayId") != args.gateway:
            return
        messages = frame.get("messages")
        if not isinstance(messages, list):
            return
        with gateway.lock:
            gateway.extra_events = []
            responses = gateway.handle_down(frame.get("clientId", ""), messages)
            extra = list(gateway.extra_events)
        if responses:
            publish_messages(responses)
        if extra:
            publish_messages(extra)

    client.on_connect = on_connect
    client.on_message = on_message
    client.connect(args.host, args.port, keepalive=20)
    client.loop_start()
    try:
        while True:
            time.sleep(15)
            if client.is_connected():
                client.publish(
                    presence_topic,
                    json.dumps({"online": True, "ts": int(time.time() * 1000)}),
                    qos=1,
                    retain=True,
                )
    except KeyboardInterrupt:
        client.publish(
            presence_topic,
            json.dumps({"online": False, "ts": int(time.time() * 1000)}),
            qos=1,
            retain=True,
        ).wait_for_publish(2)
    finally:
        client.disconnect()
        client.loop_stop()


if __name__ == "__main__":
    main()
