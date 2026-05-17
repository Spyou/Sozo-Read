import 'package:hive/hive.dart';

import '../models/book_item.dart';
import '../models/provider_info.dart';

enum LibraryStatus { reading, completed, onHold, planning }

// LibraryEntry schema v2: adds `lastSeenChapterCount` so the background
// chapter-check service can compare the latest count returned by the
// source against what we observed last run, and fire a notification on
// growth. Older payloads (no field present) default to 0 — the first
// background run after upgrade will silently seed the counter without
// alerting (we treat an unknown baseline as "already up to date").
class LibraryEntry {
  final BookItem book;
  final LibraryStatus status;
  final DateTime addedAt;
  final DateTime updatedAt;
  final int lastChapterIndex;
  final double? lastChapterProgress; // 0..1 within last chapter (manga page index / novel scroll)
  final int lastSeenChapterCount;

  LibraryEntry({
    required this.book,
    this.status = LibraryStatus.reading,
    required this.addedAt,
    required this.updatedAt,
    this.lastChapterIndex = 0,
    this.lastChapterProgress,
    this.lastSeenChapterCount = 0,
  });

  String get key => '${book.sourceId}::${book.id}';

  LibraryEntry copyWith({
    LibraryStatus? status,
    int? lastChapterIndex,
    double? lastChapterProgress,
    int? lastSeenChapterCount,
  }) =>
      LibraryEntry(
        book: book,
        status: status ?? this.status,
        addedAt: addedAt,
        updatedAt: DateTime.now(),
        lastChapterIndex: lastChapterIndex ?? this.lastChapterIndex,
        lastChapterProgress: lastChapterProgress ?? this.lastChapterProgress,
        lastSeenChapterCount:
            lastSeenChapterCount ?? this.lastSeenChapterCount,
      );

  Map<String, dynamic> toJson() => {
        'book': book.toJson(),
        'status': status.name,
        'addedAt': addedAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'lastChapterIndex': lastChapterIndex,
        'lastChapterProgress': lastChapterProgress,
        'lastSeenChapterCount': lastSeenChapterCount,
      };

  factory LibraryEntry.fromJson(Map<String, dynamic> j) => LibraryEntry(
        book: BookItem.fromJson(Map<String, dynamic>.from(j['book'] as Map)),
        status: LibraryStatus.values.firstWhere(
          (s) => s.name == j['status'],
          orElse: () => LibraryStatus.reading,
        ),
        addedAt: DateTime.parse(j['addedAt'] as String),
        updatedAt: DateTime.parse(j['updatedAt'] as String),
        lastChapterIndex: (j['lastChapterIndex'] as int?) ?? 0,
        lastChapterProgress: (j['lastChapterProgress'] as num?)?.toDouble(),
        lastSeenChapterCount: (j['lastSeenChapterCount'] as int?) ?? 0,
      );
}

/// Hive-backed library + reading progress store.
///
/// Sync tracking: every local write marks the entry's key in a separate
/// `library_sync_dirty` box (value = updatedAt ISO string). Deletions
/// stamp a `library_tombstones` row. The [LibrarySyncService] reads these
/// to know what to push, and writes pulled rows through [putFromSync]
/// which intentionally bypasses dirty/tombstone tracking so a pull
/// doesn't immediately re-push everything it just fetched.
class LibraryRepository {
  static const String boxName = 'library';
  static const String dirtyBoxName = 'library_sync_dirty';
  static const String tombstoneBoxName = 'library_tombstones';

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

  /// Registered by [LibrarySyncService] post-construction so the repo can
  /// poke it on each user-initiated write (kicks the debounce timer).
  /// Kept as a plain callback to avoid a hard dependency on the sync
  /// service — the repo stays usable in tests / offline-only mode.
  void Function()? onLocalWrite;

  List<LibraryEntry> getAll() {
    return _box.values
        .map((m) => LibraryEntry.fromJson(Map<String, dynamic>.from(m)))
        .toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  List<LibraryEntry> byStatus(LibraryStatus status) =>
      getAll().where((e) => e.status == status).toList();

  LibraryEntry? get(String sourceId, String bookId) {
    final raw = _box.get('$sourceId::$bookId');
    if (raw == null) return null;
    return LibraryEntry.fromJson(Map<String, dynamic>.from(raw));
  }

  bool isSaved(String sourceId, String bookId) =>
      _box.containsKey('$sourceId::$bookId');

  Future<LibraryEntry> add(BookItem book, {LibraryStatus status = LibraryStatus.reading}) async {
    final now = DateTime.now();
    final entry = LibraryEntry(
      book: book,
      status: status,
      addedAt: now,
      updatedAt: now,
    );
    await _box.put(entry.key, entry.toJson());
    // Clear any stale tombstone (resurrection: user re-adds after delete).
    await _tombstones.delete(entry.key);
    await _dirty.put(entry.key, entry.updatedAt.toIso8601String());
    onLocalWrite?.call();
    return entry;
  }

  Future<void> remove(String sourceId, String bookId) async {
    final key = '$sourceId::$bookId';
    // Write tombstone BEFORE deleting the entry — if we crash between the
    // two ops we'd rather have an orphan tombstone (sync deletes it
    // harmlessly on next push) than an undeletable cloud row.
    await _tombstones.put(key, DateTime.now().toIso8601String());
    await _box.delete(key);
    // The dirty marker would have referenced a now-deleted entry; drop it.
    await _dirty.delete(key);
    onLocalWrite?.call();
  }

  /// Wipes every saved entry. Used on sign-out so a different account
  /// doesn't inherit the previous user's library on the next sign-in.
  ///
  /// When [forSignOut] is true (the only caller right now), the dirty +
  /// tombstone boxes are also cleared so we don't push the previous
  /// user's deletes under the new user's RLS scope.
  Future<int> clear({bool forSignOut = false}) async {
    final n = _box.length;
    await _box.clear();
    if (forSignOut) {
      await _dirty.clear();
      await _tombstones.clear();
    }
    return n;
  }

  Future<LibraryEntry?> updateProgress({
    required String sourceId,
    required String bookId,
    required int chapterIndex,
    double? chapterProgress,
  }) async {
    final cur = get(sourceId, bookId);
    if (cur == null) return null;
    final updated = cur.copyWith(
      lastChapterIndex: chapterIndex,
      lastChapterProgress: chapterProgress,
    );
    await _box.put(updated.key, updated.toJson());
    await _dirty.put(updated.key, updated.updatedAt.toIso8601String());
    onLocalWrite?.call();
    return updated;
  }

  /// Updates the watermark used by [ChapterCheckService] to detect new
  /// chapters between background polls. Intentionally bypasses the
  /// dirty/sync queue — this counter is a per-device notification cache,
  /// not user-edited library state.
  Future<LibraryEntry?> updateLastSeenChapterCount({
    required String sourceId,
    required String bookId,
    required int count,
  }) async {
    final cur = get(sourceId, bookId);
    if (cur == null) return null;
    final updated = LibraryEntry(
      book: cur.book,
      status: cur.status,
      addedAt: cur.addedAt,
      // Preserve updatedAt so we don't churn the sync engine for a value
      // it doesn't care about.
      updatedAt: cur.updatedAt,
      lastChapterIndex: cur.lastChapterIndex,
      lastChapterProgress: cur.lastChapterProgress,
      lastSeenChapterCount: count,
    );
    await _box.put(updated.key, updated.toJson());
    return updated;
  }

  Future<LibraryEntry?> setStatus(String sourceId, String bookId, LibraryStatus status) async {
    final cur = get(sourceId, bookId);
    if (cur == null) return null;
    final updated = cur.copyWith(status: status);
    await _box.put(updated.key, updated.toJson());
    await _dirty.put(updated.key, updated.updatedAt.toIso8601String());
    onLocalWrite?.call();
    return updated;
  }

  // ---------------------------------------------------------------------
  // Sync-private API. Only [LibrarySyncService] should call these — they
  // intentionally skip dirty/tombstone bookkeeping so a freshly-pulled
  // cloud row isn't immediately scheduled for re-push.
  // ---------------------------------------------------------------------

  /// Writes [entry] without marking it dirty. Used when applying a cloud
  /// row that won the last-write-wins merge.
  Future<void> putFromSync(LibraryEntry entry) async {
    await _box.put(entry.key, entry.toJson());
    // The remote row supersedes any pending tombstone for this key.
    await _tombstones.delete(entry.key);
  }

  /// Deletes [key] without writing a tombstone. Used when the cloud has
  /// already deleted a row (or we're acknowledging our own pushed
  /// tombstone).
  Future<void> deleteFromSync(String key) async {
    await _box.delete(key);
  }

  /// Returns `{key: updatedAt-iso}` for every entry the sync engine
  /// hasn't yet pushed.
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

extension ProviderTypeX on ProviderType {
  bool get isNovel => this == ProviderType.novel || this == ProviderType.both;
  bool get isManga => this == ProviderType.manga || this == ProviderType.both;
}
