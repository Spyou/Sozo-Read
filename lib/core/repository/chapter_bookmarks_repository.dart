import 'package:hive/hive.dart';

/// A bookmarked chapter — the user flagged this chapter as worth coming
/// back to. Distinct from [ReadChapter] (finished reading) — a chapter
/// can be both, or just one, or neither.
///
/// The composite [key] (`sourceId::bookId::chapterId`) is the Hive
/// primary key and also matches the composite PK of the
/// `chapter_bookmarks` Supabase table.
class ChapterBookmark {
  ChapterBookmark({
    required this.sourceId,
    required this.bookId,
    required this.chapterId,
    required this.addedAt,
    this.note,
  });

  final String sourceId;
  final String bookId;
  final String chapterId;
  final DateTime addedAt;

  /// Optional user-written note attached to the bookmark.
  final String? note;

  String get key => '$sourceId::$bookId::$chapterId';

  Map<String, dynamic> toJson() => {
        'sourceId': sourceId,
        'bookId': bookId,
        'chapterId': chapterId,
        'addedAt': addedAt.toIso8601String(),
        if (note != null) 'note': note,
      };

  factory ChapterBookmark.fromJson(Map<String, dynamic> j) => ChapterBookmark(
        sourceId: j['sourceId'] as String,
        bookId: j['bookId'] as String,
        chapterId: j['chapterId'] as String,
        addedAt: DateTime.parse(j['addedAt'] as String),
        note: j['note'] as String?,
      );
}

/// Hive-backed per-chapter bookmark store with the same sync-aware
/// layout as [LibraryRepository] / [ReadChaptersRepository]: a primary
/// box plus a dirty queue and a tombstone box so [LibrarySyncService]
/// can drain writes and deletions to Supabase on debounce.
class ChapterBookmarksRepository {
  static const String boxName = 'chapter_bookmarks';
  static const String dirtyBoxName = 'chapter_bookmarks_sync_dirty';
  static const String tombstoneBoxName = 'chapter_bookmarks_tombstones';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await Hive.openBox<Map>(boxName);
    }
    if (!Hive.isBoxOpen(dirtyBoxName)) {
      await Hive.openBox<String>(dirtyBoxName);
    }
    if (!Hive.isBoxOpen(tombstoneBoxName)) {
      await Hive.openBox<String>(tombstoneBoxName);
    }
  }

  Box<Map> get _box => Hive.box<Map>(boxName);
  Box<String> get _dirty => Hive.box<String>(dirtyBoxName);
  Box<String> get _tombstones => Hive.box<String>(tombstoneBoxName);

  /// Set by [LibrarySyncService.start] so a user write kicks the debounced
  /// flush. Plain callback to avoid a hard dep on the sync service.
  void Function()? onLocalWrite;

  String _composeKey(String sourceId, String bookId, String chapterId) =>
      '$sourceId::$bookId::$chapterId';

  /// Adds a bookmark for [chapterId]. Idempotent — re-bookmarking just
  /// refreshes the timestamp. Clears any pending tombstone (resurrection
  /// after a recent unmark).
  Future<ChapterBookmark> add(
    String sourceId,
    String bookId,
    String chapterId, {
    String? note,
  }) async {
    final entry = ChapterBookmark(
      sourceId: sourceId,
      bookId: bookId,
      chapterId: chapterId,
      addedAt: DateTime.now(),
      note: note,
    );
    await _box.put(entry.key, entry.toJson());
    await _tombstones.delete(entry.key);
    await _dirty.put(entry.key, entry.addedAt.toIso8601String());
    onLocalWrite?.call();
    return entry;
  }

  /// Removes the bookmark for [chapterId]. Writes a tombstone first so a
  /// crash between ops leaves an orphan tombstone (harmless) rather than
  /// an undeletable cloud row.
  Future<void> remove(
    String sourceId,
    String bookId,
    String chapterId,
  ) async {
    final key = _composeKey(sourceId, bookId, chapterId);
    await _tombstones.put(key, DateTime.now().toIso8601String());
    await _box.delete(key);
    await _dirty.delete(key);
    onLocalWrite?.call();
  }

  bool isBookmarked(String sourceId, String bookId, String chapterId) =>
      _box.containsKey(_composeKey(sourceId, bookId, chapterId));

  /// All bookmarked chapter IDs for a given book. Useful for styling the
  /// chapter list (showing the bookmark icon next to each).
  Set<String> getBookmarkedChapterIds(String sourceId, String bookId) {
    final prefix = '$sourceId::$bookId::';
    final result = <String>{};
    for (final raw in _box.keys) {
      final k = raw as String;
      if (k.startsWith(prefix)) {
        result.add(k.substring(prefix.length));
      }
    }
    return result;
  }

  /// Full bookmark records for a book, newest-first by addedAt.
  List<ChapterBookmark> getAllForBook(String sourceId, String bookId) {
    final prefix = '$sourceId::$bookId::';
    final out = <ChapterBookmark>[];
    for (final raw in _box.keys) {
      final k = raw as String;
      if (!k.startsWith(prefix)) continue;
      final stored = _box.get(k);
      if (stored == null) continue;
      try {
        out.add(ChapterBookmark.fromJson(Map<String, dynamic>.from(stored)));
      } catch (_) {
        // Corrupt row — skip rather than crash the UI.
      }
    }
    out.sort((a, b) => b.addedAt.compareTo(a.addedAt));
    return out;
  }

  /// All bookmark records across every (sourceId, bookId), newest-first
  /// by addedAt. Used by the global Bookmarks screen.
  List<ChapterBookmark> getAll() {
    final out = <ChapterBookmark>[];
    for (final raw in _box.keys) {
      final stored = _box.get(raw);
      if (stored == null) continue;
      try {
        out.add(ChapterBookmark.fromJson(Map<String, dynamic>.from(stored)));
      } catch (_) {
        // Corrupt row — skip.
      }
    }
    out.sort((a, b) => b.addedAt.compareTo(a.addedAt));
    return out;
  }

  Future<int> clear({bool forSignOut = false}) async {
    final n = _box.length;
    await _box.clear();
    if (forSignOut) {
      await _dirty.clear();
      await _tombstones.clear();
    }
    return n;
  }

  // ---------------------------------------------------------------------
  // Sync-private API. Only [LibrarySyncService] should call these.
  // ---------------------------------------------------------------------

  Future<void> putFromSync(ChapterBookmark entry) async {
    await _box.put(entry.key, entry.toJson());
    await _tombstones.delete(entry.key);
  }

  Future<void> deleteFromSync(String key) async {
    await _box.delete(key);
  }

  Map<String, String> dirtyKeys() =>
      {for (final k in _dirty.keys.cast<String>()) k: _dirty.get(k) ?? ''};

  Map<String, String> tombstones() => {
        for (final k in _tombstones.keys.cast<String>())
          k: _tombstones.get(k) ?? '',
      };

  Future<void> ackDirty(Iterable<String> keys) async {
    for (final k in keys) {
      await _dirty.delete(k);
    }
  }

  Future<void> ackTombstones(Iterable<String> keys) async {
    for (final k in keys) {
      await _tombstones.delete(k);
    }
  }

  Stream<BoxEvent> watch() => _box.watch();
}
