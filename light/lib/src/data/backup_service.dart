import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:file_selector/file_selector.dart';
import 'package:share_plus/share_plus.dart';

class BackupService {
  static const _jsonType = XTypeGroup(
    label: '备份数据',
    extensions: ['json'],
    mimeTypes: ['application/json'],
    uniformTypeIdentifiers: ['public.json', 'public.text'],
    webWildCards: ['application/json'],
  );

  Future<String?> pickJson() async {
    final file = await openFile(
      acceptedTypeGroups: const [_jsonType],
      confirmButtonText: '导入',
    );
    return file?.readAsString();
  }

  Future<String> exportJson(
    String json, {
    required String fileName,
    Rect? sharePositionOrigin,
  }) async {
    final bytes = Uint8List.fromList(utf8.encode(json));
    final file = XFile.fromData(
      bytes,
      mimeType: 'application/json',
      name: fileName,
    );
    if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
      final location = await getSaveLocation(
        acceptedTypeGroups: const [_jsonType],
        suggestedName: fileName,
        confirmButtonText: '保存',
      );
      if (location == null) {
        return '已取消导出';
      }
      await file.saveTo(location.path);
      return '数据已导出到 ${location.path}';
    }

    await SharePlus.instance.share(
      ShareParams(
        title: '让光数据导出',
        files: [file],
        fileNameOverrides: [fileName],
        sharePositionOrigin: sharePositionOrigin,
      ),
    );
    return '已打开系统分享';
  }
}
