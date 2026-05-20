import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/di/injection.dart';
import '../../../../core/models/book_item.dart';
import '../../../../core/models/page_content.dart';
import '../../../../core/repository/downloads_repository.dart';
import '../../../../core/repository/library_repository.dart';
import '../../../../core/repository/provider_repository.dart';
import '../../../../core/repository/chapter_thumbnails_repository.dart';
import '../../../../core/repository/read_chapters_repository.dart';
import '../../../../core/repository/tracker_repository.dart';
import 'manga_reader_event.dart';
import 'manga_reader_state.dart';

class MangaReaderBloc extends Bloc<MangaReaderEvent, MangaReaderState> {
  MangaReaderBloc({
    required ProviderRepository providerRepo,
    required LibraryRepository libraryRepo,
  })  : _provider = providerRepo,
        _library = libraryRepo,
        super(const MangaReaderState()) {
    on<MangaReaderStarted>(_onStarted);
    on<MangaReaderChapterChanged>(_onChapterChanged);
    on<MangaReaderPageChanged>(_onPageChanged);
    on<MangaReaderModeToggled>(_onModeToggled);
    on<MangaReaderDirectionToggled>(_onDirectionToggled);
    on<MangaReaderModeSet>(_onModeSet);
    on<MangaReaderBrightnessChanged>(_onBrightness);
    on<MangaReaderResumeConsumed>(_onResumeConsumed);
  }

  final ProviderRepository _provider;
  final LibraryRepository _library;

  /// Tracks the most recent chapter we marked as read so paging within the
  /// same chapter doesn't repeatedly hit the read-chapters repo. Cleared on
  /// chapter change.
  String? _lastMarkedChapterKey;

  Future<void> _onStarted(MangaReaderStarted event, Emitter<MangaReaderState> emit) async {
    emit(state.copyWith(
      book: event.book,
      chapterIndex: event.chapterIndex,
      pageIndex: 0,
      mode: event.initialMode,
      direction: event.initialDirection,
    ));
    // Honour saved progress only if the user is opening the *same* chapter
    // the library entry remembers.
    var entry = _library.get(event.book.sourceId, event.book.id);

    // Auto-save: if the book isn't in the library yet AND the user is
    // create an entry with status=Reading on first chapter open. Mirrors
    // Tachiyomi / Webnovel behaviour — opening a chapter is an implicit
    // "I want to read this." Used to be gated on `isSignedIn` but that
    // hid the Continue Reading row entirely for signed-out users; the
    // library dirty-queue handles deferred sync just fine, so add for
    // everyone and let sync catch up whenever the user signs in.
    if (entry == null) {
      final item = BookItem(
        id: event.book.id,
        title: event.book.title,
        cover: event.book.cover,
        url: event.book.url,
        type: event.book.type,
        sourceId: event.book.sourceId,
      );
      entry = await _library.add(item);
    }

    // Auto-match + promote remote status to "reading" so the series shows
    // up on the user's tracker reading list immediately, without waiting
    // for them to finish a chapter. Fire-and-forget.
    // ignore: discarded_futures
    sl<TrackerRepository>().pushReadingStarted(
      sourceId: event.book.sourceId,
      bookId: event.book.id,
      localTitle: event.book.title,
    );

    // If the caller asked to deep-jump to a specific page (page-bookmark
    // tap), that wins over the library's "you were 67% through" resume.
    // The resume fraction is computed inside _fetchPages once we know
    // how many pages the chapter actually has.
    final resume = event.initialPageIndex != null
        ? null
        : (entry.lastChapterIndex == event.chapterIndex &&
                (entry.lastChapterProgress ?? 0) > 0 &&
                (entry.lastChapterProgress ?? 0) < 1)
            ? entry.lastChapterProgress
            : null;
    // Promote to Reading whenever the user opens a chapter they haven't
    // already finished. This covers two cases:
    //   * planning / on-hold / dropped → reading (always)
    //   * completed → reading IFF the chapter being opened is unread
    //     (i.e. a new chapter has been released since they finished —
    //     "re-reading" an already-finished chapter stays Completed).
    if (entry.status != LibraryStatus.reading) {
      final openingCh = event.book.chapters.isNotEmpty
          ? event.book.chapters[event.chapterIndex]
          : null;
      final readIds = sl<ReadChaptersRepository>().getReadChapterIds(
        event.book.sourceId,
        event.book.id,
      );
      final openingIsUnread =
          openingCh != null && !readIds.contains(openingCh.id);
      final shouldPromote = entry.status != LibraryStatus.completed ||
          openingIsUnread;
      if (shouldPromote) {
        // ignore: discarded_futures
        _library.setStatus(
          event.book.sourceId,
          event.book.id,
          LibraryStatus.reading,
        );
      }
    }
    await _fetchPages(
      emit,
      pendingResume: resume,
      initialPageIndex: event.initialPageIndex,
    );
    _prefetchNext();
  }

  Future<void> _onChapterChanged(
      MangaReaderChapterChanged event, Emitter<MangaReaderState> emit) async {
    if (state.book == null) return;
    final i = event.chapterIndex.clamp(0, state.book!.chapters.length - 1);
    // Reset the "last marked" guard so the new chapter can be marked when
    // the user reaches its final page.
    _lastMarkedChapterKey = null;
    emit(state.copyWith(
      chapterIndex: i,
      pageIndex: 0,
      autoAdvancing: true,
      clearResume: true,
    ));
    await _fetchPages(emit);
    emit(state.copyWith(autoAdvancing: false));
    _prefetchNext();
  }

  void _onPageChanged(MangaReaderPageChanged event, Emitter<MangaReaderState> emit) {
    emit(state.copyWith(pageIndex: event.pageIndex));
    final book = state.book;
    if (book == null || state.pages.isEmpty) return;
    final progress = event.pageIndex / state.pages.length;
    _library.updateProgress(
      sourceId: book.sourceId,
      bookId: book.id,
      chapterIndex: state.chapterIndex,
      chapterProgress: progress,
    );
    // Mark the chapter read once the user crosses onto the last page (or
    // hits >= 99% otherwise). Guarded so paging back-and-forth within the
    // same chapter only writes to Hive once.
    if (state.chapterIndex >= 0 &&
        state.chapterIndex < book.chapters.length) {
      final reachedEnd =
          event.pageIndex >= state.pages.length - 1 || progress >= 0.99;
      if (reachedEnd) {
        final ch = book.chapters[state.chapterIndex];
        final key = '${book.sourceId}::${book.id}::${ch.id}';
        if (_lastMarkedChapterKey != key) {
          _lastMarkedChapterKey = key;
          // ignore: discarded_futures
          sl<ReadChaptersRepository>()
              .mark(book.sourceId, book.id, ch.id);
          // Push to any linked trackers (AniList today, MAL later). The
          // chapter list is newest-first, so chapterNumber comes from
          // Chapter.number when known; fall back to counting up from the
          // bottom of the list. Fire-and-forget — never blocks the reader.
          final chapterNumber = ch.number?.round() ??
              (book.chapters.length - state.chapterIndex);
          // ignore: discarded_futures
          sl<TrackerRepository>().pushProgress(
            sourceId: book.sourceId,
            bookId: book.id,
            chapterNumber: chapterNumber,
          );
          // If this was the newest chapter (chapter list is newest-first,
          // so index 0), auto-flip the local library to Completed so the
          // book drops off Home > Continue Reading and lands in the
          // Library > Completed tab. If the source later picks up a new
          // chapter (ongoing series), [_onStarted] promotes back to
          // Reading the moment the user opens that unread chapter.
          if (state.chapterIndex == 0) {
            // ignore: discarded_futures
            _library.setStatus(
              book.sourceId,
              book.id,
              LibraryStatus.completed,
            );
          }
        }
      }
    }
  }

  void _onModeToggled(MangaReaderModeToggled event, Emitter<MangaReaderState> emit) {
    emit(state.copyWith(
      mode: state.mode == ReaderMode.vertical ? ReaderMode.horizontal : ReaderMode.vertical,
    ));
  }

  void _onModeSet(MangaReaderModeSet event, Emitter<MangaReaderState> emit) {
    emit(state.copyWith(mode: event.mode));
  }

  void _onDirectionToggled(MangaReaderDirectionToggled event, Emitter<MangaReaderState> emit) {
    emit(state.copyWith(
      direction:
          state.direction == ReadingDirection.ltr ? ReadingDirection.rtl : ReadingDirection.ltr,
    ));
  }

  void _onBrightness(MangaReaderBrightnessChanged event, Emitter<MangaReaderState> emit) {
    emit(state.copyWith(brightness: event.value.clamp(0.0, 0.85)));
  }

  void _onResumeConsumed(
      MangaReaderResumeConsumed event, Emitter<MangaReaderState> emit) {
    emit(state.copyWith(clearResume: true));
  }

  Future<void> _fetchPages(
    Emitter<MangaReaderState> emit, {
    double? pendingResume,
    int? initialPageIndex,
  }) async {
    final book = state.book;
    if (book == null || book.chapters.isEmpty) return;
    final ch = book.chapters[state.chapterIndex];
    // ignore: avoid_print
    print('[reader] getPages ${book.sourceId} chapter=${ch.title} url=${ch.url}');
    emit(state.copyWith(
      status: ReaderStatus.loading,
      clearError: true,
      pages: const [],
    ));

    // Resolves the resume fraction once we know how many pages there
    // are. If the caller passed [initialPageIndex] (e.g. via a page
    // bookmark tap), convert it to a fraction here and override the
    // library's lastChapterProgress.
    double? resolveResume(int pageCount) {
      if (initialPageIndex != null && pageCount > 0) {
        final clamped = initialPageIndex.clamp(0, pageCount - 1);
        return clamped / pageCount;
      }
      return pendingResume;
    }

    // Offline fast-path: if this chapter is fully downloaded, build pages
    // from the local manifest and skip the network entirely.
    final downloads = sl<DownloadsRepository>();
    final entry = downloads.get(book.sourceId, book.id, ch.id);
    if (entry != null &&
        entry.status == DownloadStatus.done &&
        entry.pages.isNotEmpty) {
      final localPages = <PageContent>[
        for (var i = 0; i < entry.pages.length; i++)
          PageContent(
            url: 'file://${entry.pages[i].localPath}',
            index: i,
          ),
      ];
      emit(state.copyWith(
        status: ReaderStatus.success,
        pages: localPages,
        clearError: true,
        pendingResumeProgress: resolveResume(localPages.length),
      ));
      return;
    }

    final result = await _provider.pages(book.sourceId, ch.url);
    result.fold(
      (f) {
        // ignore: avoid_print
        print('[reader] getPages FAILED: ${f.message}');
        emit(state.copyWith(status: ReaderStatus.error, error: f.message));
      },
      (pages) {
        // ignore: avoid_print
        print('[reader] getPages OK: ${pages.length} pages');
        emit(state.copyWith(
          status: pages.isEmpty ? ReaderStatus.error : ReaderStatus.success,
          pages: pages,
          error: pages.isEmpty ? 'No pages (chapter may be external/licensed)' : null,
          clearError: pages.isNotEmpty,
          pendingResumeProgress:
              pages.isNotEmpty ? resolveResume(pages.length) : null,
        ));
        // Cache the first page URL so the chapter list + Bookmarks tab
        // can render a thumbnail for chapters the user has opened.
        if (pages.isNotEmpty) {
          // ignore: discarded_futures
          sl<ChapterThumbnailsRepository>().rememberFirstPage(
            sourceId: book.sourceId,
            bookId: book.id,
            chapterId: ch.id,
            firstPageUrl: pages.first.url,
          );
        }
      },
    );
  }

  /// Fire-and-forget prefetch of the next chapter's pages + first ~10 images.
  /// The chapter list is descending (index 0 = newest), so "next" is
  /// `chapterIndex - 1`.
  void _prefetchNext() {
    final book = state.book;
    if (book == null) return;
    final nextIdx = state.chapterIndex - 1;
    if (nextIdx < 0 || nextIdx >= book.chapters.length) return;
    final ch = book.chapters[nextIdx];
    // Run async without awaiting — we never want this to block the read.
    Future<void>(() async {
      try {
        final result = await _provider.pages(book.sourceId, ch.url);
        result.fold(
          (_) {},
          (pages) {
            final ctx = WidgetsBinding.instance.rootElement;
            if (ctx == null) return;
            final take = pages.take(10).toList();
            for (final p in take) {
              final provider = CachedNetworkImageProvider(
                p.url,
                headers: p.headers,
              );
              // ignore: discarded_futures
              precacheImage(provider, ctx).catchError((_) {});
            }
          },
        );
      } catch (_) {
        // Prefetch is best-effort.
      }
    });
  }
}
