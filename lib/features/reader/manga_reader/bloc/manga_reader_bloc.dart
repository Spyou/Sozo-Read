import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/repository/library_repository.dart';
import '../../../../core/repository/provider_repository.dart';
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
  }

  final ProviderRepository _provider;
  final LibraryRepository _library;

  Future<void> _onStarted(MangaReaderStarted event, Emitter<MangaReaderState> emit) async {
    emit(state.copyWith(book: event.book, chapterIndex: event.chapterIndex, pageIndex: 0));
    await _fetchPages(emit);
  }

  Future<void> _onChapterChanged(MangaReaderChapterChanged event, Emitter<MangaReaderState> emit) async {
    if (state.book == null) return;
    final i = event.chapterIndex.clamp(0, state.book!.chapters.length - 1);
    emit(state.copyWith(chapterIndex: i, pageIndex: 0));
    await _fetchPages(emit);
  }

  void _onPageChanged(MangaReaderPageChanged event, Emitter<MangaReaderState> emit) {
    emit(state.copyWith(pageIndex: event.pageIndex));
    final book = state.book;
    if (book == null) return;
    if (state.pages.isEmpty) return;
    final progress = event.pageIndex / state.pages.length;
    _library.updateProgress(
      sourceId: book.sourceId,
      bookId: book.id,
      chapterIndex: state.chapterIndex,
      chapterProgress: progress,
    );
  }

  void _onModeToggled(MangaReaderModeToggled event, Emitter<MangaReaderState> emit) {
    emit(state.copyWith(
      mode: state.mode == ReaderMode.vertical ? ReaderMode.horizontal : ReaderMode.vertical,
    ));
  }

  Future<void> _fetchPages(Emitter<MangaReaderState> emit) async {
    final book = state.book;
    if (book == null || book.chapters.isEmpty) return;
    final ch = book.chapters[state.chapterIndex];
    // ignore: avoid_print
    print('[reader] getPages ${book.sourceId} chapter=${ch.title} url=${ch.url}');
    emit(state.copyWith(status: ReaderStatus.loading, clearError: true, pages: const []));
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
        ));
      },
    );
  }
}
