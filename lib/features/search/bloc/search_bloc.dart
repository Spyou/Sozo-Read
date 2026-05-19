import 'dart:async';

import 'package:dartz/dartz.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/error/failures.dart';
import '../../../core/models/book_item.dart';
import '../../../core/repository/provider_repository.dart';
import 'search_event.dart';
import 'search_state.dart';

/// Per-source ceiling. After this, a provider's result is treated as failed
/// and the rest keep going. Tuned for cellular networks — dead hosts would
/// otherwise sit in a 60–120s TCP timeout and block the whole UI.
const _kPerSourceTimeout = Duration(seconds: 10);

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
        totalSources: 0,
        completedSources: const {},
        failedSources: const {},
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

  /// Streams results per-source instead of waiting for everyone. As each
  /// provider returns (or times out), the state is emitted again with the
  /// growing list of results so the UI shows hits the moment any source
  /// replies, instead of staring at a spinner until the slowest one resolves.
  Future<void> _onSubmitted(SearchSubmitted event, Emitter<SearchState> emit) async {
    final q = state.query.trim();
    if (q.isEmpty) return;
    final runId = ++_runId;

    final sourceIds = state.sourceId != null
        ? <String>[state.sourceId!]
        : _repo.providers.map((p) => p.sourceId).toList();
    if (sourceIds.isEmpty) {
      emit(state.copyWith(
        status: SearchStatus.error,
        error: 'No sources installed.',
      ));
      return;
    }
    final category = state.genre ?? '';

    emit(state.copyWith(
      status: SearchStatus.loading,
      results: const [],
      clearError: true,
      totalSources: sourceIds.length,
      completedSources: const {},
      failedSources: const {},
    ));

    final merged = <BookItem>[];
    final completed = <String>{};
    final failed = <String>{};
    final stream = _streamSearches(sourceIds, q, category);

    await emit.onEach<_TaggedResult>(
      stream,
      onData: (tag) {
        if (runId != _runId) return;
        completed.add(tag.sourceId);
        if (tag.result == null) {
          failed.add(tag.sourceId);
        } else {
          tag.result!.fold(
            (_) => failed.add(tag.sourceId),
            (books) => merged.addAll(books),
          );
        }
        // Promote loading → success once we have anything to show OR every
        // source has reported in. While still loading-with-no-results, only
        // bump the progress counters so the shimmer keeps showing.
        final allDone = completed.length == sourceIds.length;
        if (merged.isNotEmpty || allDone) {
          emit(state.copyWith(
            status: SearchStatus.success,
            results: List.of(merged),
            completedSources: Set.of(completed),
            failedSources: Set.of(failed),
          ));
        } else {
          emit(state.copyWith(
            completedSources: Set.of(completed),
            failedSources: Set.of(failed),
          ));
        }
      },
    );

    if (runId != _runId) return;
    // Every source failed and we have nothing to show — surface the error
    // view. If we have any results at all, leave the partial-success state
    // alone (the UI shows a small "couldn't reach: X" footer instead).
    if (merged.isEmpty && failed.length == sourceIds.length) {
      emit(state.copyWith(
        status: SearchStatus.error,
        error: failed.length == 1
            ? 'Could not reach ${failed.first}. Check your connection and try again.'
            : 'No sources could be reached. Check your connection and try again.',
      ));
    }
  }

  /// Fans out one search per source, applies a per-source timeout, and
  /// yields tagged results in completion order via a [StreamController].
  Stream<_TaggedResult> _streamSearches(
    List<String> sourceIds,
    String query,
    String category,
  ) {
    final ctrl = StreamController<_TaggedResult>();
    int remaining = sourceIds.length;
    for (final id in sourceIds) {
      // Don't await — let them race.
      // ignore: discarded_futures
      () async {
        Either<Failure, List<BookItem>>? result;
        try {
          result = await _repo
              .search(id, query, category: category)
              .timeout(_kPerSourceTimeout);
        } catch (_) {
          // TimeoutException + anything else _guard might let escape →
          // signal a null result so the bloc marks this source as failed.
        }
        if (!ctrl.isClosed) ctrl.add(_TaggedResult(id, result));
        remaining--;
        if (remaining == 0 && !ctrl.isClosed) ctrl.close();
      }();
    }
    return ctrl.stream;
  }

  @override
  Future<void> close() {
    _debounce?.cancel();
    return super.close();
  }
}

class _TaggedResult {
  const _TaggedResult(this.sourceId, this.result);
  final String sourceId;
  final Either<Failure, List<BookItem>>? result;
}
