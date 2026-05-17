import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/di/injection.dart';
import '../../../../core/repository/downloads_repository.dart';
import '../../../../core/repository/library_repository.dart';
import '../../../../core/repository/provider_repository.dart';
import '../../../../core/repository/read_chapters_repository.dart';
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
    final entry = _library.get(event.book.sourceId, event.book.id);
    final resume = (entry != null &&
            entry.lastChapterIndex == event.chapterIndex &&
            (entry.lastChapterProgress ?? 0) > 0 &&
            (entry.lastChapterProgress ?? 0) < 1)
        ? entry.lastChapterProgress
        : null;
    await _fetch(emit, pendingResume: resume);
  }

  Future<void> _onChapterChanged(NovelReaderChapterChanged event, Emitter<NovelReaderState> emit) async {
    if (state.book == null) return;
    final i = event.chapterIndex.clamp(0, state.book!.chapters.length - 1);
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
    // Mark chapter as read once the user scrolls past 99% of the content.
    if (event.progress >= 0.99 &&
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
