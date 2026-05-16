import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/models/book_item.dart';
import '../../../core/repository/library_repository.dart';
import '../../../core/repository/provider_repository.dart';
import 'detail_event.dart';
import 'detail_state.dart';

class DetailBloc extends Bloc<DetailEvent, DetailState> {
  DetailBloc({
    required ProviderRepository providerRepo,
    required LibraryRepository libraryRepo,
  })  : _provider = providerRepo,
        _library = libraryRepo,
        super(const DetailState()) {
    on<DetailLoaded>(_onLoaded);
    on<DetailReloaded>(_onReloaded);
    on<DetailLibraryToggled>(_onLibraryToggled);
    on<DetailSimilarRequested>(_onSimilarRequested);
  }

  final ProviderRepository _provider;
  final LibraryRepository _library;

  String? _sourceId;
  String? _url;

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
        emit(state.copyWith(
          status: DetailStatus.success,
          book: book,
          library: entry,
          clearLibrary: entry == null,
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

  Future<void> _onLibraryToggled(DetailLibraryToggled event, Emitter<DetailState> emit) async {
    final book = state.book;
    if (book == null) return;
    if (state.inLibrary) {
      await _library.remove(book.sourceId, book.id);
      emit(state.copyWith(clearLibrary: true));
    } else {
      final item = BookItem(
        id: book.id,
        title: book.title,
        cover: book.cover,
        url: book.url,
        type: book.type,
        sourceId: book.sourceId,
      );
      final entry = await _library.add(item);
      emit(state.copyWith(library: entry));
    }
  }
}
