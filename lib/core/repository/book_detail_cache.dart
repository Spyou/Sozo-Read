import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../models/book_detail.dart';

/// Lightweight Hive-backed cache of [BookDetail] objects, keyed by
/// `<sourceId>::<bookId>`.
///
/// Stored as JSON-encoded strings rather than nested `Map`s: Hive
/// re-types nested values to `Map&lt;dynamic, dynamic&gt;` on read, which
/// breaks `BookDetail.fromJson`'s inner casts (chapters list, etc.).
/// Encoding to JSON guarantees a clean tree on every read.
///
/// The detail screen uses this as a stale-while-revalidate layer: a
/// cached entry renders instantly while the network refetch runs in
/// the background. Cache hits skip the JS-engine round trip entirely,
/// which is the bulk of the detail-load latency on most sources.
class BookDetailCache {
  // v2 → JSON-string-backed (was v1: nested Map; orphaned old box is harmless,
  // it's a pure cache).
  static const String boxName = 'book_detail_cache_v2';

  /// Entries younger than this are treated as fresh enough that the
  /// background refresh can be skipped.
  static const Duration freshFor = Duration(hours: 6);

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await Hive.openBox<String>(boxName);
    }
  }

  Box<String> get _box => Hive.box<String>(boxName);

  String _key(String sourceId, String bookId) => '$sourceId::$bookId';

  /// Returns the cached [BookDetail] for this series, or `null` when
  /// the cache is empty / the stored JSON is corrupt.
  BookDetail? get(String sourceId, String bookId) {
    final raw = _box.get(_key(sourceId, bookId));
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return BookDetail.fromJson(decoded);
    } catch (e) {
      debugPrint(
        'BookDetailCache.get: corrupt entry for $sourceId/$bookId — $e',
      );
      // ignore: discarded_futures
      _box.delete(_key(sourceId, bookId));
      return null;
    }
  }

  DateTime? cachedAt(String sourceId, String bookId) {
    final raw = _box.get(_key(sourceId, bookId));
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final ts = decoded['__cachedAt'] as String?;
      if (ts == null) return null;
      return DateTime.tryParse(ts);
    } catch (_) {
      return null;
    }
  }

  bool isFresh(String sourceId, String bookId) {
    final ts = cachedAt(sourceId, bookId);
    if (ts == null) return false;
    return DateTime.now().difference(ts) < freshFor;
  }

  Future<void> put(BookDetail book) async {
    // Don't cache "empty chapters" results. The provider script
    // occasionally fails to extract the chapter list for certain
    // series (layout variants, transient errors, rate limits). Without
    // this guard the empty list would be served from cache for the
    // full freshFor window and the user would stare at "No chapters
    // available" until the entry expires. Skipping the write lets the
    // next detail open retry from the network.
    if (book.chapters.isEmpty) {
      // Also evict any pre-existing entry so a previously-good cache
      // doesn't keep serving stale data after a bad refetch. (We won't
      // proactively re-cache; the next successful load handles that.)
      await evict(book.sourceId, book.id);
      return;
    }
    final payload = book.toJson()
      ..['__cachedAt'] = DateTime.now().toIso8601String();
    await _box.put(_key(book.sourceId, book.id), jsonEncode(payload));
  }

  Future<void> evict(String sourceId, String bookId) =>
      _box.delete(_key(sourceId, bookId));

  Future<void> clear() => _box.clear();
}
