import 'dart:io';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive/hive.dart';
import 'package:saf_util/saf_util.dart';

import '../../../core/repository/downloads_repository.dart';
import '../../../core/storage/download_storage.dart';
import '../../../core/storage/download_storage_locator.dart';
import '../../../core/storage/internal_download_storage.dart';
import '../../../core/storage/saf_download_storage.dart';

enum StorageLocationPhase { idle, picking, migrating, done, error }

class StorageLocationState extends Equatable {
  final StorageLocationPhase phase;
  final String currentLabel;
  final bool hasCustomLocation;
  final int copied;
  final int total;
  final int failedEntries;
  final String? error;

  const StorageLocationState({
    required this.phase,
    required this.currentLabel,
    required this.hasCustomLocation,
    this.copied = 0,
    this.total = 0,
    this.failedEntries = 0,
    this.error,
  });

  StorageLocationState copyWith({
    StorageLocationPhase? phase,
    String? currentLabel,
    bool? hasCustomLocation,
    int? copied,
    int? total,
    int? failedEntries,
    String? error,
    bool clearError = false,
  }) =>
      StorageLocationState(
        phase: phase ?? this.phase,
        currentLabel: currentLabel ?? this.currentLabel,
        hasCustomLocation: hasCustomLocation ?? this.hasCustomLocation,
        copied: copied ?? this.copied,
        total: total ?? this.total,
        failedEntries: failedEntries ?? this.failedEntries,
        error: clearError ? null : (error ?? this.error),
      );

  @override
  List<Object?> get props => [
        phase,
        currentLabel,
        hasCustomLocation,
        copied,
        total,
        failedEntries,
        error,
      ];
}

/// Drives the storage-location picker UI on `/settings/storage`.
///
/// Lifecycle:
///   * `idle` — showing the current path. User can tap "Change location".
///   * `picking` — system SAF dialog is open. Cubit awaits the result.
///   * `migrating` — copying every previously downloaded page into the new
///     storage. `copied` / `total` drive the progress UI.
///   * `done` — migration finished (possibly with per-entry failures). User
///     dismisses the sheet and we drop back to `idle`.
///   * `error` — terminal failure that aborted the picker / migration.
///
/// Migration policy: any chapter with an in-flight `queued` or `downloading`
/// entry blocks the migration with an error message. The user has to pause
/// or finish those entries first. Per-page copy failures are non-fatal: the
/// parent entry is flipped to `failed` with a "re-download" hint and the
/// migration continues with the next entry.
class StorageLocationCubit extends Cubit<StorageLocationState> {
  StorageLocationCubit({DownloadsRepository? downloads})
      : _downloads = downloads,
        super(StorageLocationState(
          phase: StorageLocationPhase.idle,
          currentLabel: DownloadStorageLocator.currentLabel,
          hasCustomLocation: DownloadStorageLocator.hasCustomLocation,
        ));

  // Held only so we can stamp `failed` on partially-migrated entries via
  // the same code path the rest of the app uses. Optional — the cubit can
  // function with raw Hive access if needed.
  // ignore: unused_field
  final DownloadsRepository? _downloads;

  final SafUtil _saf = SafUtil();

  /// Open the system SAF picker. Returns the new tree URI string or null
  /// if the user cancelled. Persists the URI and invalidates the storage
  /// cache on success.
  Future<String?> pickLocation() async {
    if (!Platform.isAndroid) {
      emit(state.copyWith(
        phase: StorageLocationPhase.error,
        error: 'Custom storage locations are Android-only.',
      ));
      return null;
    }
    emit(state.copyWith(
      phase: StorageLocationPhase.picking,
      clearError: true,
    ));
    try {
      final picked = await _saf.pickDirectory(
        writePermission: true,
        persistablePermission: true,
      );
      if (picked == null) {
        // User cancelled — leave the previous setting untouched.
        emit(state.copyWith(
          phase: StorageLocationPhase.idle,
          currentLabel: DownloadStorageLocator.currentLabel,
          hasCustomLocation: DownloadStorageLocator.hasCustomLocation,
        ));
        return null;
      }
      await DownloadStorageLocator.setRootUri(picked.uri);
      emit(state.copyWith(
        phase: StorageLocationPhase.idle,
        currentLabel: DownloadStorageLocator.currentLabel,
        hasCustomLocation: DownloadStorageLocator.hasCustomLocation,
        clearError: true,
      ));
      return picked.uri;
    } catch (e) {
      emit(state.copyWith(
        phase: StorageLocationPhase.error,
        error: 'Failed to open folder picker: $e',
      ));
      return null;
    }
  }

  /// Revert to the internal default storage. Does not migrate files —
  /// previously downloaded chapters stay where they were (in the SAF tree)
  /// and will be unreachable from the new internal-storage backend until
  /// the user re-picks the same SAF location or re-downloads.
  Future<void> resetToInternal() async {
    await DownloadStorageLocator.setRootUri(null);
    emit(state.copyWith(
      phase: StorageLocationPhase.idle,
      currentLabel: DownloadStorageLocator.currentLabel,
      hasCustomLocation: DownloadStorageLocator.hasCustomLocation,
      clearError: true,
    ));
  }

  /// Migrate every downloaded chapter from the implicit "old" internal
  /// storage to the currently active (just-picked) storage.
  ///
  /// We assume the migration is always *from* internal *to* SAF because:
  ///   1. Going SAF → internal is rare in practice and the bytes are
  ///      already accessible to the user via the file manager.
  ///   2. The cubit cannot reliably know "what the old root was" once
  ///      the new URI is persisted, since the locator only caches the
  ///      current root.
  Future<void> migrate() async {
    if (!Platform.isAndroid) {
      emit(state.copyWith(
        phase: StorageLocationPhase.error,
        error: 'Migration is Android-only.',
      ));
      return;
    }

    // Block migration if anything is mid-download. Pausing under the
    // user's feet is rude; better to surface the gate and let them
    // resolve it.
    final box = Hive.box<Map>(DownloadsRepository.boxName);
    final entries = <DownloadEntry>[];
    for (final raw in box.values) {
      try {
        entries.add(
            DownloadEntry.fromJson(Map<String, dynamic>.from(raw)));
      } catch (_) {/* skip corrupt rows */}
    }
    final hasInFlight = entries.any((e) =>
        e.status == DownloadStatus.downloading ||
        e.status == DownloadStatus.queued);
    if (hasInFlight) {
      emit(state.copyWith(
        phase: StorageLocationPhase.error,
        error:
            'Pause or finish all in-progress downloads before migrating.',
      ));
      return;
    }

    final old = InternalDownloadStorage();
    final DownloadStorage target = DownloadStorageLocator.current;
    if (target is! SafDownloadStorage) {
      // Migration only makes sense when the *new* root is SAF — internal
      // → internal would be a no-op (same files).
      emit(state.copyWith(
        phase: StorageLocationPhase.error,
        error: 'Pick a new download location first.',
      ));
      return;
    }

    // Build the migration plan. One MigrationItem per *completed* page on
    // a *done* entry whose handle is still filesystem-resident (so we
    // don't re-copy chapters that were already migrated).
    final items = <MigrationItem>[];
    final entryByKey = <String, DownloadEntry>{};
    for (final e in entries) {
      if (e.isNovel) continue; // novel text lives inline in Hive
      if (e.status != DownloadStatus.done) continue;
      entryByKey[e.key] = e;
      for (var i = 0; i < e.pages.length; i++) {
        final p = e.pages[i];
        if (p.localPath.isEmpty) continue;
        if (!DownloadsRepository.isFilesystemHandle(p.localPath)) {
          // Already an SAF handle — likely a partial prior migration.
          continue;
        }
        final ext = _extOf(p.localPath);
        items.add(MigrationItem(
          entryKey: e.key,
          pageIndex: i,
          relativePath:
              '${e.sourceId}/${e.bookId}/${e.chapterId}/$i.$ext',
          sourceHandle: p.localPath,
        ));
      }
    }

    emit(state.copyWith(
      phase: StorageLocationPhase.migrating,
      copied: 0,
      total: items.length,
      failedEntries: 0,
      clearError: true,
    ));

    // Per-entry new handles by page index, and the set of entries that
    // failed at least one page (these get flipped to `failed` at the end).
    final newHandlesByEntry = <String, Map<int, String>>{};
    final failedEntryKeys = <String>{};

    await for (final p in target.migrateFrom(old, items, (copied, total) {
      emit(state.copyWith(copied: copied, total: total));
    })) {
      final item = p.item;
      if (item == null) continue;
      if (p.isFailure) {
        failedEntryKeys.add(item.entryKey);
        continue;
      }
      final newHandle = p.newHandle;
      if (newHandle == null) continue;
      newHandlesByEntry
          .putIfAbsent(item.entryKey, () => <int, String>{})[item.pageIndex] =
          newHandle;
    }

    // Commit handle rewrites to Hive — one entry write per chapter, not
    // per page.
    for (final mapEntry in newHandlesByEntry.entries) {
      final original = entryByKey[mapEntry.key];
      if (original == null) continue;
      final pages = List<DownloadedPage>.from(original.pages);
      mapEntry.value.forEach((idx, newHandle) {
        if (idx < pages.length) {
          pages[idx] = DownloadedPage(
            url: pages[idx].url,
            localPath: newHandle,
            headers: pages[idx].headers,
          );
        }
      });
      // If this entry had a page-level failure mid-migration, flag it.
      final hadFailure = failedEntryKeys.contains(mapEntry.key);
      final updated = original.copyWith(
        pages: pages,
        status: hadFailure ? DownloadStatus.failed : original.status,
        error: hadFailure
            ? 'Migration incomplete — re-download'
            : original.error,
        updatedAt: DateTime.now(),
      );
      await box.put(updated.key, updated.toJson());
    }

    // Best-effort: scrub the old internal-storage tree once everything
    // that was meant to move has moved. We do this on a per-entry basis
    // for *fully* migrated entries only; entries with any failure keep
    // their internal copy as a fallback.
    for (final entry in entryByKey.values) {
      if (failedEntryKeys.contains(entry.key)) continue;
      await old.deleteRecursive(
          '${entry.sourceId}/${entry.bookId}/${entry.chapterId}');
    }

    emit(state.copyWith(
      phase: StorageLocationPhase.done,
      failedEntries: failedEntryKeys.length,
    ));
  }

  void acknowledgeDone() {
    emit(state.copyWith(
      phase: StorageLocationPhase.idle,
      currentLabel: DownloadStorageLocator.currentLabel,
      hasCustomLocation: DownloadStorageLocator.hasCustomLocation,
      clearError: true,
    ));
  }

  static String _extOf(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return 'jpg';
    return path.substring(dot + 1).toLowerCase();
  }
}
