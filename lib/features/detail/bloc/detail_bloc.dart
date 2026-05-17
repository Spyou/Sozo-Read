import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive/hive.dart';

import '../../../core/models/book_item.dart';
import '../../../core/repository/library_repository.dart';
import '../../../core/repository/provider_repository.dart';
import '../../../core/repository/read_chapters_repository.dart';
import 'detail_event.dart';
import 'detail_state.dart';

class DetailBloc extends Bloc<DetailEvent, DetailState> {
  DetailBloc({
    required ProviderRepository providerRepo,
    required LibraryRepository libraryRepo,
    required ReadChaptersRepository readChaptersRepo,
  })  : _provider = providerRepo,
        _library = libraryRepo,
        _readChapters = readChaptersRepo,
        super(const DetailState()) {
    on<DetailLoaded>(_onLoaded);
    on<DetailReloaded>(_onReloaded);
    on<DetailLibrarySaved>(_onLibrarySaved);
    on<DetailLibraryRemoved>(_onLibraryRemoved);
    on<DetailSimilarRequested>(_onSimilarRequested);
    on<DetailReadChaptersRefreshed>(_onReadChaptersRefreshed);
    // Watch the read-chapters Hive box so cloud pulls / external marks
    // refresh the chapter list without the user re-navigating.
    _readChaptersSub = _readChapters.watch().listen((_) {
      add(const DetailReadChaptersRefreshed());
    });
  }

  final ProviderRepository _provider;
  final LibraryRepository _library;
  final ReadChaptersRepository _readChapters;
  StreamSubscription<BoxEvent>? _readChaptersSub;

  String? _sourceId;
  String? _url;

  @override
  Future<void> close() async {
    await _readChaptersSub?.cancel();
    return super.close();
  }

  Future<void> _onLoaded(DetailLoaded event, Emitter<DetailState> emit) async {
    _sourceId = event.sourceId;
    _url = event.url;
    await _fetch(emit);
  }

  Future<void> _onReloaded(DetailReloaded event, Emitter<DetailState> emit) => _fetch(emit);

  Future<void> _fetch(Emitter<DetailState> emit) async {
    if (_sourceId == null || _url == null) return;
    emit(state.copyWith(status: DetailStatus.loading, clearError: true));
    final result = await _provider.detail(_sourceId!, _url!);
    result.fold(
      (f) => emit(state.copyWith(status: DetailStatus.error, error: f.message)),
      (book) {
        final entry = _library.get(book.sourceId, book.id);
        final reads =
            _readChapters.getReadChapterIds(book.sourceId, book.id);
        emit(state.copyWith(
          status: DetailStatus.success,
          book: book,
          library: entry,
          clearLibrary: entry == null,
          readChapterIds: reads,
        ));
        // Kick off the similar-books fetch once the main detail is loaded.
        // Skipped when the source returned no genres — there's nothing to
        // query against.
        if (book.genres.isNotEmpty) {
          add(const DetailSimilarRequested());
        }
      },
    );
  }

  void _onReadChaptersRefreshed(
    DetailReadChaptersRefreshed event,
    Emitter<DetailState> emit,
  ) {
    final book = state.book;
    if (book == null) return;
    final reads = _readChapters.getReadChapterIds(book.sourceId, book.id);
    if (reads.length == state.readChapterIds.length &&
        reads.containsAll(state.readChapterIds)) {
      return; // no change → avoid a pointless rebuild
    }
    emit(state.copyWith(readChapterIds: reads));
  }

  Future<void> _onSimilarRequested(
    DetailSimilarRequested event,
    Emitter<DetailState> emit,
  ) async {
    final book = state.book;
    if (book == null || book.genres.isEmpty) return;
    final genre = book.genres.first;
    emit(state.copyWith(similarStatus: SimilarStatus.loading));
    final result = await _provider.search(book.sourceId, genre);
    result.fold(
      (f) => emit(state.copyWith(similarStatus: SimilarStatus.error)),
      (items) {
        // Filter out the current book by id and cap to 12.
        final filtered = items.where((b) => b.id != book.id).take(12).toList();
        emit(state.copyWith(
          similarStatus: SimilarStatus.success,
          similar: filtered,
        ));
      },
    );
  }

  Future<void> _onLibrarySaved(
    DetailLibrarySaved event,
    Emitter<DetailState> emit,
  ) async {
    final book = state.book;
    if (book == null) return;
    // If the book is already saved we just patch its status (keeps the
    // original addedAt + reading progress). Otherwise insert fresh.
    if (state.inLibrary) {
      final updated =
          await _library.setStatus(book.sourceId, book.id, event.status);
      if (updated != null) emit(state.copyWith(library: updated));
      return;
    }
    final item = BookItem(
      id: book.id,
      title: book.title,
      cover: book.cover,
      url: book.url,
      type: book.type,
      sourceId: book.sourceId,
    );
    final entry = await _library.add(item, status: event.status);
    emit(state.copyWith(library: entry));
  }

  Future<void> _onLibraryRemoved(
    DetailLibraryRemoved event,
    Emitter<DetailState> emit,
  ) async {
    final book = state.book;
    if (book == null) return;
    await _library.remove(book.sourceId, book.id);
    emit(state.copyWith(clearLibrary: true));
  }
}
