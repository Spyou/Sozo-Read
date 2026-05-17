import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/models/book_item.dart';
import '../../../core/repository/provider_repository.dart';
import 'search_event.dart';
import 'search_state.dart';

class SearchBloc extends Bloc<SearchEvent, SearchState> {
  SearchBloc({required ProviderRepository repository})
      : _repo = repository,
        super(const SearchState()) {
    on<SearchQueryChanged>(_onQueryChanged);
    on<SearchSourceChanged>(_onSourceChanged);
    on<SearchGenreChanged>(_onGenreChanged);
    on<SearchSortChanged>(_onSortChanged);
    on<SearchSubmitted>(_onSubmitted);
  }

  final ProviderRepository _repo;
  Timer? _debounce;
  int _runId = 0;

  void _onQueryChanged(SearchQueryChanged event, Emitter<SearchState> emit) {
    // New query resets sort back to default (per spec).
    emit(state.copyWith(query: event.query, sort: SearchSort.bestMatch));
    _debounce?.cancel();
    if (event.query.trim().isEmpty) {
      emit(state.copyWith(
        results: const [],
        status: SearchStatus.idle,
        clearError: true,
      ));
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 400), () => add(const SearchSubmitted()));
  }

  void _onSourceChanged(SearchSourceChanged event, Emitter<SearchState> emit) {
    emit(state.copyWith(
      sourceId: event.sourceId,
      clearSourceId: event.sourceId == null,
    ));
    if (state.query.trim().isNotEmpty) add(const SearchSubmitted());
  }

  void _onGenreChanged(SearchGenreChanged event, Emitter<SearchState> emit) {
    emit(state.copyWith(
      genre: event.genre,
      clearGenre: event.genre == null,
    ));
    if (state.query.trim().isNotEmpty) add(const SearchSubmitted());
  }

  void _onSortChanged(SearchSortChanged event, Emitter<SearchState> emit) {
    emit(state.copyWith(sort: event.sort));
  }

  Future<void> _onSubmitted(SearchSubmitted event, Emitter<SearchState> emit) async {
    final q = state.query.trim();
    if (q.isEmpty) return;
    final runId = ++_runId;
    emit(state.copyWith(status: SearchStatus.loading, clearError: true));

    final source = state.sourceId;
    final category = state.genre ?? '';
    if (source != null) {
      final result = await _repo.search(source, q, category: category);
      if (runId != _runId) return;
      result.fold(
        (f) => emit(state.copyWith(status: SearchStatus.error, error: f.message)),
        (books) => emit(state.copyWith(status: SearchStatus.success, results: books)),
      );
      return;
    }

    // No "All sources" overload accepts category, so reuse provider-level
    // search when a genre is active; otherwise use the aggregate helper.
    if (state.genre != null && state.genre!.isNotEmpty) {
      final merged = <BookItem>[];
      String? firstError;
      await Future.wait(_repo.providers.map((p) async {
        final r = await _repo.search(p.sourceId, q, category: category);
        r.fold(
          (f) => firstError ??= f.message,
          (books) => merged.addAll(books),
        );
      }));
      if (runId != _runId) return;
      if (merged.isEmpty && firstError != null) {
        emit(state.copyWith(status: SearchStatus.error, error: firstError));
      } else {
        emit(state.copyWith(status: SearchStatus.success, results: merged));
      }
      return;
    }

    final all = await _repo.searchAll(q);
    if (runId != _runId) return;
    final merged = <BookItem>[];
    String? firstError;
    for (final entry in all.entries) {
      entry.value.fold(
        (f) => firstError ??= f.message,
        (books) => merged.addAll(books),
      );
    }
    if (merged.isEmpty && firstError != null) {
      emit(state.copyWith(status: SearchStatus.error, error: firstError));
    } else {
      emit(state.copyWith(status: SearchStatus.success, results: merged));
    }
  }

  @override
  Future<void> close() {
    _debounce?.cancel();
    return super.close();
  }
}
