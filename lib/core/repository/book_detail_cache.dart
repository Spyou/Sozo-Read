import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../models/book_detail.dart';

/// Lightweight Hive-backed cache of [BookDetail] objects, keyed by
/// `<sourceId>::<bookId>`.
///
/// The detail screen uses this as a stale-while-revalidate layer: a
/// cached entry renders instantly while the network refetch runs in
/// the background. Cache hits skip the JS-engine round trip entirely,
/// which is the bulk of the detail-load latency on most sources.
class BookDetailCache {
  static const String boxName = 'book_detail_cache';

  /// Entries older than this are still served (so the user sees
  /// something), but the bloc treats them as a hint to refetch.
  /// Anything younger than this is treated as fresh enough that the
  /// background refresh can be skipped on flaky networks.
  static const Duration freshFor = Duration(hours: 6);

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await Hive.openBox<Map>(boxName);
    }
  }

  Box<Map> get _box => Hive.box<Map>(boxName);

  String _key(String sourceId, String bookId) => '$sourceId::$bookId';

  /// Returns the cached [BookDetail] for this series, or `null` when
  /// the cache is empty or the stored JSON is corrupt.
  BookDetail? get(String sourceId, String bookId) {
    final raw = _box.get(_key(sourceId, bookId));
    if (raw == null) return null;
    try {
      return BookDetail.fromJson(Map<String, dynamic>.from(raw));
    } catch (e) {
      debugPrint('BookDetailCache.get: corrupt entry for $sourceId/$bookId — $e');
      // ignore: discarded_futures
      _box.delete(_key(sourceId, bookId));
      return null;
    }
  }

  /// Returns the timestamp the cache entry was written, or `null` if
  /// absent. Used by the bloc to decide whether the entry is fresh
  /// enough to skip the background refresh.
  DateTime? cachedAt(String sourceId, String bookId) {
    final raw = _box.get(_key(sourceId, bookId));
    if (raw == null) return null;
    final ts = raw['__cachedAt'] as String?;
    if (ts == null) return null;
    return DateTime.tryParse(ts);
  }

  /// Returns true when the cache entry exists and was written within
  /// the [freshFor] window.
  bool isFresh(String sourceId, String bookId) {
    final ts = cachedAt(sourceId, bookId);
    if (ts == null) return false;
    return DateTime.now().difference(ts) < freshFor;
  }

  Future<void> put(BookDetail book) async {
    final payload = book.toJson()
      ..['__cachedAt'] = DateTime.now().toIso8601String();
    await _box.put(_key(book.sourceId, book.id), payload);
  }

  Future<void> evict(String sourceId, String bookId) =>
      _box.delete(_key(sourceId, bookId));

  Future<void> clear() => _box.clear();
}
