import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../device_model.dart';

/// 随包发布的设备模型目录
///
/// 设备定义以 JSON 保存在 `assets/devices/` 下，启动时一次性读入并校验，
/// 运行期只按设备标识取用，不再有内嵌在 Dart 里的定义。
class DeviceModelCatalog {
  DeviceModelCatalog._(this._models);

  static const String assetDirectory = 'assets/devices/';

  /// 没有本地配置的设备使用的默认模型标识
  static const String defaultModelId = 'at5';

  static DeviceModelCatalog? _instance;

  static DeviceModelCatalog get instance {
    final instance = _instance;
    if (instance == null) {
      throw StateError('设备模型目录尚未加载');
    }
    return instance;
  }

  static bool get loaded => _instance != null;

  final Map<String, DeviceModel> _models;

  Map<String, DeviceModel> get models => Map.unmodifiable(_models);

  DeviceModel get defaultModel {
    final model = _models[defaultModelId];
    if (model == null) {
      throw StateError('缺少默认设备模型 $defaultModelId');
    }
    return model;
  }

  DeviceModel? modelFor(String id) => _models[id];

  /// 读取全部随包模型；单个文件损坏时直接失败，避免带病启动
  static Future<DeviceModelCatalog> load({
    AssetBundle? bundle,
    List<String>? assets,
  }) async {
    final source = bundle ?? rootBundle;
    final paths = assets ?? await _discover(source);
    return _build({
      for (final path in paths) path: await source.loadString(path),
    });
  }

  /// 从本地文件读取模型，供测试与工具直接使用同一份定义
  static Future<DeviceModelCatalog> loadFiles(List<String> paths) async {
    return _build({for (final path in paths) path: File(path).readAsStringSync()});
  }

  static DeviceModelCatalog _build(Map<String, String> sources) {
    final models = <String, DeviceModel>{};
    for (final entry in sources.entries) {
      final decoded = jsonDecode(entry.value);
      if (decoded is! Map) {
        throw FormatException('${entry.key} 不是设备模型对象');
      }
      final model = DeviceModel.fromJson(
        decoded.map((key, value) => MapEntry(key.toString(), value)),
      );
      if (models.containsKey(model.id)) {
        throw FormatException('设备模型标识重复：${model.id}');
      }
      models[model.id] = model;
    }
    final catalog = DeviceModelCatalog._(models);
    _instance = catalog;
    return catalog;
  }

  static Future<List<String>> _discover(AssetBundle bundle) async {
    final manifest = await AssetManifest.loadFromAssetBundle(bundle);
    return [
      for (final path in manifest.listAssets())
        if (path.startsWith(assetDirectory) && path.endsWith('.json')) path,
    ]..sort();
  }
}
