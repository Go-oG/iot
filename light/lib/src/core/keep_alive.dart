import 'dart:io';

import 'package:flutter_background/flutter_background.dart';

/// 息屏保持：Android 通过前台服务持有部分唤醒锁和无线锁，
/// 避免息屏后定时器被系统挂起、MQTT 心跳停止而被服务器判定为超时断开
/// 仅 Android 支持，其他平台保持调用后不生效
///
/// 主控制链路与 MQTT 调试页会同时申请保持，因此按持有者计数，
/// 只有最后一个持有者释放时才真正关闭前台服务
class KeepAliveService {
  KeepAliveService._();

  /// 主控制链路（首页、设备页的 MQTT 会话）
  static const String controlOwner = 'control';

  /// MQTT 调试页的独立连接
  static const String debugOwner = 'debug';

  static bool get supported => Platform.isAndroid;

  static final Set<String> _owners = {};
  static bool _active = false;

  static bool get active => _active;

  /// 申请息屏保持，首次调用可能请求关闭电池优化；重复申请只增加持有者
  static Future<bool> start({
    String owner = controlOwner,
    String title = '设备控制已连接',
    String text = '正在保持与网关的连接，避免息屏后断开',
  }) async {
    _owners.add(owner);
    if (_active || !supported) return _active;
    try {
      _active = await FlutterBackground.initialize(
        androidConfig: FlutterBackgroundAndroidConfig(
          notificationTitle: title,
          notificationText: text,
          notificationImportance: AndroidNotificationImportance.normal,
        ),
      );
      if (_active)
        _active = await FlutterBackground.enableBackgroundExecution();
    } catch (_) {
      _active = false;
    }
    // 申请失败时不留持有者，避免后续释放被误判为仍在使用
    if (!_active) _owners.remove(owner);
    return _active;
  }

  /// 释放息屏保持；仍有其他持有者时保持前台服务运行
  static Future<void> stop({String owner = controlOwner}) async {
    _owners.remove(owner);
    if (_owners.isNotEmpty || !_active) return;
    _active = false;
    try {
      await FlutterBackground.disableBackgroundExecution();
    } catch (_) {
      // 取消失败不影响页面退出
    }
  }
}
