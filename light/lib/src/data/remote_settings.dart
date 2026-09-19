import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class RemoteSettings {
  const RemoteSettings({
    required this.host,
    required this.gatewayId,
    this.port = 8883,
    this.tls = true,
    this.username = '',
    this.password = '',
    this.enabled = true,
    this.bluetoothDeviceId = '',
  });

  final String host;
  final int port;
  final bool tls;
  final String username;
  final String password;

  /// 网关唯一标识，对应协议帧的 gatewayId 与主题中的网关段
  final String gatewayId;

  final bool enabled;
  final String bluetoothDeviceId;

  RemoteSettings withDevice(String id) => RemoteSettings(
    host: host,
    port: port,
    tls: tls,
    username: username,
    password: password,
    gatewayId: gatewayId,
    enabled: enabled,
    bluetoothDeviceId: id,
  );

  void validate() {
    if (host.trim().isEmpty ||
        host.contains('://') ||
        host.contains('/') ||
        host.contains(RegExp(r'\s'))) {
      throw const FormatException('请输入服务器域名或 IP，不含协议前缀和路径');
    }
    if (port < 1 || port > 65535) throw const FormatException('端口应为 1–65535');
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,64}$').hasMatch(gatewayId)) {
      throw const FormatException('网关标识只能包含字母、数字、下划线或连字符，最多 64 位');
    }
  }

  Map<String, Object?> toJson() => {
    'host': host,
    'port': port,
    'tls': tls,
    'username': username,
    'password': password,
    'gatewayId': gatewayId,
    'enabled': enabled,
    'bluetoothDeviceId': bluetoothDeviceId,
  };

  factory RemoteSettings.fromJson(Map<String, dynamic> json) {
    // 兼容旧版本保存的 deviceId 字段
    final gatewayId = json['gatewayId'] ?? json['deviceId'];
    if (gatewayId is! String) throw const FormatException('远程配置缺少网关标识');
    final value = RemoteSettings(
      host: json['host'] as String,
      port: json['port'] as int? ?? 8883,
      tls: json['tls'] as bool? ?? true,
      username: json['username'] as String? ?? '',
      password: json['password'] as String? ?? '',
      gatewayId: gatewayId,
      enabled: json['enabled'] as bool? ?? true,
      bluetoothDeviceId: json['bluetoothDeviceId'] as String? ?? '',
    );
    value.validate();
    return value;
  }
}

abstract interface class RemoteSettingsStore {
  Future<RemoteSettings?> read();
  Future<void> write(RemoteSettings settings);
  Future<void> clear();
}

class SecureRemoteSettingsStore implements RemoteSettingsStore {
  static const _storage = FlutterSecureStorage();
  static const _key = 'light_remote_settings_v1';

  @override
  Future<RemoteSettings?> read() async {
    final value = await _storage.read(key: _key);
    return value == null
        ? null
        : RemoteSettings.fromJson(jsonDecode(value) as Map<String, dynamic>);
  }

  @override
  Future<void> write(RemoteSettings settings) =>
      _storage.write(key: _key, value: jsonEncode(settings.toJson()));

  @override
  Future<void> clear() => _storage.delete(key: _key);
}

class MemoryRemoteSettingsStore implements RemoteSettingsStore {
  RemoteSettings? settings;

  @override
  Future<RemoteSettings?> read() async => settings;

  @override
  Future<void> write(RemoteSettings value) async {
    settings = value;
  }

  @override
  Future<void> clear() async {
    settings = null;
  }
}
