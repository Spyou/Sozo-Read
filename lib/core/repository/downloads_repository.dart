import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';

import '../models/book_detail.dart';
import '../models/chapter.dart';
import '../models/page_content.dart';

enum DownloadStatus { queued, downloading, done, failed }

class DownloadedPage {
  final String url;
  final String localPath;
  final Map<String, String>? headers;

  const DownloadedPage({
    required this.url,
    required this.localPath,
    this.headers,
  });

  Map<String, dynamic> toJson() => {
        'url': url,
        'localPath': localPath,
        if (headers != null) 'headers': headers,
      };

  factory DownloadedPage.fromJson(Map<String, dynamic> j) => DownloadedPage(
        url: j['url'] as String,
        localPath: j['localPath'] as String,
        headers: (j['headers'] as Map?)?.cast<String, String>(),
      );
}

class DownloadEntry {
  final String sourceId;
  final String bookId;
  final String bookTitle;
  final String chapterId;
  final String chapterTitle;
  final String chapterUrl;
  final String? chapterDate;
  final DownloadStatus status;
  final int total;
  final int completed;
  final List<DownloadedPage> pages;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? error;
  // Novel-only: the chapter's plain text + the URL the next chapter
  // resolves to. For manga downloads both are null and `pages` is used
  // instead.
  final String? text;
  final String? nextChapterUrl;

  const DownloadEntry({
    required this.sourceId,
    required this.bookId,
    required this.bookTitle,
    required this.chapterId,
    required this.chapterTitle,
    required this.chapterUrl,
    this.chapterDate,
    required this.status,
    required this.total,
    required this.completed,
    required this.pages,
    required this.createdAt,
    required this.updatedAt,
    this.error,
    this.text,
    this.nextChapterUrl,
  });

  bool get isNovel => text != null;

  String get key => '$sourceId::$bookId::$chapterId';

  DownloadEntry copyWith({
    DownloadStatus? status,
    int? total,
    int? completed,
    List<DownloadedPage>? pages,
    DateTime? updatedAt,
    String? error,
    bool clearError = false,
    String? text,
    String? nextChapterUrl,
  }) =>
      DownloadEntry(
        sourceId: sourceId,
        bookId: bookId,
        bookTitle: bookTitle,
        chapterId: chapterId,
        chapterTitle: chapterTitle,
        chapterUrl: chapterUrl,
        chapterDate: chapterDate,
        status: status ?? this.status,
        total: total ?? this.total,
        completed: completed ?? this.completed,
        pages: pages ?? this.pages,
        createdAt: createdAt,
        updatedAt: updatedAt ?? DateTime.now(),
        error: clearError ? null : (error ?? this.error),
        text: text ?? this.text,
        nextChapterUrl: nextChapterUrl ?? this.nextChapterUrl,
      );

  Map<String, dynamic> toJson() => {
        'sourceId': sourceId,
        'bookId': bookId,
        'bookTitle': bookTitle,
        'chapterId': chapterId,
        'chapterTitle': chapterTitle,
        'chapterUrl': chapterUrl,
        'chapterDate': chapterDate,
        'status': status.name,
        'total': total,
        'completed': completed,
        'pages': pages.map((p) => p.toJson()).toList(),
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'error': error,
        'text': text,
        'nextChapterUrl': nextChapterUrl,
      };

  factory DownloadEntry.fromJson(Map<String, dynamic> j) => DownloadEntry(
        sourceId: j['sourceId'] as String,
        bookId: j['bookId'] as String,
        bookTitle: j['bookTitle'] as String,
        chapterId: j['chapterId'] as String,
        chapterTitle: j['chapterTitle'] as String,
        chapterUrl: j['chapterUrl'] as String,
        chapterDate: j['chapterDate'] as String?,
        status: DownloadStatus.values.firstWhere(
          (s) => s.name == j['status'],
          orElse: () => DownloadStatus.queued,
        ),
        total: (j['total'] as int?) ?? 0,
        completed: (j['completed'] as int?) ?? 0,
        pages: ((j['pages'] as List?) ?? [])
            .map((e) => DownloadedPage.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        createdAt: DateTime.parse(j['createdAt'] as String),
        updatedAt: DateTime.parse(j['updatedAt'] as String),
        error: j['error'] as String?,
        text: j['text'] as String?,
        nextChapterUrl: j['nextChapterUrl'] as String?,
      );
}

/// Hive + filesystem backed downloads store.
class DownloadsRepository {
  static const String boxName = 'downloads';
  /// Side box keyed by `sourceId::bookId`, value = serialized BookDetail.
  /// Lets the Downloads screen open a chapter directly in the reader
  /// without re-fetching the book over the network (offline-first).
  static const String bookSnapshotBoxName = 'download_books';

  Box<Map> get _box => Hive.box<Map>(boxName);
  Box<Map> get _bookBox => Hive.box<Map>(bookSnapshotBoxName);

  Directory? _rootDir;
  final Map<String, CancelToken> _inFlight = {};
  final Map<String, StreamController<DownloadEntry>> _watchers = {};

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await Hive.openBox<Map>(boxName);
    }
    if (!Hive.isBoxOpen(bookSnapshotBoxName)) {
      await Hive.openBox<Map>(bookSnapshotBoxName);
    }
  }

  String _bookKey(String sourceId, String bookId) => '$sourceId::$bookId';

  Future<void> saveBookSnapshot(BookDetail book) async {
    await _bookBox.put(_bookKey(book.sourceId, book.id), book.toJson());
  }

  BookDetail? getBookSnapshot(String sourceId, String bookId) {
    final raw = _bookBox.get(_bookKey(sourceId, bookId));
    if (raw == null) return null;
    try {
      return BookDetail.fromJson(Map<String, dynamic>.from(raw));
    } catch (_) {
      return null;
    }
  }

  Future<Directory> _ensureRoot() async {
    if (_rootDir != null) return _rootDir!;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/downloads');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _rootDir = dir;
    return dir;
  }

  String _keyFor(String sourceId, String bookId, String chapterId) =>
      '$sourceId::$bookId::$chapterId';

  DownloadEntry? get(String sourceId, String bookId, String chapterId) {
    final raw = _box.get(_keyFor(sourceId, bookId, chapterId));
    if (raw == null) return null;
    return DownloadEntry.fromJson(Map<String, dynamic>.from(raw));
  }

  bool isDownloaded(String sourceId, String bookId, String chapterId) {
    final e = get(sourceId, bookId, chapterId);
    return e != null && e.status == DownloadStatus.done;
  }

  bool isDownloading(String sourceId, String bookId, String chapterId) {
    final e = get(sourceId, bookId, chapterId);
    return e != null &&
        (e.status == DownloadStatus.queued ||
            e.status == DownloadStatus.downloading);
  }

  List<DownloadEntry> all() {
    final list = _box.values
        .map((m) => DownloadEntry.fromJson(Map<String, dynamic>.from(m)))
        .toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  /// Watch a single chapter's download entry. Emits current state immediately
  /// and on every update.
  Stream<DownloadEntry> watch(String sourceId, String bookId, String chapterId) {
    final key = _keyFor(sourceId, bookId, chapterId);
    final ctrl = _watchers.putIfAbsent(
      key,
      () => StreamController<DownloadEntry>.broadcast(),
    );
    // Push initial state on next microtask so listeners attach first.
    scheduleMicrotask(() {
      final cur = get(sourceId, bookId, chapterId);
      if (cur != null && !ctrl.isClosed) ctrl.add(cur);
    });
    return ctrl.stream;
  }

  void _emit(DownloadEntry entry) {
    final ctrl = _watchers[entry.key];
    if (ctrl != null && !ctrl.isClosed) ctrl.add(entry);
  }

  Future<void> _save(DownloadEntry entry) async {
    await _box.put(entry.key, entry.toJson());
    _emit(entry);
  }

  String _extFromUrl(String url) {
    try {
      final u = Uri.parse(url);
      final path = u.path;
      final dot = path.lastIndexOf('.');
      if (dot < 0 || dot == path.length - 1) return 'jpg';
      final ext = path.substring(dot + 1).toLowerCase();
      if (ext.length > 5 || !RegExp(r'^[a-z0-9]+$').hasMatch(ext)) return 'jpg';
      return ext;
    } catch (_) {
      return 'jpg';
    }
  }

  Future<void> enqueue(
    BookDetail book,
    Chapter chapter,
    List<PageContent> pages,
    Dio dio,
  ) async {
    // Cache the book metadata + chapter list so the Downloads screen can
    // open the reader offline without re-fetching the detail page.
    // ignore: discarded_futures
    saveBookSnapshot(book);

    final key = _keyFor(book.sourceId, book.id, chapter.id);
    final now = DateTime.now();

    // If already done, no-op.
    final existing = get(book.sourceId, book.id, chapter.id);
    if (existing != null && existing.status == DownloadStatus.done) return;

    final entry = DownloadEntry(
      sourceId: book.sourceId,
      bookId: book.id,
      bookTitle: book.title,
      chapterId: chapter.id,
      chapterTitle: chapter.title,
      chapterUrl: chapter.url,
      chapterDate: chapter.date,
      status: DownloadStatus.queued,
      total: pages.length,
      completed: 0,
      pages: const [],
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
    );
    await _save(entry);

    final cancelToken = CancelToken();
    _inFlight[key] = cancelToken;

    try {
      final root = await _ensureRoot();
      final chapterDir = Directory(
        '${root.path}/${book.sourceId}/${book.id}/${chapter.id}',
      );
      if (!await chapterDir.exists()) {
        await chapterDir.create(recursive: true);
      }

      var current = entry.copyWith(status: DownloadStatus.downloading);
      await _save(current);

      final downloaded = <DownloadedPage>[];
      for (var i = 0; i < pages.length; i++) {
        if (cancelToken.isCancelled) {
          throw Exception('cancelled');
        }
        final p = pages[i];
        final ext = _extFromUrl(p.url);
        final filePath = '${chapterDir.path}/$i.$ext';

        await dio.download(
          p.url,
          filePath,
          options: Options(
            headers: p.headers,
            responseType: ResponseType.bytes,
          ),
          cancelToken: cancelToken,
        );

        downloaded.add(DownloadedPage(
          url: p.url,
          localPath: filePath,
          headers: p.headers,
        ));

        current = current.copyWith(
          completed: i + 1,
          pages: List.unmodifiable(downloaded),
        );
        await _save(current);
      }

      final done = current.copyWith(
        status: DownloadStatus.done,
        clearError: true,
        updatedAt: DateTime.now(),
      );
      await _save(done);
    } catch (e) {
      final cur = get(book.sourceId, book.id, chapter.id) ?? entry;
      final failed = cur.copyWith(
        status: DownloadStatus.failed,
        error: e.toString(),
        updatedAt: DateTime.now(),
      );
      await _save(failed);
    } finally {
      _inFlight.remove(key);
    }
  }

  /// Novel-only download: stores the chapter's plain text inline in Hive
  /// (typically <50 KB per chapter). No filesystem dir needed — the novel
  /// reader pulls the text straight out of the DownloadEntry.
  Future<void> enqueueNovel({
    required BookDetail book,
    required Chapter chapter,
    required String text,
    String? nextChapterUrl,
  }) async {
    // ignore: discarded_futures
    saveBookSnapshot(book);
    final now = DateTime.now();
    final entry = DownloadEntry(
      sourceId: book.sourceId,
      bookId: book.id,
      bookTitle: book.title,
      chapterId: chapter.id,
      chapterTitle: chapter.title,
      chapterUrl: chapter.url,
      chapterDate: chapter.date,
      status: DownloadStatus.done,
      total: 1,
      completed: 1,
      pages: const [],
      createdAt: now,
      updatedAt: now,
      text: text,
      nextChapterUrl: nextChapterUrl,
    );
    await _save(entry);
  }

  Future<void> cancel(String sourceId, String bookId, String chapterId) async {
    final key = _keyFor(sourceId, bookId, chapterId);
    final tok = _inFlight[key];
    tok?.cancel('user cancelled');
    _inFlight.remove(key);
    // Also clean up the partial directory + Hive entry.
    await delete(sourceId, bookId, chapterId);
  }

  Future<void> delete(String sourceId, String bookId, String chapterId) async {
    final key = _keyFor(sourceId, bookId, chapterId);
    try {
      final root = await _ensureRoot();
      final dir = Directory('${root.path}/$sourceId/$bookId/$chapterId');
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {
      // Best-effort.
    }
    await _box.delete(key);
    // Emit so any listeners can react (stream will simply not emit a new
    // entry; safest to close).
    final ctrl = _watchers[key];
    if (ctrl != null && !ctrl.isClosed) {
      // Emit a synthetic "deleted" by closing; subscribers should treat
      // null/missing entries as not-downloaded.
      ctrl.add(DownloadEntry(
        sourceId: sourceId,
        bookId: bookId,
        bookTitle: '',
        chapterId: chapterId,
        chapterTitle: '',
        chapterUrl: '',
        status: DownloadStatus.failed,
        total: 0,
        completed: 0,
        pages: const [],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        error: '__deleted__',
      ));
    }
  }

  Future<void> dispose() async {
    for (final c in _watchers.values) {
      await c.close();
    }
    _watchers.clear();
  }
}
