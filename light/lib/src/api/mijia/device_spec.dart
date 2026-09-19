import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import 'errors.dart';

/// Base URL of the public device-spec site.
const String deviceSpecBaseUrl = 'https://home.miot-spec.com/spec/';

/// Bump when the normalised shape below changes, to invalidate caches.
const int deviceInfoVersion = 1;

/// User agent sent to the spec site.
const String deviceSpecUserAgent = 'mijiaAPI/4.2.1';

/// Property value types this library can encode.
const List<String> supportedPropertyTypes = [
  'bool',
  'int',
  'uint',
  'float',
  'string',
];

/// Fetches and normalises the spec for [deviceModel] (e.g.
/// `yeelink.light.lamp4`).
///
/// When [cacheDir] is given the result is cached as `{model}.json` inside it,
/// exactly as the Python library does next to `auth.json`. Pass [refresh] to
/// bypass a valid cache entry, and [baseUrl] to point at a mirror.
///
/// The returned map has `version`, `name`, `model`, `properties` and
/// `actions`. Each property carries `name`, `description`, `type`, `rw`,
/// `range`, `value-list` and `method` (`siid`/`piid`); each action carries
/// `name`, `description` and `method` (`siid`/`aiid`).
///
/// Throws [GetDeviceInfoException] when the spec cannot be read.
Future<Map<String, dynamic>> fetchDeviceInfo(
  String deviceModel, {
  Directory? cacheDir,
  Dio? dio,
  String baseUrl = deviceSpecBaseUrl,
  bool refresh = false,
}) async {
  final cacheFile = cacheDir == null
      ? null
      : File('${cacheDir.path}${Platform.pathSeparator}$deviceModel.json');

  if (!refresh && cacheFile != null && await cacheFile.exists()) {
    try {
      final cached = jsonDecode(await cacheFile.readAsString());
      if (cached is Map && cached['version'] == deviceInfoVersion) {
        return Map<String, dynamic>.from(cached);
      }
    } on Object {
      // A corrupt cache is simply refetched.
    }
  }

  final client = dio ??
      Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 30),
          receiveTimeout: const Duration(seconds: 30),
          validateStatus: (_) => true,
          responseType: ResponseType.plain,
        ),
      );

  final Response<dynamic> response;
  try {
    response = await client.get<dynamic>(
      '$baseUrl$deviceModel',
      options: Options(
        headers: <String, String>{'User-Agent': deviceSpecUserAgent},
        responseType: ResponseType.plain,
        validateStatus: (_) => true,
      ),
    );
  } on DioException {
    throw GetDeviceInfoException(deviceModel);
  }

  if (response.statusCode != 200) {
    throw GetDeviceInfoException(deviceModel);
  }

  final match = RegExp(
    r'<script data-page="app" type="application/json">(.*?)</script>',
    dotAll: true,
  ).firstMatch('${response.data}');
  if (match == null) {
    throw GetDeviceInfoException(deviceModel);
  }

  final result = _normalize(
    deviceModel,
    Map<String, dynamic>.from(jsonDecode(match.group(1)!) as Map),
  );

  if (cacheFile != null) {
    await cacheFile.parent.create(recursive: true);
    await cacheFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(result),
    );
  }
  return result;
}

Map<String, dynamic> _normalize(
  String deviceModel,
  Map<String, dynamic> content,
) {
  final props = Map<String, dynamic>.from(content['props'] as Map);
  final product = Map<String, dynamic>.from(props['product'] as Map);
  final i18n = props['i18n'] is Map
      ? Map<String, dynamic>.from(props['i18n'] as Map)
      : <String, dynamic>{};
  final zh = i18n['zh_cn'] is Map
      ? Map<String, dynamic>.from(i18n['zh_cn'] as Map)
      : <String, dynamic>{};
  final tree = Map<String, dynamic>.from(props['tree'] as Map);
  final services = tree['services'] as List<dynamic>;

  final result = <String, dynamic>{
    'version': deviceInfoVersion,
    'name': product['name'],
    'model': product['model'] ?? deviceModel,
    'properties': <dynamic>[],
    'actions': <dynamic>[],
  };
  final properties = result['properties'] as List<dynamic>;
  final actions = result['actions'] as List<dynamic>;

  for (final service in services) {
    final svc = Map<String, dynamic>.from(service as Map);
    final siid = svc['iid'] as int;

    for (final prop in (svc['properties'] as List<dynamic>?) ?? const []) {
      final map = Map<String, dynamic>.from(prop as Map);
      final piid = map['iid'] as int;
      final format = '${map['format']}';
      final access = (map['access'] as List<dynamic>?) ?? const [];

      final property = <String, dynamic>{
        'name': map['type'],
        'description': _joinDescription(
          '${map['description'] ?? ''}',
          '${zh['service:${_pad(siid)}:property:${_pad(piid)}'] ?? ''}',
        ),
        'type': format.startsWith('int')
            ? 'int'
            : format.startsWith('uint')
                ? 'uint'
                : format,
        'rw': '${access.contains('read') ? 'r' : ''}'
            '${access.contains('write') ? 'w' : ''}',
        'range': map['valueRange'],
        'value-list': null,
        'method': <String, dynamic>{'siid': siid, 'piid': piid},
      };

      final valueList = map['valueList'];
      if (valueList is List && valueList.isNotEmpty) {
        final entries = <dynamic>[];
        for (final item in valueList) {
          final entry = Map<String, dynamic>.from(item as Map);
          final zhText = zh['${entry['i18nKey'] ?? ''}'];
          final valueEntry = <String, dynamic>{
            'value': entry['value'],
            'description': entry['description'],
          };
          if (zhText != null && '$zhText'.isNotEmpty) {
            valueEntry['desc_zh_cn'] = zhText;
          }
          entries.add(valueEntry);
        }
        property['value-list'] = entries;
      }

      properties.add(property);
    }

    for (final action in (svc['actions'] as List<dynamic>?) ?? const []) {
      final map = Map<String, dynamic>.from(action as Map);
      final aiid = map['iid'] as int;
      actions.add(<String, dynamic>{
        'name': map['type'],
        'description': _joinDescription(
          '${map['description'] ?? ''}',
          '${zh['service:${_pad(siid)}:action:${_pad(aiid)}'] ?? ''}',
        ),
        'method': <String, dynamic>{'siid': siid, 'aiid': aiid},
      });
    }
  }

  _deduplicateNames(properties, 'piid');
  _deduplicateNames(actions, 'aiid');
  return result;
}

String _pad(int value) => value.toString().padLeft(3, '0');

/// `f"{description} / {zh}".rstrip(" / ")`.
String _joinDescription(String description, String zh) {
  final combined = zh.isEmpty ? description : '$description / $zh';
  return combined.replaceAll(RegExp(r'[ /]+$'), '');
}

/// Disambiguates duplicate names by appending `siid`, then the item id.
///
/// Each pass snapshots its counts before rewriting, so the second pass sees the
/// names the first produced — matching the Python behaviour.
void _deduplicateNames(List<dynamic> items, String iidKey) {
  for (final suffixKey in <String>['siid', iidKey]) {
    final counts = <String, int>{};
    for (final item in items) {
      final name = '${_item(item)['name']}';
      counts[name] = (counts[name] ?? 0) + 1;
    }
    for (final item in items) {
      final map = _item(item);
      final name = '${map['name']}';
      if ((counts[name] ?? 0) <= 1) continue;
      final method = Map<String, dynamic>.from(map['method'] as Map);
      map['name'] = '$name-${method[suffixKey]}';
    }
  }
}

Map<String, dynamic> _item(dynamic item) => item is Map<String, dynamic>
    ? item
    : Map<String, dynamic>.from(item as Map);
