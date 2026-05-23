import 'package:hive/hive.dart';

/// Hive-backed cache for AI-generated chapter summaries. Keyed by
/// `sourceId::bookId::chapterId` so the same chapter across two
/// providers gets distinct entries (lots of MTL novels republish
/// chapters with different IDs per host).
///
/// Cache values are immutable maps `{ summary, model, createdAtMs }`
/// — we record which model generated the text so the UI can show a
/// "regenerate with newer model" hint later if we want to.
class SummariesRepository {
  SummariesRepository._(this._box);

  static const String boxName = 'ai_summaries';

  final Box _box;

  static Future<SummariesRepository> init() async {
    final box = await Hive.openBox(boxName);
    return SummariesRepository._(box);
  }

  String _key(String sourceId, String bookId, String chapterId) =>
      '$sourceId::$bookId::$chapterId';

  /// Returns the cached summary for the given chapter, or null if
  /// not yet generated. Doesn't validate the model — callers who
  /// care about that should branch on [cachedAt].
  String? get(String sourceId, String bookId, String chapterId) {
    final raw = _box.get(_key(sourceId, bookId, chapterId));
    if (raw is Map) {
      final s = raw['summary'];
      return s is String ? s : null;
    }
    return null;
  }

  /// Model id that produced the cached summary, or null if not
  /// cached. Useful for the "regenerate with the new default model"
  /// flow if we ever ship one.
  String? modelFor(String sourceId, String bookId, String chapterId) {
    final raw = _box.get(_key(sourceId, bookId, chapterId));
    if (raw is Map) {
      final m = raw['model'];
      return m is String ? m : null;
    }
    return null;
  }

  /// When the cached summary was created. Used by future "show stale
  /// > N days" UI; not consumed by the current sheet.
  DateTime? cachedAt(String sourceId, String bookId, String chapterId) {
    final raw = _box.get(_key(sourceId, bookId, chapterId));
    if (raw is Map) {
      final ms = raw['createdAtMs'];
      if (ms is int) return DateTime.fromMillisecondsSinceEpoch(ms);
    }
    return null;
  }

  Future<void> put({
    required String sourceId,
    required String bookId,
    required String chapterId,
    required String summary,
    required String modelApiId,
  }) async {
    await _box.put(_key(sourceId, bookId, chapterId), {
      'summary': summary,
      'model': modelApiId,
      'createdAtMs': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<void> remove(String sourceId, String bookId, String chapterId) =>
      _box.delete(_key(sourceId, bookId, chapterId));

  /// Wipe everything — exposed via Settings > AI as a "Clear summary
  /// cache" affordance for users who don't want generated text stored
  /// on device anymore.
  Future<void> clear() => _box.clear();
}
