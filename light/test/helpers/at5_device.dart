import 'dart:io';

import 'package:light/src/core/device/device_model_catalog.dart';
import 'package:light/src/core/device_model.dart';

/// 测试直接读取随包发布的 AT5 设备模型
final DeviceModel at5DeviceModel = DeviceModel.fromJsonString(
  File('assets/devices/at5.json').readAsStringSync(),
);

/// AT5 协议常量：与 assets/devices/at5.json 里的帧定义对应
const List<int> at5RequestHeader = [0x34, 0x43, 0x88, 0x88];
const List<int> at5ResponseHeader = [0x43, 0x34, 0x88, 0x88];
const int at5CommandOffset = 4;
const int at5StatusOffset = 7;
const String at5ServiceUuid = '8332af20-6d0e-4eea-bb35-665544332211';
const String at5CharacteristicUuid = at5ServiceUuid;
const Map<String, int> at5CommandBytes = {
  'time': 0x01,
  'channels': 0x03,
  'timer': 0x04,
  'power': 0x05,
  'temperature': 0x06,
  'fanSpeed': 0x06,
};

/// 测试进程没有 Flutter 资源包，直接用同一份随包文件建立模型目录
Future<void> loadDeviceModelCatalog() =>
    DeviceModelCatalog.loadFiles(['assets/devices/at5.json']);
