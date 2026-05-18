import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/di/injection.dart';
import '../../../../core/models/book_item.dart';
import '../../../../core/repository/downloads_repository.dart';
import '../../../../core/repository/library_repository.dart';
import '../../../../core/repository/provider_repository.dart';
import '../../../../core/repository/read_chapters_repository.dart';
import '../../../../core/state/auth_service.dart';
import 'novel_reader_event.dart';
import 'novel_reader_state.dart';

class NovelReaderBloc extends Bloc<NovelReaderEvent, NovelReaderState> {
  NovelReaderBloc({
    required ProviderRepository providerRepo,
    required LibraryRepository libraryRepo,
  })  : _provider = providerRepo,
        _library = libraryRepo,
        super(const NovelReaderState()) {
    on<NovelReaderStarted>(_onStarted);
    on<NovelReaderChapterChanged>(_onChapterChanged);
    on<NovelReaderFontSizeChanged>(_onFontSize);
    on<NovelReaderProgressUpdated>(_onProgress);
    on<NovelReaderResumeConsumed>(_onResumeConsumed);
  }

  final ProviderRepository _provider;
  final LibraryRepository _library;

  /// Guard so paging past 99% only writes the read mark once per chapter.
  String? _lastMarkedChapterKey;

  Future<void> _onStarted(NovelReaderStarted event, Emitter<NovelReaderState> emit) async {
    emit(state.copyWith(book: event.book, chapterIndex: event.chapterIndex, progress: 0));
    var entry = _library.get(event.book.sourceId, event.book.id);

    // Auto-save: if the book isn't already in the library AND the user
    // is signed in, save it as Reading on first chapter open. Matches
    // the manga reader's behaviour so Continue-Reading + Library
    // populate without an extra tap. Signed-out users hit the explicit
    // bookmark gate on the detail screen.
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
    // Promote planning/on-hold -> reading so the book shows up in the
    // Library Reading tab + Home Continue-Reading row. Completed stays.
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
    await _fetch(emit, pendingResume: resume);
  }

  Future<void> _onChapterChanged(NovelReaderChapterChanged event, Emitter<NovelReaderState> emit) async {
    final book = state.book;
    if (book == null) return;
    final i = event.chapterIndex.clamp(0, book.chapters.length - 1);

    // Tapping Next/Prev is a strong "I finished this one" signal — much
    // more reliable than scrolling past 99% of a page that has ads /
    // comments / extra UI past the actual chapter end. Mark the previous
    // chapter as read before we switch. We only consider it "finished"
    // if the user had at least some progress on it (avoids marking
    // chapters they barely opened).
    if (state.chapterIndex >= 0 &&
        state.chapterIndex < book.chapters.length &&
        state.chapterIndex != i &&
        state.progress > 0.4) {
      final prev = book.chapters[state.chapterIndex];
      final prevKey = '${book.sourceId}::${book.id}::${prev.id}';
      if (_lastMarkedChapterKey != prevKey) {
        _lastMarkedChapterKey = prevKey;
        // ignore: discarded_futures
        sl<ReadChaptersRepository>().mark(book.sourceId, book.id, prev.id);
      }
    }

    // Reset guard so the next chapter's own end-of-content mark can fire.
    _lastMarkedChapterKey = null;
    emit(state.copyWith(chapterIndex: i, progress: 0, clearResume: true));
    await _fetch(emit);
  }

  void _onFontSize(NovelReaderFontSizeChanged event, Emitter<NovelReaderState> emit) {
    final next = (state.fontSize + event.delta).clamp(12.0, 28.0);
    emit(state.copyWith(fontSize: next));
  }

  void _onProgress(NovelReaderProgressUpdated event, Emitter<NovelReaderState> emit) {
    emit(state.copyWith(progress: event.progress));
    final book = state.book;
    if (book == null) return;
    _library.updateProgress(
      sourceId: book.sourceId,
      bookId: book.id,
      chapterIndex: state.chapterIndex,
      chapterProgress: event.progress,
    );
    // Mark as read once the user crosses 85% of the scrollable area.
    // 99% was too strict — novel pages have ads / comments / extra UI
    // past the actual chapter text, so users naturally stop scrolling
    // well before the absolute bottom. 85% is a good "they read the
    // content" threshold without false positives from a quick skim.
    if (event.progress >= 0.85 &&
        state.chapterIndex >= 0 &&
        state.chapterIndex < book.chapters.length) {
      final ch = book.chapters[state.chapterIndex];
      final key = '${book.sourceId}::${book.id}::${ch.id}';
      if (_lastMarkedChapterKey != key) {
        _lastMarkedChapterKey = key;
        // ignore: discarded_futures
        sl<ReadChaptersRepository>().mark(book.sourceId, book.id, ch.id);
      }
    }
  }

  void _onResumeConsumed(
      NovelReaderResumeConsumed event, Emitter<NovelReaderState> emit) {
    emit(state.copyWith(clearResume: true));
  }

  Future<void> _fetch(
    Emitter<NovelReaderState> emit, {
    double? pendingResume,
  }) async {
    final book = state.book;
    if (book == null || book.chapters.isEmpty) return;
    emit(state.copyWith(status: NovelReaderStatus.loading, clearError: true, text: ''));
    final ch = book.chapters[state.chapterIndex];

    // Offline-first: if the user downloaded this chapter, serve it from
    // Hive instead of round-tripping to the source. The reader doesn't
    // need to care whether the user is online or not.
    final cached = sl<DownloadsRepository>()
        .get(book.sourceId, book.id, ch.id);
    if (cached != null && cached.text != null && cached.text!.isNotEmpty) {
      emit(state.copyWith(
        status: NovelReaderStatus.success,
        text: cached.text!,
        pendingResumeProgress: pendingResume,
      ));
      return;
    }

    final result = await _provider.novelContent(book.sourceId, ch.url);
    result.fold(
      (f) => emit(state.copyWith(status: NovelReaderStatus.error, error: f.message)),
      (c) => emit(state.copyWith(
        status: NovelReaderStatus.success,
        text: c.text,
        pendingResumeProgress: pendingResume,
      )),
    );
  }
}
