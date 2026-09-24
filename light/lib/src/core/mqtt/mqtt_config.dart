import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class MqttConfig {
  const MqttConfig({
    required this.host,
    required this.gatewayId,

    this.port = 8883,
    this.tls = true,
    this.username = '',
    this.password = '',
    this.enabled = true,
    this.bluetoothDeviceId = '',
    this.autoReconnect = false,
    this.keepAlivePeriod = 30,
    this.connectTimeoutPeriod = 8000,
    this.log = false,
  });

  final bool enabled;

  final String host;
  final int port;
  final bool tls;
  final String username;
  final String password;

  /// 网关唯一标识，对应协议帧的 gatewayId 与主题中的网关段
  /// 由ESP 32 管理界面获取
  final String gatewayId;

  final String bluetoothDeviceId;
  final bool autoReconnect;
  final int keepAlivePeriod;
  final int connectTimeoutPeriod;
  final bool log;

  MqttConfig withDevice(String id) => MqttConfig(
    host: host,
    port: port,
    tls: tls,
    username: username,
    password: password,
    gatewayId: gatewayId,
    enabled: enabled,
    bluetoothDeviceId: id,
    autoReconnect: autoReconnect,
    keepAlivePeriod: keepAlivePeriod,
    connectTimeoutPeriod: connectTimeoutPeriod,
    log: log,
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

  factory MqttConfig.fromJson(Map<String, dynamic> json) {
    // 兼容旧版本保存的 deviceId 字段
    final gatewayId = json['gatewayId'] ?? json['deviceId'];
    if (gatewayId is! String) throw const FormatException('远程配置缺少网关标识');
    final value = MqttConfig(
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

abstract interface class MqttConfigStore {
  Future<MqttConfig?> read();

  Future<void> write(MqttConfig settings);
  Future<void> clear();
}

class SecureMqttConfigStore implements MqttConfigStore {
  static const _storage = FlutterSecureStorage();
  static const _key = 'mqtt_config';

  @override
  Future<MqttConfig?> read() async {
    final value = await _storage.read(key: _key);
    return value == null ? null : MqttConfig.fromJson(jsonDecode(value) as Map<String, dynamic>);
  }

  @override
  Future<void> write(MqttConfig settings) => _storage.write(key: _key, value: jsonEncode(settings.toJson()));

  @override
  Future<void> clear() => _storage.delete(key: _key);
}
