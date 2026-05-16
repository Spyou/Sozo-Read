import 'package:hive/hive.dart';

import '../models/book_item.dart';
import '../models/provider_info.dart';

enum LibraryStatus { reading, completed, onHold, planning }

class LibraryEntry {
  final BookItem book;
  final LibraryStatus status;
  final DateTime addedAt;
  final DateTime updatedAt;
  final int lastChapterIndex;
  final double? lastChapterProgress; // 0..1 within last chapter (manga page index / novel scroll)

  LibraryEntry({
    required this.book,
    this.status = LibraryStatus.reading,
    required this.addedAt,
    required this.updatedAt,
    this.lastChapterIndex = 0,
    this.lastChapterProgress,
  });

  String get key => '${book.sourceId}::${book.id}';

  LibraryEntry copyWith({
    LibraryStatus? status,
    int? lastChapterIndex,
    double? lastChapterProgress,
  }) =>
      LibraryEntry(
        book: book,
        status: status ?? this.status,
        addedAt: addedAt,
        updatedAt: DateTime.now(),
        lastChapterIndex: lastChapterIndex ?? this.lastChapterIndex,
        lastChapterProgress: lastChapterProgress ?? this.lastChapterProgress,
      );

  Map<String, dynamic> toJson() => {
        'book': book.toJson(),
        'status': status.name,
        'addedAt': addedAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'lastChapterIndex': lastChapterIndex,
        'lastChapterProgress': lastChapterProgress,
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
      );
}

/// Hive-backed library + reading progress store.
class LibraryRepository {
  static const String boxName = 'library';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await Hive.openBox<Map>(boxName);
    }
  }

  Box<Map> get _box => Hive.box<Map>(boxName);

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
    return entry;
  }

  Future<void> remove(String sourceId, String bookId) async {
    await _box.delete('$sourceId::$bookId');
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
    return updated;
  }

  Future<LibraryEntry?> setStatus(String sourceId, String bookId, LibraryStatus status) async {
    final cur = get(sourceId, bookId);
    if (cur == null) return null;
    final updated = cur.copyWith(status: status);
    await _box.put(updated.key, updated.toJson());
    return updated;
  }

  Stream<BoxEvent> watch() => _box.watch();
}

extension ProviderTypeX on ProviderType {
  bool get isNovel => this == ProviderType.novel || this == ProviderType.both;
  bool get isManga => this == ProviderType.manga || this == ProviderType.both;
}
