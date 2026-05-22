import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'download_storage.dart';

/// Default storage backend: writes under
/// `getApplicationDocumentsDirectory()/downloads/<relativePath>` and returns
/// the absolute filesystem path as the handle. This is the legacy behavior
/// from before the storage-location picker existed; iOS always uses this
/// (Apple does not expose SAF), and Android falls back to it when the user
/// has not picked an alternate location.
class InternalDownloadStorage extends DownloadStorage {
  Directory? _rootCache;

  Future<Directory> _ensureRoot() async {
    if (_rootCache != null) return _rootCache!;
    final docs = await getApplicationDocumentsDirectory();
    final root = Directory('${docs.path}/downloads');
    if (!await root.exists()) {
      await root.create(recursive: true);
    }
    _rootCache = root;
    return root;
  }

  Future<File> _resolve(String relativePath) async {
    final root = await _ensureRoot();
    final file = File('${root.path}/$relativePath');
    final parent = file.parent;
    if (!await parent.exists()) {
      await parent.create(recursive: true);
    }
    return file;
  }

  @override
  Future<String> writeBytes(String relativePath, Uint8List bytes) async {
    final file = await _resolve(relativePath);
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  @override
  Future<bool> exists(String handle) async {
    if (handle.isEmpty) return false;
    return File(handle).exists();
  }

  @override
  Future<int> length(String handle) async {
    if (handle.isEmpty) return 0;
    try {
      return await File(handle).length();
    } catch (_) {
      return 0;
    }
  }

  @override
  Future<void> deleteRecursive(String relativeDir) async {
    try {
      final root = await _ensureRoot();
      final dir = Directory('${root.path}/$relativeDir');
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {
      // Best-effort — a missing directory just means there was nothing to clean.
    }
  }

  @override
  Future<Uint8List> readBytes(String handle) async {
    final raw = await File(handle).readAsBytes();
    return Uint8List.fromList(raw);
  }
}
