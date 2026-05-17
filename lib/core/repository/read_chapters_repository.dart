import 'package:hive/hive.dart';

/// A single chapter the user has finished reading.
///
/// The composite [key] (`sourceId::bookId::chapterId`) is the Hive primary
/// key for [ReadChaptersRepository] — it matches the composite PK of the
/// `read_chapters` Supabase table.
class ReadChapter {
  final String sourceId;
  final String bookId;
  final String chapterId;
  final DateTime readAt;

  ReadChapter({
    required this.sourceId,
    required this.bookId,
    required this.chapterId,
    required this.readAt,
  });

  String get key => '$sourceId::$bookId::$chapterId';

  Map<String, dynamic> toJson() => {
        'sourceId': sourceId,
        'bookId': bookId,
        'chapterId': chapterId,
        'readAt': readAt.toIso8601String(),
      };

  factory ReadChapter.fromJson(Map<String, dynamic> j) => ReadChapter(
        sourceId: j['sourceId'] as String,
        bookId: j['bookId'] as String,
        chapterId: j['chapterId'] as String,
        readAt: DateTime.parse(j['readAt'] as String),
      );
}

/// Hive-backed per-chapter "finished reading" tracker.
///
/// Mirrors [LibraryRepository]'s sync layout: every local write flips a
/// flag in the [dirtyBoxName] box (value = readAt ISO) so the sync engine
/// can drain it on debounce. Deletions (unmark) write a tombstone with the
/// deletion time so the cloud row gets removed on the next push. Pull
/// writes go through [putFromSync] / [deleteFromSync] so a fresh fetch
/// doesn't immediately schedule everything for re-push.
class ReadChaptersRepository {
  static const String boxName = 'read_chapters';
  static const String dirtyBoxName = 'read_chapters_sync_dirty';
  static const String tombstoneBoxName = 'read_chapters_tombstones';

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

  /// Set by [LibrarySyncService.start] so a user write can kick the
  /// debounced flush. Plain callback to avoid a hard dep on the sync
  /// service.
  void Function()? onLocalWrite;

  String _composeKey(String sourceId, String bookId, String chapterId) =>
      '$sourceId::$bookId::$chapterId';

  /// Marks [chapterId] as read for the given book. Idempotent — re-marking
  /// just refreshes the [ReadChapter.readAt] timestamp. Clears any pending
  /// tombstone for this key (resurrection: user re-reads after unmark).
  Future<ReadChapter> mark(
    String sourceId,
    String bookId,
    String chapterId,
  ) async {
    final entry = ReadChapter(
      sourceId: sourceId,
      bookId: bookId,
      chapterId: chapterId,
      readAt: DateTime.now(),
    );
    await _box.put(entry.key, entry.toJson());
    await _tombstones.delete(entry.key);
    await _dirty.put(entry.key, entry.readAt.toIso8601String());
    onLocalWrite?.call();
    return entry;
  }

  /// Removes the read mark for [chapterId]. Writes a tombstone first so a
  /// crash between the two ops leaves an orphan tombstone (harmless) rather
  /// than an undeletable cloud row.
  Future<void> unmark(
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

  bool isRead(String sourceId, String bookId, String chapterId) =>
      _box.containsKey(_composeKey(sourceId, bookId, chapterId));

  /// Returns the set of chapter IDs the user has finished for the given
  /// book. Useful for batch-styling chapter lists.
  Set<String> getReadChapterIds(String sourceId, String bookId) {
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

  /// Wipes every read entry. Used on sign-out so a different account
  /// doesn't inherit the previous user's read history. When [forSignOut]
  /// is true the dirty + tombstone boxes are also cleared so we don't
  /// push the old user's writes under the new user's RLS scope.
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
  // Sync-private API. Only [LibrarySyncService] should call these — they
  // intentionally skip dirty/tombstone bookkeeping so a freshly-pulled
  // cloud row isn't immediately scheduled for re-push.
  // ---------------------------------------------------------------------

  Future<void> putFromSync(ReadChapter entry) async {
    await _box.put(entry.key, entry.toJson());
    await _tombstones.delete(entry.key);
  }

  Future<void> deleteFromSync(String key) async {
    await _box.delete(key);
  }

  /// Returns `{key: readAt-iso}` for every entry the sync engine hasn't
  /// yet pushed.
  Map<String, String> dirtyKeys() =>
      {for (final k in _dirty.keys.cast<String>()) k: _dirty.get(k) ?? ''};

  /// Returns `{key: deletedAt-iso}` for every pending deletion.
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
