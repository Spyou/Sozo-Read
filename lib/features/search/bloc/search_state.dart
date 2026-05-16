import 'package:equatable/equatable.dart';

import '../../../core/models/book_item.dart';

enum SearchStatus { idle, loading, success, error }

class SearchState extends Equatable {
  final String query;
  final String? sourceId; // null = search all
  final SearchStatus status;
  final List<BookItem> results;
  final String? error;

  const SearchState({
    this.query = '',
    this.sourceId,
    this.status = SearchStatus.idle,
    this.results = const [],
    this.error,
  });

  SearchState copyWith({
    String? query,
    String? sourceId,
    bool clearSourceId = false,
    SearchStatus? status,
    List<BookItem>? results,
    String? error,
    bool clearError = false,
  }) =>
      SearchState(
        query: query ?? this.query,
        sourceId: clearSourceId ? null : (sourceId ?? this.sourceId),
        status: status ?? this.status,
        results: results ?? this.results,
        error: clearError ? null : (error ?? this.error),
      );

  @override
  List<Object?> get props => [query, sourceId, status, results, error];
}
