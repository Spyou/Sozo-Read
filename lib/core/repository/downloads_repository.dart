import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';

import '../models/book_detail.dart';
import '../models/chapter.dart';
import '../models/page_content.dart';

/// Lifecycle of a chapter download.
///
/// Ordering is deliberate so old code that compared by ordinal still does
/// the "right thing": `queued` < `downloading` < `paused` < `done` < `failed`.
/// `paused` sits between `downloading` and `done` because in practice a
/// paused entry has *some* progress and just needs a kick to finish.
enum DownloadStatus { queued, downloading, paused, done, failed }

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

  /// Full list of pages the chapter *should* end up with, captured at
  /// enqueue time. Each entry's URL + headers is what the worker uses to
  /// fetch page `i` if the local file doesn't already exist.
  ///
  /// This is intentionally a separate list from [pages]: `pages` only
  /// contains COMPLETED pages, so without `targetPages` a resume can't
  /// know the URL for pages that were never written.
  final List<DownloadedPage> targetPages;

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
    this.targetPages = const [],
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
    List<DownloadedPage>? targetPages,
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
        targetPages: targetPages ?? this.targetPages,
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
        'targetPages': targetPages.map((p) => p.toJson()).toList(),
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
            .map((e) =>
                DownloadedPage.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        targetPages: ((j['targetPages'] as List?) ?? [])
            .map((e) =>
                DownloadedPage.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        createdAt: DateTime.parse(j['createdAt'] as String),
        updatedAt: DateTime.parse(j['updatedAt'] as String),
        error: j['error'] as String?,
        text: j['text'] as String?,
        nextChapterUrl: j['nextChapterUrl'] as String?,
      );
}

/// Hive + filesystem backed downloads store with a small worker-pool for
/// concurrent, pausable, retryable chapter downloads.
///
/// Architecture notes:
///   * `enqueue` is the only public path that creates new entries; it saves
///     the entry as `queued` (including `targetPages`) and kicks the worker
///     pool. The actual transfer happens off-call.
///   * The worker pool is a simple counter (`_activeWorkers`) bounded by
///     [kMaxConcurrent]. Each kick scans Hive for the oldest `queued`
///     entry and launches a `_processOne` future on it; nothing fancier
///     than that.
///   * Pause/resume/retry are pure status flips that re-enter the same
///     kick loop. The worker honors a per-key [CancelToken] and detects
///     "paused" mid-chapter by checking the current Hive state on every
///     page boundary — keeps cleanup logic out of every catch block.
///   * WiFi-only enforcement happens at worker pickup time. If the rule
///     would block a job, the entry is flipped to `paused` with a small
///     note in `error` and the worker exits. Connectivity changes
///     re-kick the pool so paused-for-wifi entries thaw automatically.
class DownloadsRepository {
  static const String boxName = 'downloads';

  /// Side box keyed by `sourceId::bookId`, value = serialized BookDetail.
  /// Lets the Downloads screen open a chapter directly in the reader
  /// without re-fetching the book over the network (offline-first).
  static const String bookSnapshotBoxName = 'download_books';

  /// Hard cap on simultaneous in-flight chapter downloads. Chosen low (2)
  /// because manga CDNs rate-limit aggressively and a single chapter is
  /// already 20-100 sequential image fetches.
  static const int kMaxConcurrent = 2;

  Box<Map> get _box => Hive.box<Map>(boxName);
  Box<Map> get _bookBox => Hive.box<Map>(bookSnapshotBoxName);

  Directory? _rootDir;
  final Map<String, CancelToken> _inFlight = {};
  final Map<String, StreamController<DownloadEntry>> _watchers = {};

  // ---- Worker-pool state. ----------------------------------------------
  int _activeWorkers = 0;
  bool _kicking = false;
  Dio? _defaultDio;
  StreamSubscription<dynamic>? _connSub;

  /// Most recent dio passed to [enqueue]. The worker-pool needs *some*
  /// dio to make requests but resume/retry don't take one as a parameter
  /// (they should "just work" after a restart), so we cache the latest.
  /// If no dio has ever been provided, resume/retry will fail with a
  /// clear error rather than silently no-op.
  Dio? get _workerDio => _defaultDio;

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await Hive.openBox<Map>(boxName);
    }
    if (!Hive.isBoxOpen(bookSnapshotBoxName)) {
      await Hive.openBox<Map>(bookSnapshotBoxName);
    }
  }

  /// Wire up the connectivity listener. Idempotent — safe to call multiple
  /// times. The DI layer calls this lazily on first repo access; AppBootstrap
  /// doesn't need to know about it.
  void _ensureConnectivityListener() {
    if (_connSub != null) return;
    try {
      _connSub = Connectivity().onConnectivityChanged.listen((_) {
        // Network changed — re-kick. Workers that were blocked on WiFi-only
        // will see WiFi available now; workers on a healthy link are a no-op.
        _kickWorkers();
      });
    } catch (e) {
      // Connectivity plugin not available (test env, desktop, etc).
      // Degrade gracefully: WiFi-only just won't auto-resume.
      debugPrint('[downloads] connectivity listener init failed: $e');
    }
  }

  /// True if WiFi-only is enabled in user prefs and the current link is not
  /// WiFi. Best-effort: any failure to reach the connectivity plugin returns
  /// `false` (i.e. let the download proceed) so we never strand users on
  /// platforms where the plugin can't tell us anything.
  Future<bool> _shouldWaitForWifi() async {
    if (!_isWifiOnlyEnabled()) return false;
    try {
      final res = await Connectivity().checkConnectivity();
      // connectivity_plus 6.x returns a List<ConnectivityResult>.
      return !res.contains(ConnectivityResult.wifi);
    } catch (_) {
      return false;
    }
  }

  /// Reads the WiFi-only flag from the shared `settings` Hive box.
  /// Kept inline here (rather than depending on a cubit) so the repo
  /// stays UI-framework-independent and testable.
  bool _isWifiOnlyEnabled() {
    try {
      if (!Hive.isBoxOpen('settings')) return false;
      final box = Hive.box('settings');
      return (box.get('downloads.wifi_only') as bool?) ?? false;
    } catch (_) {
      return false;
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

  /// Enqueue a chapter for download. Returns immediately after persisting
  /// the entry; the actual transfer happens on the worker pool.
  ///
  /// Backwards-compatible with the pre-concurrency signature: existing
  /// callers in `detail_screen.dart` and `manga_reader_screen.dart` still
  /// compile and behave the same from their perspective (fire-and-forget).
  Future<void> enqueue(
    BookDetail book,
    Chapter chapter,
    List<PageContent> pages,
    Dio dio,
  ) async {
    _defaultDio = dio;
    _ensureConnectivityListener();

    // Cache the book metadata + chapter list so the Downloads screen can
    // open the reader offline without re-fetching the detail page.
    // ignore: discarded_futures
    saveBookSnapshot(book);

    final now = DateTime.now();

    // If already done, no-op.
    final existing = get(book.sourceId, book.id, chapter.id);
    if (existing != null && existing.status == DownloadStatus.done) return;

    final targetPages = pages
        .map((p) => DownloadedPage(
              url: p.url,
              localPath: '', // filled in by the worker when written
              headers: p.headers,
            ))
        .toList(growable: false);

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
      completed: existing?.completed ?? 0,
      pages: existing?.pages ?? const [],
      targetPages: targetPages,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
    );
    await _save(entry);

    _kickWorkers();
  }

  // -- Worker pool -------------------------------------------------------

  /// Try to start more workers up to [kMaxConcurrent]. Safe to call from
  /// any code path — re-entrancy is guarded by `_kicking`.
  void _kickWorkers() {
    if (_kicking) return;
    _kicking = true;
    try {
      while (_activeWorkers < kMaxConcurrent) {
        final next = _findNextQueued();
        if (next == null) break;
        // Flip to downloading *before* the future runs so a second iter
        // of the while loop doesn't pick the same entry.
        final running = next.copyWith(
          status: DownloadStatus.downloading,
          updatedAt: DateTime.now(),
          clearError: true,
        );
        // ignore: discarded_futures
        _box.put(running.key, running.toJson()).then((_) {
          _emit(running);
        });
        _activeWorkers++;
        // Fire-and-forget. _processOne handles its own errors.
        // ignore: discarded_futures
        _processOne(running).whenComplete(() {
          _activeWorkers = (_activeWorkers - 1).clamp(0, kMaxConcurrent);
          // Tail-call the kick on a microtask so the decrement is visible
          // and re-entrancy is clean.
          scheduleMicrotask(_kickWorkers);
        });
      }
    } finally {
      _kicking = false;
    }
  }

  /// Oldest (by createdAt) entry in `queued` state, or null.
  DownloadEntry? _findNextQueued() {
    DownloadEntry? best;
    for (final raw in _box.values) {
      final entry =
          DownloadEntry.fromJson(Map<String, dynamic>.from(raw));
      if (entry.status != DownloadStatus.queued) continue;
      if (entry.isNovel) continue; // novels are stored inline, no worker
      if (best == null || entry.createdAt.isBefore(best.createdAt)) {
        best = entry;
      }
    }
    return best;
  }

  Future<void> _processOne(DownloadEntry initial) async {
    final key = initial.key;
    final dio = _workerDio;
    if (dio == null) {
      // Resume/retry called before any enqueue → no dio cached.
      final failed = initial.copyWith(
        status: DownloadStatus.failed,
        error: 'No network client available (open a chapter to retry).',
        updatedAt: DateTime.now(),
      );
      await _save(failed);
      return;
    }

    // WiFi-only gate. We re-check at the *start* of every job so an entry
    // that was queued while on WiFi but picked up after a switch to LTE
    // still gets paused. Sets the small note + flips to paused and bails.
    if (await _shouldWaitForWifi()) {
      final cur = get(initial.sourceId, initial.bookId, initial.chapterId) ??
          initial;
      final paused = cur.copyWith(
        status: DownloadStatus.paused,
        error: 'Waiting for WiFi',
        updatedAt: DateTime.now(),
      );
      await _save(paused);
      return;
    }

    final cancelToken = CancelToken();
    _inFlight[key] = cancelToken;

    try {
      final root = await _ensureRoot();
      final chapterDir = Directory(
        '${root.path}/${initial.sourceId}/${initial.bookId}/${initial.chapterId}',
      );
      if (!await chapterDir.exists()) {
        await chapterDir.create(recursive: true);
      }

      // Mutable working copy. We refresh from Hive on each iteration so a
      // pause/cancel that landed mid-flight is reflected immediately.
      var current = initial;
      final downloaded = List<DownloadedPage>.from(current.pages);
      final targets = current.targetPages;
      if (targets.isEmpty) {
        throw StateError(
          'Entry has no targetPages — was it created before the '
          'concurrency refactor? Delete and re-enqueue.',
        );
      }

      for (var i = 0; i < targets.length; i++) {
        // Pause/cancel checkpoint at every page boundary. Reading the
        // latest Hive state means an external `pause()` call that
        // happened during the previous dio.download is honored here even
        // though the cancel token's cancel was best-effort.
        final latest =
            get(initial.sourceId, initial.bookId, initial.chapterId);
        if (latest == null) {
          // Entry was deleted from under us — nothing to do.
          return;
        }
        if (latest.status == DownloadStatus.paused) {
          // User paused. We've already written `pages` and `completed`
          // via _save inside the previous iteration; just exit.
          return;
        }
        if (cancelToken.isCancelled) {
          // Treat cancel-without-status-flip as a pause so we don't lose
          // already-downloaded pages. The caller (cancel()) deletes the
          // whole entry, so this branch only fires for pause-driven
          // cancels.
          final cur = latest;
          if (cur.status != DownloadStatus.paused) {
            await _save(cur.copyWith(
              status: DownloadStatus.paused,
              updatedAt: DateTime.now(),
            ));
          }
          return;
        }

        final p = targets[i];

        // Resume support: skip if a page at this slot already exists on
        // disk *and* in the entry's pages list. We trust `pages[i]` over
        // a filesystem-existence check because the localPath includes
        // the extension we picked at download time.
        if (i < downloaded.length) {
          final existing = downloaded[i];
          if (existing.localPath.isNotEmpty &&
              await File(existing.localPath).exists()) {
            continue;
          }
        }

        final ext = _extFromUrl(p.url);
        final filePath = '${chapterDir.path}/$i.$ext';

        // If the file is on disk from a previous half-completed run but
        // the in-memory `downloaded` list doesn't know about it, claim
        // it rather than re-downloading.
        if (i >= downloaded.length && await File(filePath).exists()) {
          downloaded.add(DownloadedPage(
            url: p.url,
            localPath: filePath,
            headers: p.headers,
          ));
          current = current.copyWith(
            completed: downloaded.length,
            pages: List.unmodifiable(downloaded),
          );
          await _save(current);
          continue;
        }

        await dio.download(
          p.url,
          filePath,
          options: Options(
            headers: p.headers,
            responseType: ResponseType.bytes,
          ),
          cancelToken: cancelToken,
        );

        final page = DownloadedPage(
          url: p.url,
          localPath: filePath,
          headers: p.headers,
        );
        if (i < downloaded.length) {
          downloaded[i] = page;
        } else {
          downloaded.add(page);
        }

        current = current.copyWith(
          completed: downloaded.length,
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
      // If the token was cancelled by pause(), we want `paused`, not
      // `failed`. Inspect the cancel reason to disambiguate.
      final wasPaused = e is DioException &&
          CancelToken.isCancel(e) &&
          (e.message?.contains('pause') == true);

      final cur = get(initial.sourceId, initial.bookId, initial.chapterId);
      if (cur == null) return; // entry deleted during the run

      if (wasPaused || cur.status == DownloadStatus.paused) {
        // Already flipped to paused by pause(); just make sure the
        // timestamp updates so listeners notice.
        if (cur.status != DownloadStatus.paused) {
          await _save(cur.copyWith(
            status: DownloadStatus.paused,
            updatedAt: DateTime.now(),
          ));
        }
      } else {
        await _save(cur.copyWith(
          status: DownloadStatus.failed,
          error: e.toString(),
          updatedAt: DateTime.now(),
        ));
      }
    } finally {
      _inFlight.remove(key);
    }
  }

  // -- Pause / Resume / Retry --------------------------------------------

  /// Pause an in-progress or queued chapter download. Mid-flight pages are
  /// cancelled; already-written pages stay on disk so resume() picks up
  /// where this left off.
  Future<void> pause(String sourceId, String bookId, String chapterId) async {
    final cur = get(sourceId, bookId, chapterId);
    if (cur == null) return;
    if (cur.status == DownloadStatus.done ||
        cur.status == DownloadStatus.paused) {
      return;
    }
    // Flip status first so the worker's next-page checkpoint sees it.
    await _save(cur.copyWith(
      status: DownloadStatus.paused,
      updatedAt: DateTime.now(),
    ));
    final tok = _inFlight[_keyFor(sourceId, bookId, chapterId)];
    tok?.cancel('paused by user');
  }

  /// Resume a paused or queued chapter download. Worker will skip pages
  /// that are already on disk so this is cheap even if called repeatedly.
  Future<void> resume(String sourceId, String bookId, String chapterId) async {
    final cur = get(sourceId, bookId, chapterId);
    if (cur == null) return;
    if (cur.status == DownloadStatus.done ||
        cur.status == DownloadStatus.downloading) {
      return;
    }
    _ensureConnectivityListener();
    await _save(cur.copyWith(
      status: DownloadStatus.queued,
      clearError: true,
      updatedAt: DateTime.now(),
    ));
    _kickWorkers();
  }

  /// Retry a failed chapter download. Identical to resume() but only
  /// valid when status is `failed` — guards against accidentally
  /// "retrying" a done chapter.
  Future<void> retry(String sourceId, String bookId, String chapterId) async {
    final cur = get(sourceId, bookId, chapterId);
    if (cur == null) return;
    if (cur.status != DownloadStatus.failed) return;
    _ensureConnectivityListener();
    await _save(cur.copyWith(
      status: DownloadStatus.queued,
      clearError: true,
      updatedAt: DateTime.now(),
    ));
    _kickWorkers();
  }

  // -- Bulk enqueue ------------------------------------------------------

  /// Enqueue many chapters at once. Page-list fetches are bounded to ~3
  /// concurrent so we don't hammer the source — per-chapter failures are
  /// logged and skipped so one dead chapter doesn't kill the batch.
  ///
  /// Returns when all chapters have been enqueued (or skipped). Does NOT
  /// wait for the downloads themselves to finish; that's the worker
  /// pool's job.
  Future<void> enqueueMany({
    required BookDetail book,
    required List<Chapter> chapters,
    required Future<List<PageContent>> Function(Chapter) fetchPages,
    required Dio dio,
  }) async {
    _defaultDio = dio;
    _ensureConnectivityListener();

    const fetchConcurrency = 3;
    var index = 0;

    Future<void> worker() async {
      while (true) {
        final myIndex = index++;
        if (myIndex >= chapters.length) return;
        final chapter = chapters[myIndex];
        try {
          final pages = await fetchPages(chapter);
          if (pages.isEmpty) {
            debugPrint(
              '[downloads] enqueueMany: ${chapter.title} -> 0 pages, skipping',
            );
            continue;
          }
          await enqueue(book, chapter, pages, dio);
        } catch (e, st) {
          debugPrint(
            '[downloads] enqueueMany: failed to fetch pages for '
            '${chapter.title}: $e\n$st',
          );
        }
      }
    }

    final workers = List<Future<void>>.generate(
      fetchConcurrency.clamp(1, chapters.isEmpty ? 1 : chapters.length),
      (_) => worker(),
    );
    await Future.wait(workers);
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
    await _connSub?.cancel();
    _connSub = null;
    for (final c in _watchers.values) {
      await c.close();
    }
    _watchers.clear();
  }
}
