import 'package:equatable/equatable.dart';

import '../../../core/models/book_item.dart';

enum SearchStatus { idle, loading, success, error }

enum SearchSort {
  bestMatch('Best match'),
  titleAsc('Title A → Z'),
  titleDesc('Title Z → A');

  const SearchSort(this.label);
  final String label;
}

class SearchState extends Equatable {
  final String query;
  final String? sourceId; // null = search all
  final String? genre; // null = no genre filter
  final SearchSort sort;
  final SearchStatus status;
  final List<BookItem> results; // original order, as fetched
  final String? error;

  /// Total number of providers being queried for the current search run.
  /// Zero when not searching. Used by the UI to show progress.
  final int totalSources;

  /// Source IDs that have returned (either with results or with an error /
  /// timeout). Once `completedSources.length == totalSources`, the search
  /// run is fully done.
  final Set<String> completedSources;

  /// Source IDs that errored or timed out. Subset of [completedSources].
  /// Surfaced to the user as a small "couldn't reach: X" footer.
  final Set<String> failedSources;

  const SearchState({
    this.query = '',
    this.sourceId,
    this.genre,
    this.sort = SearchSort.bestMatch,
    this.status = SearchStatus.idle,
    this.results = const [],
    this.error,
    this.totalSources = 0,
    this.completedSources = const {},
    this.failedSources = const {},
  });

  /// True while the search run is still pending replies from one or more
  /// sources. The UI uses this to keep a "still searching" indicator visible
  /// underneath any partial results already shown.
  bool get isStillSearching =>
      status == SearchStatus.loading ||
      (status == SearchStatus.success &&
          totalSources > 0 &&
          completedSources.length < totalSources);

  /// Results with the current sort applied (client-side).
  List<BookItem> get sortedResults {
    switch (sort) {
      case SearchSort.bestMatch:
        return results;
      case SearchSort.titleAsc:
        final list = [...results]
          ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
        return list;
      case SearchSort.titleDesc:
        final list = [...results]
          ..sort((a, b) => b.title.toLowerCase().compareTo(a.title.toLowerCase()));
        return list;
    }
  }

  SearchState copyWith({
    String? query,
    String? sourceId,
    bool clearSourceId = false,
    String? genre,
    bool clearGenre = false,
    SearchSort? sort,
    SearchStatus? status,
    List<BookItem>? results,
    String? error,
    bool clearError = false,
    int? totalSources,
    Set<String>? completedSources,
    Set<String>? failedSources,
  }) =>
      SearchState(
        query: query ?? this.query,
        sourceId: clearSourceId ? null : (sourceId ?? this.sourceId),
        genre: clearGenre ? null : (genre ?? this.genre),
        sort: sort ?? this.sort,
        status: status ?? this.status,
        results: results ?? this.results,
        error: clearError ? null : (error ?? this.error),
        totalSources: totalSources ?? this.totalSources,
        completedSources: completedSources ?? this.completedSources,
        failedSources: failedSources ?? this.failedSources,
      );

  @override
  List<Object?> get props => [
        query,
        sourceId,
        genre,
        sort,
        status,
        results,
        error,
        totalSources,
        completedSources,
        failedSources,
      ];
}
