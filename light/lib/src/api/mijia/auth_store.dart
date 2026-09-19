
import 'dart:convert';
import 'dart:io';

/// Where the auth blob lives between runs.
abstract class MijiaAuthStore {
  const MijiaAuthStore();

  /// Returns the stored auth blob, or `null` when nothing has been saved yet.
  Future<Map<String, dynamic>?> read();

  /// Persists [data], replacing any previous blob.
  Future<void> write(Map<String, dynamic> data);

  /// Removes the stored blob, if any.
  Future<void> clear();
}

/// Keeps the auth blob in memory only. Useful for tests and for apps that
/// manage persistence themselves.
class MemoryAuthStore extends MijiaAuthStore {
  MemoryAuthStore([Map<String, dynamic>? initial])
      : _data = initial == null ? null : Map<String, dynamic>.from(initial);

  Map<String, dynamic>? _data;

  @override
  Future<Map<String, dynamic>?> read() async =>
      _data == null ? null : Map<String, dynamic>.from(_data!);

  @override
  Future<void> write(Map<String, dynamic> data) async {
    _data = Map<String, dynamic>.from(data);
  }

  @override
  Future<void> clear() async => _data = null;
}

/// Stores the auth blob as a JSON file, the equivalent of the Python
/// `auth_data_path` argument.
class FileAuthStore extends MijiaAuthStore {
  const FileAuthStore(this.file);

  /// Resolves the default location, mirroring
  /// `~/.config/mijia-api/auth.json`.
  ///
  /// On Windows the Python library still writes to `~/.config`, so
  /// [USERPROFILE] is used when [HOME] is unset.
  factory FileAuthStore.defaultLocation() {
    final env = Platform.environment;
    final home = env['HOME'] ?? env['USERPROFILE'] ?? '.';
    return FileAuthStore(File('$home/.config/mijia-api/auth.json'));
  }

  /// Resolves a path that may be either a directory or a file, so the
  /// `auth_data_path` argument behaves the same as in Python.
  factory FileAuthStore.forPath(String path) {
    final normalized = path.replaceAll('\\', Platform.pathSeparator);
    if (Directory(normalized).existsSync()) {
      return FileAuthStore(
        File('$normalized${Platform.pathSeparator}auth.json'),
      );
    }
    return FileAuthStore(File(normalized));
  }

  final File file;

  @override
  Future<Map<String, dynamic>?> read() async {
    if (!await file.exists()) return null;
    final text = await file.readAsString();
    if (text.trim().isEmpty) return null;
    final decoded = jsonDecode(text);
    if (decoded is! Map) return null;
    return Map<String, dynamic>.from(decoded);
  }

  @override
  Future<void> write(Map<String, dynamic> data) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(data),
    );
  }

  @override
  Future<void> clear() async {
    if (await file.exists()) {
      await file.delete();
    }
  }
}
