import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/repository/library_repository.dart';
import '../../../../core/repository/provider_repository.dart';
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
  }

  final ProviderRepository _provider;
  final LibraryRepository _library;

  Future<void> _onStarted(NovelReaderStarted event, Emitter<NovelReaderState> emit) async {
    emit(state.copyWith(book: event.book, chapterIndex: event.chapterIndex, progress: 0));
    await _fetch(emit);
  }

  Future<void> _onChapterChanged(NovelReaderChapterChanged event, Emitter<NovelReaderState> emit) async {
    if (state.book == null) return;
    final i = event.chapterIndex.clamp(0, state.book!.chapters.length - 1);
    emit(state.copyWith(chapterIndex: i, progress: 0));
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
  }

  Future<void> _fetch(Emitter<NovelReaderState> emit) async {
    final book = state.book;
    if (book == null || book.chapters.isEmpty) return;
    emit(state.copyWith(status: NovelReaderStatus.loading, clearError: true, text: ''));
    final ch = book.chapters[state.chapterIndex];
    final result = await _provider.novelContent(book.sourceId, ch.url);
    result.fold(
      (f) => emit(state.copyWith(status: NovelReaderStatus.error, error: f.message)),
      (c) => emit(state.copyWith(status: NovelReaderStatus.success, text: c.text)),
    );
  }
}
