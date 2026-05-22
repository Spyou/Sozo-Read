import 'dart:io';
import 'dart:typed_data';

import 'package:saf_stream/saf_stream.dart';
import 'package:saf_util/saf_util.dart';

import 'download_storage.dart';

/// Android-only [DownloadStorage] backed by a user-picked SAF tree URI.
/// The tree URI is granted persistable read+write permission by
/// [DownloadStorageLocator.pickAndPersist] and survives app restarts /
/// uninstall-reinstall (until the user revokes it via system settings).
///
/// SAF does not expose POSIX paths: every directory and file is its own
/// `content://...document/...` URI, and traversal requires either listing
/// or `child(uri, names)`. We cache the *directory* URIs we walk through so
/// the common case (writing 20-100 sequential pages into one chapter dir)
/// doesn't re-resolve the same parent on every page.
///
/// On non-Android platforms `Platform.isAndroid` is false and these calls
/// will throw at the plugin layer — callers must route to
/// [InternalDownloadStorage] on iOS, which [DownloadStorageLocator] does.
class SafDownloadStorage extends DownloadStorage {
  SafDownloadStorage(this.treeUri);

  /// The persistable tree URI returned by `SafUtil.pickDirectory`.
  final String treeUri;

  final SafUtil _util = SafUtil();
  final SafStream _stream = SafStream();

  /// Cache of resolved directory URIs keyed by the slash-joined relative
  /// path (e.g. `mangadex/<bookId>/<chapterId>`). Saves a `mkdirp` round
  /// trip per page after the first one in the same chapter.
  final Map<String, String> _dirCache = {};

  /// Cache of resolved leaf-file URIs so `exists` / `length` / `readBytes`
  /// don't have to re-walk the tree for previously written pages.
  final Map<String, String> _fileCache = {};

  /// Splits a relative path into (directory segments, file name). The file
  /// name is whatever follows the final `/`; everything before it is the
  /// directory chain that needs to exist before we can create the file.
  ({List<String> dirs, String name}) _split(String relativePath) {
    final parts = relativePath.split('/').where((s) => s.isNotEmpty).toList();
    if (parts.isEmpty) {
      throw ArgumentError('empty relativePath');
    }
    final name = parts.removeLast();
    return (dirs: parts, name: name);
  }

  Future<String> _ensureDir(List<String> dirs) async {
    if (dirs.isEmpty) return treeUri;
    final key = dirs.join('/');
    final cached = _dirCache[key];
    if (cached != null) return cached;
    final doc = await _util.mkdirp(treeUri, dirs);
    _dirCache[key] = doc.uri;
    return doc.uri;
  }

  /// Best-effort MIME guess from the extension. SAF doesn't strictly require
  /// the right MIME (the bytes are the bytes), but Android file pickers /
  /// gallery apps key off this when surfacing the file later.
  String _mimeFor(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot < 0) return 'application/octet-stream';
    switch (fileName.substring(dot + 1).toLowerCase()) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'webp':
        return 'image/webp';
      case 'gif':
        return 'image/gif';
      case 'avif':
        return 'image/avif';
      default:
        return 'application/octet-stream';
    }
  }

  @override
  Future<String> writeBytes(String relativePath, Uint8List bytes) async {
    final split = _split(relativePath);
    final parentUri = await _ensureDir(split.dirs);
    // `writeFileBytes` with overwrite=true replaces any existing file of the
    // same name — important for resume-after-pause where we may write the
    // same page index twice if the previous attempt failed mid-stream.
    final res = await _stream.writeFileBytes(
      parentUri,
      split.name,
      _mimeFor(split.name),
      bytes,
      overwrite: true,
    );
    final handle = res.uri.toString();
    _fileCache[relativePath] = handle;
    return handle;
  }

  @override
  Future<bool> exists(String handle) async {
    if (handle.isEmpty) return false;
    try {
      return await _util.exists(handle, false);
    } catch (_) {
      return false;
    }
  }

  @override
  Future<int> length(String handle) async {
    if (handle.isEmpty) return 0;
    try {
      final doc = await _util.documentFileFromUri(handle, false);
      return doc?.length ?? 0;
    } catch (_) {
      return 0;
    }
  }

  @override
  Future<void> deleteRecursive(String relativeDir) async {
    final parts =
        relativeDir.split('/').where((s) => s.isNotEmpty).toList();
    if (parts.isEmpty) return;
    try {
      final doc = await _util.child(treeUri, parts);
      if (doc != null) {
        await _util.delete(doc.uri, true);
      }
    } catch (_) {
      // Best-effort.
    }
    // Drop any cached entries that pointed inside the now-deleted dir.
    final prefix = '$relativeDir/';
    _dirCache.removeWhere((k, _) => k == relativeDir || k.startsWith(prefix));
    _fileCache.removeWhere((k, _) => k.startsWith(prefix));
  }

  @override
  Future<Uint8List> readBytes(String handle) async {
    return _stream.readFileBytes(handle);
  }

  /// Copy a previously written SAF file into a local filesystem path. Used
  /// by `DownloadsRepository`'s temp-file workflow to materialize bytes for
  /// `Image.file`-style callers when the per-page cache misses.
  Future<void> copyToLocal(String handle, String destPath) async {
    final parent = File(destPath).parent;
    if (!await parent.exists()) {
      await parent.create(recursive: true);
    }
    await _stream.copyToLocalFile(handle, destPath);
  }
}
