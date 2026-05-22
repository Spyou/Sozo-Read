import 'package:hive/hive.dart';

/// Membership row of a library entry in a [LibraryCategory]. One entry
/// can live in zero or more categories.
///
/// Composite [key]: `sourceId::bookId::categoryId`. This matches the
/// composite PK of the `library_entry_categories` Supabase table.
class LibraryEntryCategory {
  LibraryEntryCategory({
    required this.sourceId,
    required this.bookId,
    required this.categoryId,
    required this.addedAt,
  });

  final String sourceId;
  final String bookId;
  final String categoryId;
  final DateTime addedAt;

  String get key => '$sourceId::$bookId::$categoryId';

  Map<String, dynamic> toJson() => {
        'sourceId': sourceId,
        'bookId': bookId,
        'categoryId': categoryId,
        'addedAt': addedAt.toIso8601String(),
      };

  factory LibraryEntryCategory.fromJson(Map<String, dynamic> j) =>
      LibraryEntryCategory(
        sourceId: j['sourceId'] as String,
        bookId: j['bookId'] as String,
        categoryId: j['categoryId'] as String,
        addedAt: DateTime.parse(j['addedAt'] as String),
      );
}

/// Hive-backed join store between library entries and categories.
/// Same dirty/tombstone layout as [ChapterBookmarksRepository] so the
/// existing sync engine can drain it.
class LibraryCategoriesRepository {
  static const String boxName = 'library_entry_categories';
  static const String dirtyBoxName = 'library_entry_categories_sync_dirty';
  static const String tombstoneBoxName = 'library_entry_categories_tombstones';

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

  String _composeKey(String sourceId, String bookId, String categoryId) =>
      '$sourceId::$bookId::$categoryId';

  Future<LibraryEntryCategory> assign({
    required String sourceId,
    required String bookId,
    required String categoryId,
  }) async {
    final entry = LibraryEntryCategory(
      sourceId: sourceId,
      bookId: bookId,
      categoryId: categoryId,
      addedAt: DateTime.now(),
    );
    await _box.put(entry.key, entry.toJson());
    await _tombstones.delete(entry.key);
    await _dirty.put(entry.key, entry.addedAt.toIso8601String());
    onLocalWrite?.call();
    return entry;
  }

  Future<void> unassign({
    required String sourceId,
    required String bookId,
    required String categoryId,
  }) async {
    final key = _composeKey(sourceId, bookId, categoryId);
    await _tombstones.put(key, DateTime.now().toIso8601String());
    await _box.delete(key);
    await _dirty.delete(key);
    onLocalWrite?.call();
  }

  bool isAssigned({
    required String sourceId,
    required String bookId,
    required String categoryId,
  }) =>
      _box.containsKey(_composeKey(sourceId, bookId, categoryId));

  /// Category IDs assigned to a specific (source, book).
  Set<String> categoryIdsForBook(String sourceId, String bookId) {
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

  List<LibraryEntryCategory> getAll() {
    final out = <LibraryEntryCategory>[];
    for (final raw in _box.keys) {
      final stored = _box.get(raw);
      if (stored == null) continue;
      try {
        out.add(
          LibraryEntryCategory.fromJson(Map<String, dynamic>.from(stored)),
        );
      } catch (_) {
        // Corrupt — skip.
      }
    }
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

  Future<void> putFromSync(LibraryEntryCategory entry) async {
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
