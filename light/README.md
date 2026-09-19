# light

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## MQTT 设备与网关管理

设备扫描、登记、连接、控制和 ESP32 管理均通过 MQTT。设备页支持网关附近扫描、多设备管理与 AT5 控制；ESP32 管理页支持诊断、登记备份、网络配置和重启。

App 不再直接扫描或连接 BLE：手机只与 MQTT Broker 通信，蓝牙扫描、连接和读写全部由 ESP32 网关执行，因此不再申请蓝牙与定位权限。需要配套 `../esp` 项目 `0.7.0` 或以上的固件（`esp/dist/firmware_merged.bin`）。

连接方式、协议、模拟器和联调步骤见 [远程控制说明](docs/remote-control.md)。

## 模块化设备控制

设备通过功能列表组装控制界面和命令能力，接入方法见 [设备控制模块](docs/device-modules.md)。

除内置的 AT5 灯具外，可以用 JSON 配置接入任意 BLE 设备：配置里声明特征、封包规则（前缀 / 命令字节 / 长度 / 校验）和每条命令的字节布局，App 就按这套规则把功能值编码后经 MQTT 网关下发，并把通知解码回功能状态。字段说明与校验规则见 [通用设备远程读写协议设计](docs/generic-device-codec.md)，入口在 **我的 → 通用设备协议**。
