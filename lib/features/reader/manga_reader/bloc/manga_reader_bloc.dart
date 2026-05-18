import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/di/injection.dart';
import '../../../../core/models/book_item.dart';
import '../../../../core/models/page_content.dart';
import '../../../../core/repository/downloads_repository.dart';
import '../../../../core/repository/library_repository.dart';
import '../../../../core/repository/provider_repository.dart';
import '../../../../core/repository/read_chapters_repository.dart';
import '../../../../core/state/auth_service.dart';
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
    // signed in, create an entry with status=Reading on first chapter
    // open. Mirrors Tachiyomi / Webnovel behaviour — opening a chapter
    // is an implicit "I want to read this." Signed-out users still get
    // gated at the explicit bookmark button on the detail screen.
    if (entry == null && sl<AuthService>().isSignedIn) {
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

    final resume = (entry != null &&
            entry.lastChapterIndex == event.chapterIndex &&
            (entry.lastChapterProgress ?? 0) > 0 &&
            (entry.lastChapterProgress ?? 0) < 1)
        ? entry.lastChapterProgress
        : null;
    // Promote planning / on-hold -> reading so the book shows up in the
    // Library "Reading" tab + Home Continue-Reading row. Completed books
    // are left alone — re-reading a finished book shouldn't demote it.
    if (entry != null &&
        entry.status != LibraryStatus.reading &&
        entry.status != LibraryStatus.completed) {
      // ignore: discarded_futures
      _library.setStatus(
        event.book.sourceId,
        event.book.id,
        LibraryStatus.reading,
      );
    }
    await _fetchPages(emit, pendingResume: resume);
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
        pendingResumeProgress: pendingResume,
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
          pendingResumeProgress: pages.isNotEmpty ? pendingResume : null,
        ));
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
