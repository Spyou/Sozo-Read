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

  const SearchState({
    this.query = '',
    this.sourceId,
    this.genre,
    this.sort = SearchSort.bestMatch,
    this.status = SearchStatus.idle,
    this.results = const [],
    this.error,
  });

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
  }) =>
      SearchState(
        query: query ?? this.query,
        sourceId: clearSourceId ? null : (sourceId ?? this.sourceId),
        genre: clearGenre ? null : (genre ?? this.genre),
        sort: sort ?? this.sort,
        status: status ?? this.status,
        results: results ?? this.results,
        error: clearError ? null : (error ?? this.error),
      );

  @override
  List<Object?> get props => [query, sourceId, genre, sort, status, results, error];
}
