import 'package:hive/hive.dart';

/// A bookmarked page inside a chapter. "Panel" in the user's mental
/// model — but since individual panels within a manga image aren't
/// addressable without image-recognition, in practice this is a per-page
/// (chapter image) bookmark.
///
/// [pageUrl] is captured at bookmark time so the UI can render a small
/// thumbnail in the bookmarks list even if the source later restructures
/// its page URLs.
///
/// Composite [key]: `sourceId::bookId::chapterId::pageIndex`.
class PageBookmark {
  PageBookmark({
    required this.sourceId,
    required this.bookId,
    required this.chapterId,
    required this.pageIndex,
    required this.addedAt,
    this.pageUrl,
    this.note,
  });

  final String sourceId;
  final String bookId;
  final String chapterId;
  final int pageIndex;
  final DateTime addedAt;

  /// Snapshot of the page's image URL at bookmark time. May 404 later if
  /// the source rotates its CDN — that's fine, the bookmark still lets
  /// the user jump to the page index inside the chapter.
  final String? pageUrl;
  final String? note;

  String get key => '$sourceId::$bookId::$chapterId::$pageIndex';

  Map<String, dynamic> toJson() => {
        'sourceId': sourceId,
        'bookId': bookId,
        'chapterId': chapterId,
        'pageIndex': pageIndex,
        'addedAt': addedAt.toIso8601String(),
        if (pageUrl != null) 'pageUrl': pageUrl,
        if (note != null) 'note': note,
      };

  factory PageBookmark.fromJson(Map<String, dynamic> j) => PageBookmark(
        sourceId: j['sourceId'] as String,
        bookId: j['bookId'] as String,
        chapterId: j['chapterId'] as String,
        pageIndex: (j['pageIndex'] as num).toInt(),
        addedAt: DateTime.parse(j['addedAt'] as String),
        pageUrl: j['pageUrl'] as String?,
        note: j['note'] as String?,
      );
}

/// Hive-backed per-page bookmark store with sync-aware dirty + tombstone
/// boxes. Same layout as [ChapterBookmarksRepository] and the other
/// sync-enabled repos.
class PageBookmarksRepository {
  static const String boxName = 'page_bookmarks';
  static const String dirtyBoxName = 'page_bookmarks_sync_dirty';
  static const String tombstoneBoxName = 'page_bookmarks_tombstones';

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

  void Function()? onLocalWrite;

  String _composeKey(
    String sourceId,
    String bookId,
    String chapterId,
    int pageIndex,
  ) =>
      '$sourceId::$bookId::$chapterId::$pageIndex';

  Future<PageBookmark> add({
    required String sourceId,
    required String bookId,
    required String chapterId,
    required int pageIndex,
    String? pageUrl,
    String? note,
  }) async {
    final entry = PageBookmark(
      sourceId: sourceId,
      bookId: bookId,
      chapterId: chapterId,
      pageIndex: pageIndex,
      addedAt: DateTime.now(),
      pageUrl: pageUrl,
      note: note,
    );
    await _box.put(entry.key, entry.toJson());
    await _tombstones.delete(entry.key);
    await _dirty.put(entry.key, entry.addedAt.toIso8601String());
    onLocalWrite?.call();
    return entry;
  }

  Future<void> remove({
    required String sourceId,
    required String bookId,
    required String chapterId,
    required int pageIndex,
  }) async {
    final key = _composeKey(sourceId, bookId, chapterId, pageIndex);
    await _tombstones.put(key, DateTime.now().toIso8601String());
    await _box.delete(key);
    await _dirty.delete(key);
    onLocalWrite?.call();
  }

  bool isBookmarked({
    required String sourceId,
    required String bookId,
    required String chapterId,
    required int pageIndex,
  }) =>
      _box.containsKey(_composeKey(sourceId, bookId, chapterId, pageIndex));

  /// Returns the set of bookmarked page indices for a given chapter.
  /// Used by the reader's page indicator to highlight the current page
  /// when it's saved.
  Set<int> getBookmarkedPageIndices({
    required String sourceId,
    required String bookId,
    required String chapterId,
  }) {
    final prefix = '$sourceId::$bookId::$chapterId::';
    final out = <int>{};
    for (final raw in _box.keys) {
      final k = raw as String;
      if (!k.startsWith(prefix)) continue;
      final tail = k.substring(prefix.length);
      final i = int.tryParse(tail);
      if (i != null) out.add(i);
    }
    return out;
  }

  /// Full bookmark records for a book — across all chapters — sorted by
  /// addedAt descending.
  List<PageBookmark> getAllForBook(String sourceId, String bookId) {
    final prefix = '$sourceId::$bookId::';
    final out = <PageBookmark>[];
    for (final raw in _box.keys) {
      final k = raw as String;
      if (!k.startsWith(prefix)) continue;
      final stored = _box.get(k);
      if (stored == null) continue;
      try {
        out.add(PageBookmark.fromJson(Map<String, dynamic>.from(stored)));
      } catch (_) {
        // Corrupt — skip.
      }
    }
    out.sort((a, b) => b.addedAt.compareTo(a.addedAt));
    return out;
  }

  /// All bookmark records across every (sourceId, bookId), newest-first
  /// by addedAt. Used by the global Bookmarks screen.
  List<PageBookmark> getAll() {
    final out = <PageBookmark>[];
    for (final raw in _box.keys) {
      final stored = _box.get(raw);
      if (stored == null) continue;
      try {
        out.add(PageBookmark.fromJson(Map<String, dynamic>.from(stored)));
      } catch (_) {
        // Corrupt — skip.
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
  // Sync-private API.
  // ---------------------------------------------------------------------

  Future<void> putFromSync(PageBookmark entry) async {
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
