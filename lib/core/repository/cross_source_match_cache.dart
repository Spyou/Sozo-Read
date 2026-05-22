import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../services/cross_source_matcher.dart';

/// Hive-backed cache of cross-source title matches discovered when a
/// source fails. Keyed by the FAILING `(sourceId, bookId)` so the next
/// open of the same dead entry skips the fanout entirely.
///
/// Values are JSON-encoded maps; Hive re-types nested maps to
/// `Map<dynamic, dynamic>` on read so we stringify on write for a clean
/// round-trip.
class CrossSourceMatchCache {
  static const String boxName = 'cross_source_matches';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await Hive.openBox<String>(boxName);
    }
  }

  Box<String> get _box => Hive.box<String>(boxName);

  String _key(String sourceId, String bookId) => '$sourceId::$bookId';

  /// Returns the cached fallback descriptor for the given failing entry,
  /// or null when nothing is cached / the stored JSON is corrupt.
  Map<String, dynamic>? get(String sourceId, String bookId) {
    final raw = _box.get(_key(sourceId, bookId));
    if (raw == null || raw.isEmpty) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (e) {
      debugPrint(
        'CrossSourceMatchCache.get: corrupt entry for $sourceId/$bookId — $e',
      );
      // ignore: discarded_futures
      _box.delete(_key(sourceId, bookId));
      return null;
    }
  }

  Future<void> put(
    String sourceId,
    String bookId,
    MatchCandidate candidate,
  ) async {
    final payload = <String, dynamic>{
      'srcB': candidate.sourceId,
      'repoUrlB': candidate.repoUrl,
      'bookIdB': candidate.book.id,
      'titleB': candidate.book.title,
      'url': candidate.book.url,
      'score': candidate.score,
      'ts': DateTime.now().toIso8601String(),
    };
    await _box.put(_key(sourceId, bookId), jsonEncode(payload));
  }

  Future<void> clear() => _box.clear();
}
