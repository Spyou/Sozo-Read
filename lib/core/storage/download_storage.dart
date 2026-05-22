import 'dart:typed_data';

/// Single page transferred during a storage migration. `relativePath` is the
/// `sourceId/bookId/chapterId/N.ext` shape used everywhere else in this
/// layer; `sourceHandle` is the opaque handle on the *old* storage that
/// holds the bytes we want to copy. The cubit-side caller produces these
/// from the downloads Hive box and feeds them to [DownloadStorage.migrateFrom].
class MigrationItem {
  final String entryKey; // DownloadEntry.key
  final int pageIndex;
  final String relativePath;
  final String sourceHandle;

  const MigrationItem({
    required this.entryKey,
    required this.pageIndex,
    required this.relativePath,
    required this.sourceHandle,
  });
}

/// Per-page result emitted from [DownloadStorage.migrateFrom].
class MigrationProgress {
  final int copied;
  final int total;
  final MigrationItem? item;

  /// New handle that should overwrite the original `DownloadedPage.localPath`
  /// after a successful copy. Null on failed copies.
  final String? newHandle;

  /// Non-null when this specific page failed. The migration continues; the
  /// caller is expected to mark the parent entry as `failed` with a
  /// re-download hint.
  final String? error;

  const MigrationProgress({
    required this.copied,
    required this.total,
    this.item,
    this.newHandle,
    this.error,
  });

  bool get isFailure => error != null;
}

/// Backend-agnostic interface for the downloaded-chapter store. The active
/// implementation is picked at runtime by [DownloadStorageLocator] — either
/// the legacy [InternalDownloadStorage] (writes under
/// `getApplicationDocumentsDirectory()/downloads`) or the new
/// [SafDownloadStorage] (writes under a user-picked Android SAF tree URI).
///
/// All write/read APIs use an opaque "handle" string. Callers MUST NOT
/// assume the handle is a filesystem path: for the internal backend it is
/// (an absolute `File.path`), but for the SAF backend it is a
/// `content://...` document URI. The two are distinguishable by the leading
/// character (`/` = filesystem path, anything else = SAF URI), which is what
/// the reader call sites use to dispatch to `File()` vs. SAF byte reads.
///
/// [relativePath] follows the shape `sourceId/bookId/chapterId/<index>.<ext>`.
abstract class DownloadStorage {
  /// Writes [bytes] to the resolved location for [relativePath]. Returns the
  /// opaque handle that should be persisted in `DownloadedPage.localPath`.
  Future<String> writeBytes(String relativePath, Uint8List bytes);

  /// True if a previously written handle still resolves to a stored object.
  Future<bool> exists(String handle);

  /// Length in bytes of a previously written handle, or 0 if unknown.
  Future<int> length(String handle);

  /// Recursively deletes everything under [relativeDir] (a path of the same
  /// shape as [writeBytes] but pointing at a directory, e.g.
  /// `sourceId/bookId/chapterId`). Best-effort: missing dirs are not
  /// errors.
  Future<void> deleteRecursive(String relativeDir);

  /// Reads the bytes for a previously written handle.
  Future<Uint8List> readBytes(String handle);

  /// Pump every [MigrationItem] in [items] from [old] storage into this
  /// storage. Emits a [MigrationProgress] event after each item (success
  /// or failure). `progress(copied, total)` is also invoked synchronously
  /// after every successful copy so the UI can show a count without
  /// subscribing to the stream.
  ///
  /// Best-effort: a single failed page does not abort the whole migration.
  /// Callers consume the stream and mark the parent `DownloadEntry` as
  /// `failed` for entries that emitted any error events.
  Stream<MigrationProgress> migrateFrom(
    DownloadStorage old,
    List<MigrationItem> items,
    void Function(int copied, int total) progress,
  ) async* {
    var copied = 0;
    final total = items.length;
    for (final item in items) {
      try {
        final bytes = await old.readBytes(item.sourceHandle);
        final newHandle = await writeBytes(item.relativePath, bytes);
        copied++;
        progress(copied, total);
        yield MigrationProgress(
          copied: copied,
          total: total,
          item: item,
          newHandle: newHandle,
        );
      } catch (e) {
        yield MigrationProgress(
          copied: copied,
          total: total,
          item: item,
          error: e.toString(),
        );
      }
    }
  }
}
