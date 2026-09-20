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

所有设备都使用设备模型 JSON 接入：模型声明属性、读写通知操作、请求帧字段、长度与校验、响应匹配和界面渲染器，通用层按模型渲染控件、编码下发并解析上报。模型定义见 [device_model.dart](lib/src/core/device_model.dart)，会话见 [device_model_session.dart](lib/src/core/device/device_model_session.dart)，接入方法见 [设备模块与设备模型](docs/device-modules.md)，入口在 **设备页 → 编辑设备模型**。

帧定义使用字符串模板，例如 `AA55 ${length:u8} ${seq:u8} 2103 ${value:u16be,scale=0.1} ${crc16modbus}`：出现顺序即帧内顺序，长度与校验范围按字段名引用，模型载入时编译成运行时结构。

配色与计划同样保存设备属性值：应用配色、切换计划、调整输出上限都经设备模型会话下发，控制器不保存灯光面板状态。

## 设备模型与架构分析

- [设备管理与命令下发分析](docs/architecture-review.md)
- [设备模块与设备模型](docs/device-modules.md)
