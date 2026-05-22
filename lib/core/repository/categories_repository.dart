import 'package:hive/hive.dart';

/// A user-defined library category (e.g. "Currently Reading",
/// "Favorites"). The UI for managing these isn't wired up yet — this
/// store exists so the sync engine has a stable local home for the
/// rows once the feature lands.
///
/// [id] is a client-generated stable string (UUID / ULID style) so two
/// devices can independently create rows without colliding on
/// auto-incrementing keys. [sortOrder] is the display rank — lower
/// renders first. [updatedAt] drives the last-write-wins merge.
class LibraryCategory {
  LibraryCategory({
    required this.id,
    required this.name,
    required this.sortOrder,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final int sortOrder;
  final DateTime updatedAt;

  String get key => id;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'sortOrder': sortOrder,
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory LibraryCategory.fromJson(Map<String, dynamic> j) => LibraryCategory(
        id: j['id'] as String,
        name: j['name'] as String,
        sortOrder: (j['sortOrder'] as num?)?.toInt() ?? 0,
        updatedAt: DateTime.parse(j['updatedAt'] as String),
      );

  LibraryCategory copyWith({
    String? name,
    int? sortOrder,
    DateTime? updatedAt,
  }) =>
      LibraryCategory(
        id: id,
        name: name ?? this.name,
        sortOrder: sortOrder ?? this.sortOrder,
        updatedAt: updatedAt ?? DateTime.now(),
      );
}

/// Hive-backed category store, matching the sync layout used by the
/// other library repos: a primary box + a dirty queue + a tombstone box
/// so [LibrarySyncService] can drain writes/deletions to Supabase on
/// debounce. No UI consumes this yet — see the Categories follow-up
/// task — but writing the local store now keeps the dirty/tombstone
/// invariants centralised in one PR.
class CategoriesRepository {
  static const String boxName = 'categories';
  static const String dirtyBoxName = 'categories_sync_dirty';
  static const String tombstoneBoxName = 'categories_tombstones';

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
  /// flush.
  void Function()? onLocalWrite;

  /// All categories, sorted by sortOrder ascending then name.
  List<LibraryCategory> getAll() {
    final out = <LibraryCategory>[];
    for (final raw in _box.keys) {
      final stored = _box.get(raw);
      if (stored == null) continue;
      try {
        out.add(LibraryCategory.fromJson(Map<String, dynamic>.from(stored)));
      } catch (_) {
        // Corrupt row — skip rather than crash the UI.
      }
    }
    out.sort((a, b) {
      final c = a.sortOrder.compareTo(b.sortOrder);
      if (c != 0) return c;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return out;
  }

  LibraryCategory? get(String id) {
    final raw = _box.get(id);
    if (raw == null) return null;
    return LibraryCategory.fromJson(Map<String, dynamic>.from(raw));
  }

  Future<LibraryCategory> upsert(LibraryCategory cat) async {
    await _box.put(cat.key, cat.toJson());
    await _tombstones.delete(cat.key);
    await _dirty.put(cat.key, cat.updatedAt.toIso8601String());
    onLocalWrite?.call();
    return cat;
  }

  Future<void> remove(String id) async {
    // Tombstone before delete so a crash mid-op leaves an orphan
    // tombstone (harmless) rather than an undeletable cloud row.
    await _tombstones.put(id, DateTime.now().toIso8601String());
    await _box.delete(id);
    await _dirty.delete(id);
    onLocalWrite?.call();
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

  Future<void> putFromSync(LibraryCategory entry) async {
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
