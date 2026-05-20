import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

/// Local cache of "first image URL per chapter" used by the chapter list
/// and bookmarks UI to render a small thumbnail next to each row.
///
/// Populated organically as the user reads — when the manga reader's
/// `_fetchPages` loads a chapter's pages, we stash the first page URL
/// here. Bookmarking a chapter also proactively fetches + writes here
/// so every chapter bookmark is guaranteed to have a thumbnail.
///
/// Keyed by `<sourceId>::<bookId>::<chapterId>`. Pure local cache —
/// not synced to Supabase (the same chapter looked at from two devices
/// will populate independently, which is fine and avoids extra traffic).
class ChapterThumbnailsRepository {
  static const String boxName = 'chapter_thumbnails';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await Hive.openBox<String>(boxName);
    }
  }

  Box<String> get _box => Hive.box<String>(boxName);

  String _key(String sourceId, String bookId, String chapterId) =>
      '$sourceId::$bookId::$chapterId';

  /// Returns the cached first-page URL for [chapterId] or `null` if the
  /// user has never opened that chapter (and never bookmarked it).
  String? get(String sourceId, String bookId, String chapterId) {
    final v = _box.get(_key(sourceId, bookId, chapterId));
    if (v == null || v.isEmpty) return null;
    return v;
  }

  /// Stores the first-page URL for [chapterId]. Idempotent — re-writing
  /// the same URL is a no-op for the UI.
  Future<void> put({
    required String sourceId,
    required String bookId,
    required String chapterId,
    required String pageUrl,
  }) async {
    if (pageUrl.isEmpty) return;
    // Skip local file URLs (offline-downloaded chapters) — those paths
    // are tied to the device's filesystem and won't render on another
    // device. The downloaded chapter still has its own thumbnail via
    // the downloads repo at render time if needed.
    if (pageUrl.startsWith('file://') || pageUrl.startsWith('/')) return;
    await _box.put(_key(sourceId, bookId, chapterId), pageUrl);
  }

  /// Bulk-loads thumbnails for an entire book — returns `{chapterId: url}`
  /// so the chapter list can render every row without N box lookups.
  Map<String, String> getAllForBook(String sourceId, String bookId) {
    final prefix = '$sourceId::$bookId::';
    final out = <String, String>{};
    for (final raw in _box.keys) {
      final k = raw as String;
      if (!k.startsWith(prefix)) continue;
      final v = _box.get(k);
      if (v != null && v.isNotEmpty) {
        out[k.substring(prefix.length)] = v;
      }
    }
    return out;
  }

  /// Pure local cache — wiped on sign-out so a different account starts
  /// with a clean slate (matches the behaviour of read_chapters etc.).
  Future<int> clear() async {
    final n = _box.length;
    await _box.clear();
    return n;
  }

  Stream<BoxEvent> watch() => _box.watch();

  /// Called from the reader when pages are loaded. Best-effort — errors
  /// are swallowed via debugPrint so a write failure never breaks the
  /// reader flow.
  Future<void> rememberFirstPage({
    required String sourceId,
    required String bookId,
    required String chapterId,
    required String firstPageUrl,
  }) async {
    try {
      await put(
        sourceId: sourceId,
        bookId: bookId,
        chapterId: chapterId,
        pageUrl: firstPageUrl,
      );
    } catch (e) {
      debugPrint('ChapterThumbnailsRepository.rememberFirstPage: $e');
    }
  }
}
