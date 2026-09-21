import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:light/src/core/device/util.dart';

import '../protocol/gateway_client.dart';
import 'device_definition.dart';
import 'device_property.dart';
import 'device_runtime.dart';
import 'device_session.dart';
import 'devie_match.dart';
import 'models.dart';
import 'spec/packer_decode_spec.dart';
import 'spec/permission_spec.dart';
import 'template/frame_defaults.dart';
import 'template/packet_encode_pec.dart';
import 'template/parser.dart';

/// 一台设备
/// [Device.fromJson] 直接得到一个设备对象；
/// 传入 [GatewayClient] 后，该对象同时具备连接、订阅、下发、上报与会话状态能力
/// 没有客户端时只作为可持久化的设备定义使用
class Device extends ChangeNotifier {
  Device._(this._definition, this._runtime, this._session, this.deviceId) {
    _session?.addListener(notifyListeners);
  }

  factory Device.fromJson(
    Map<String, dynamic> json, {
    String? deviceId,
    GatewayClient? client,
    Role role = Role.user,
    Duration maxAge = const Duration(minutes: 2),
    Duration ackWindow = const Duration(seconds: 1),
    DateTime Function()? now,
  }) {
    final definition = DeviceDefinition.fromJson(json);
    final runtime = DeviceRuntime(definition);
    final session = client == null
        ? null
        : DeviceSession(
            definition: definition,
            deviceId: deviceId ?? definition.id,
            client: client,
            role: role,
            maxAge: maxAge,
            ackWindow: ackWindow,
            now: now,
          );
    return Device._(definition, runtime, session, deviceId ?? definition.id);
  }

  /// 请求帧模板 → 运行时结构
  static PacketEncodeSpec parseRequest(
    String source, {
    FrameDefaults defaults = const FrameDefaults(),
    String path = 'frame',
  }) => parseRequestTemplate(source, defaults: defaults, path: path);

  /// 响应帧模板 → 运行时结构
  static PacketDecodeSpec parseResponse(
    String source, {
    String? service,
    String? characteristic,
    String path = 'frame',
  }) => parseResponseTemplate(
    source,
    service: service,
    characteristic: characteristic,
    path: path,
  );

  /// 编码结构 → 规范请求模板
  static String writeRequest(
    PacketEncodeSpec spec, {
    FrameDefaults defaults = const FrameDefaults(),
  }) => writeRequestTemplate(spec, defaults: defaults);

  /// 解码结构 → 规范响应模板
  static String writeResponse(PacketDecodeSpec spec) =>
      writeResponseTemplate(spec);

  static const String assetDirectory = 'assets/devices/';
  static const String defaultId = 'at5';

  static final Map<String, Map<String, dynamic>> _builtInDefinitions = {};
  static bool _definitionsLoaded = false;

  static bool get definitionsLoaded => _definitionsLoaded;

  /// 启动时读取全部随包设备 JSON
  static Future<void> loadDefinitions({
    AssetBundle? bundle,
    List<String>? assets,
  }) async {
    final source = bundle ?? rootBundle;
    final paths = assets ?? await _discoverDefinitions(source);
    final sources = <String, String>{
      for (final path in paths) path: await source.loadString(path),
    };
    _loadDefinitions(sources);
  }

  /// 从已有 JSON 文本加载定义，供测试、导入和工具使用
  static void loadDefinitionSources(Map<String, String> sources) {
    _loadDefinitions(sources);
  }

  static void _loadDefinitions(Map<String, String> sources) {
    final definitions = <String, Map<String, dynamic>>{};
    for (final entry in sources.entries) {
      final decoded = jsonDecode(entry.value);
      if (decoded is! Map) {
        throw FormatException('${entry.key} 不是设备 JSON 对象');
      }
      final json = mapOf(decoded);
      final device = DeviceDefinition.fromJson(json);
      if (definitions.containsKey(device.id)) {
        throw FormatException('设备标识重复：${device.id}');
      }
      definitions[device.id] = device.toJson();
    }
    _builtInDefinitions
      ..clear()
      ..addAll(definitions);
    _definitionsLoaded = true;
  }

  static Future<List<String>> _discoverDefinitions(AssetBundle bundle) async {
    final manifest = await AssetManifest.loadFromAssetBundle(bundle);
    return [
      for (final path in manifest.listAssets())
        if (path.startsWith(assetDirectory) && path.endsWith('.json')) path,
    ]..sort();
  }

  /// 默认设备定义，仅用于新建设备模型的初始模板
  static Device get defaultDefinition {
    final json = _builtInDefinitions[defaultId];
    if (json == null) {
      throw StateError('缺少默认设备定义 $defaultId');
    }
    return Device.fromJson(json);
  }

  /// 按标识读取随包设备定义
  static Device? definitionFor(String id) {
    final json = _builtInDefinitions[id];
    return json == null ? null : Device.fromJson(json);
  }

  static Map<String, Device> get definitions => Map.unmodifiable({
    for (final entry in _builtInDefinitions.entries)
      entry.key: Device.fromJson(entry.value),
  });

  final DeviceDefinition _definition;
  final DeviceRuntime _runtime;
  final DeviceSession? _session;

  /// 本次会话控制的实际设备标识
  final String deviceId;

  /// 协议模板标识，多台设备可以共用同一个模板
  String get modelId => _definition.id;

  String get id => deviceId;

  String get name => _definition.name;

  List<DeviceMatchRule> get match => _definition.match;

  Map<String, DeviceProperty> get properties => _definition.properties;

  String? get service => _definition.service;

  String? get characteristic => _definition.characteristic;

  FrameDefaults get frame => _definition.frame;

  bool get online => _session != null;

  Role get role => _session?.role ?? Role.user;

  Duration get maxAge => _session?.maxAge ?? const Duration(minutes: 2);

  Duration get ackWindow => _session?.ackWindow ?? const Duration(seconds: 1);

  Map<String, DevicePropertyState> get reported =>
      _session?.reported ?? const {};

  Map<String, Object?> get desired => _session?.desired ?? const {};

  List<DeviceCommandRecord> get commands => _session?.commands ?? const [];

  String? get lastError => _session?.lastError;

  bool get ready => _session?.ready ?? false;

  bool get busy => _session?.busy ?? false;

  bool get stale => _session?.stale ?? true;

  bool isFresh(DevicePropertyState state) => _session?.isFresh(state) ?? false;

  bool canRead(String property) => _session?.canRead(property) ?? false;

  bool canWrite(String property) => _session?.canWrite(property) ?? false;

  bool canNotify(String property) => _session?.canNotify(property) ?? false;

  DeviceProperty property(String propertyId) =>
      _definition.property(propertyId);

  Uint8List encodeWrite(
    String propertyId,
    Object? value, {
    Map<String, Object?> propertyState = const {},
    Map<String, Object?> variables = const {},
    int sequence = 0,
    DateTime? timestamp,
  }) => _runtime.encodeWrite(
    propertyId,
    value,
    propertyState: propertyState,
    variables: variables,
    sequence: sequence,
    timestamp: timestamp,
  );

  Uint8List? encodeReadRequest(
    String propertyId, {
    Map<String, Object?> propertyState = const {},
    Map<String, Object?> variables = const {},
    int sequence = 0,
    DateTime? timestamp,
  }) => _runtime.encodeReadRequest(
    propertyId,
    propertyState: propertyState,
    variables: variables,
    sequence: sequence,
    timestamp: timestamp,
  );

  Object? decodeRead(String propertyId, Uint8List packet) =>
      _runtime.decodeRead(propertyId, packet);

  Object? decodeNotify(String propertyId, Uint8List packet) =>
      _runtime.decodeNotify(propertyId, packet);

  Map<String, Object?> decodeNotifyPatch(String propertyId, Uint8List packet) =>
      _runtime.decodeNotifyPatch(propertyId, packet);

  List<DecodedNotification> decodeNotifications(
    String service,
    String characteristic,
    Uint8List packet,
  ) => _runtime.decodeNotifications(service, characteristic, packet);

  Future<void> start() => _requireSession().connect();

  Future<void> refresh() => _requireSession().refresh();

  Future<DeviceCommandRecord> readProperty(String property) =>
      _requireSession().readProperty(property);

  Future<DeviceCommandRecord> writeProperty(String property, Object? value) =>
      _requireSession().writeProperty(property, value);

  Future<DeviceCommandRecord> writeProperties(
    Iterable<DevicePropertyWrite> values,
  ) => _requireSession().writeProperties(values);

  List<DecodedNotification> handleFrame(
    Uint8List packet, {
    required String service,
    required String characteristic,
    DateTime? sampledAt,
    bool verified = false,
    String? bootId,
    int? sequence,
  }) => _requireSession().handleFrame(
    packet,
    service: service,
    characteristic: characteristic,
    sampledAt: sampledAt,
    verified: verified,
    bootId: bootId,
    sequence: sequence,
  );

  DeviceSession _requireSession() {
    final session = _session;
    if (session == null) {
      throw StateError('设备尚未绑定 GatewayClient');
    }
    return session;
  }

  Map<String, dynamic> toJson() => _definition.toJson();

  String toJsonString() => jsonEncode(toJson());

  @override
  void dispose() {
    _session?.removeListener(notifyListeners);
    _session?.dispose();
    super.dispose();
  }
}
