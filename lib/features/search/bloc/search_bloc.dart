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
    on<SearchSubmitted>(_onSubmitted);
  }

  final ProviderRepository _repo;
  Timer? _debounce;
  int _runId = 0;

  void _onQueryChanged(SearchQueryChanged event, Emitter<SearchState> emit) {
    emit(state.copyWith(query: event.query));
    _debounce?.cancel();
    if (event.query.trim().isEmpty) {
      emit(state.copyWith(results: const [], status: SearchStatus.idle, clearError: true));
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

  Future<void> _onSubmitted(SearchSubmitted event, Emitter<SearchState> emit) async {
    final q = state.query.trim();
    if (q.isEmpty) return;
    final runId = ++_runId;
    emit(state.copyWith(status: SearchStatus.loading, clearError: true));

    final source = state.sourceId;
    if (source != null) {
      final result = await _repo.search(source, q);
      if (runId != _runId) return;
      result.fold(
        (f) => emit(state.copyWith(status: SearchStatus.error, error: f.message)),
        (books) => emit(state.copyWith(status: SearchStatus.success, results: books)),
      );
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
