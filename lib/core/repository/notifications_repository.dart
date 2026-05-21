import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

/// A single notification entry — what was buzzed via the OS notification
/// + persisted in our local "inbox" so the user can review past events.
///
/// Stored in Hive box `notifications`, capped at [NotificationsRepository.kCap]
/// entries (oldest auto-trimmed). Not synced — device-local only.
class AppNotification {
  AppNotification({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    required this.createdAt,
    this.sourceId,
    this.bookId,
    this.coverUrl,
    this.chapterId,
    this.chapterIndex,
    this.readAt,
  });

  /// Stable ID — millis since epoch + a random suffix, generated at
  /// insertion time. Used as the Hive key.
  final String id;

  /// Short discriminator — `'new_chapter'`, `'download_done'`, etc.
  /// Reserved for future variants; today only `'new_chapter'` is used.
  final String type;

  final String title;
  final String body;
  final DateTime createdAt;

  /// Optional anchor pointing the row at a specific series. When set,
  /// tapping the row navigates to the detail screen.
  final String? sourceId;
  final String? bookId;

  /// Cover URL captured at notification time (so the row renders even
  /// if the book is later removed from the library).
  final String? coverUrl;

  /// Optional chapter anchor — currently informational only; tapping
  /// the row still goes to detail (the user picks which chapter to
  /// open from there).
  final String? chapterId;
  final int? chapterIndex;

  /// Timestamp of when the user opened the inbox AFTER this entry was
  /// added. Drives the unread badge on the Home bell.
  final DateTime? readAt;

  bool get isRead => readAt != null;

  AppNotification copyWith({DateTime? readAt}) => AppNotification(
        id: id,
        type: type,
        title: title,
        body: body,
        createdAt: createdAt,
        sourceId: sourceId,
        bookId: bookId,
        coverUrl: coverUrl,
        chapterId: chapterId,
        chapterIndex: chapterIndex,
        readAt: readAt ?? this.readAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'title': title,
        'body': body,
        'createdAt': createdAt.toIso8601String(),
        if (sourceId != null) 'sourceId': sourceId,
        if (bookId != null) 'bookId': bookId,
        if (coverUrl != null) 'coverUrl': coverUrl,
        if (chapterId != null) 'chapterId': chapterId,
        if (chapterIndex != null) 'chapterIndex': chapterIndex,
        if (readAt != null) 'readAt': readAt!.toIso8601String(),
      };

  factory AppNotification.fromJson(Map<String, dynamic> j) => AppNotification(
        id: j['id'] as String,
        type: (j['type'] as String?) ?? 'new_chapter',
        title: (j['title'] as String?) ?? '',
        body: (j['body'] as String?) ?? '',
        createdAt: DateTime.parse(j['createdAt'] as String),
        sourceId: j['sourceId'] as String?,
        bookId: j['bookId'] as String?,
        coverUrl: j['coverUrl'] as String?,
        chapterId: j['chapterId'] as String?,
        chapterIndex: (j['chapterIndex'] as num?)?.toInt(),
        readAt: j['readAt'] == null
            ? null
            : DateTime.parse(j['readAt'] as String),
      );
}

/// Local-only notifications inbox. Mirrors the OS notification stream
/// for new chapters (and future event types) so the user has a
/// persistent history they can scroll through after dismissing the
/// transient OS toast.
class NotificationsRepository {
  static const String boxName = 'notifications';

  /// Hard cap on stored entries. Oldest are trimmed when crossed.
  static const int kCap = 200;

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await Hive.openBox<Map>(boxName);
    }
  }

  Box<Map> get _box => Hive.box<Map>(boxName);

  /// Newest-first list of every notification. Used by the inbox screen.
  List<AppNotification> getAll() {
    final out = <AppNotification>[];
    for (final raw in _box.values) {
      try {
        out.add(AppNotification.fromJson(Map<String, dynamic>.from(raw)));
      } catch (e) {
        debugPrint('NotificationsRepository.getAll: corrupt entry — $e');
      }
    }
    out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return out;
  }

  /// Returns the count of entries without `readAt` set — drives the
  /// red dot/badge on the Home bell icon.
  int get unreadCount {
    var n = 0;
    for (final raw in _box.values) {
      final read = raw['readAt'];
      if (read == null) n++;
    }
    return n;
  }

  Future<AppNotification> add({
    required String type,
    required String title,
    required String body,
    String? sourceId,
    String? bookId,
    String? coverUrl,
    String? chapterId,
    int? chapterIndex,
  }) async {
    final id = '${DateTime.now().microsecondsSinceEpoch}'
        '-${_box.length}';
    final entry = AppNotification(
      id: id,
      type: type,
      title: title,
      body: body,
      createdAt: DateTime.now(),
      sourceId: sourceId,
      bookId: bookId,
      coverUrl: coverUrl,
      chapterId: chapterId,
      chapterIndex: chapterIndex,
    );
    await _box.put(entry.id, entry.toJson());
    await _trim();
    return entry;
  }

  Future<void> markRead(String id) async {
    final raw = _box.get(id);
    if (raw == null) return;
    final n = AppNotification.fromJson(Map<String, dynamic>.from(raw));
    if (n.isRead) return;
    await _box.put(id, n.copyWith(readAt: DateTime.now()).toJson());
  }

  Future<void> markAllRead() async {
    final now = DateTime.now();
    for (final key in _box.keys.toList()) {
      final raw = _box.get(key);
      if (raw == null) continue;
      final n = AppNotification.fromJson(Map<String, dynamic>.from(raw));
      if (n.isRead) continue;
      await _box.put(key, n.copyWith(readAt: now).toJson());
    }
  }

  Future<void> delete(String id) => _box.delete(id);

  Future<void> clear() => _box.clear();

  /// Keep the box bounded — drop the oldest entries past [kCap].
  Future<void> _trim() async {
    if (_box.length <= kCap) return;
    final all = getAll(); // newest-first
    final survive = all.take(kCap).map((n) => n.id).toSet();
    for (final key in _box.keys.toList().cast<String>()) {
      if (!survive.contains(key)) await _box.delete(key);
    }
  }

  Stream<BoxEvent> watch() => _box.watch();
}
