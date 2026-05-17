import 'package:equatable/equatable.dart';

import 'search_state.dart';

abstract class SearchEvent extends Equatable {
  const SearchEvent();
  @override
  List<Object?> get props => [];
}

class SearchQueryChanged extends SearchEvent {
  const SearchQueryChanged(this.query);
  final String query;
  @override
  List<Object?> get props => [query];
}

class SearchSourceChanged extends SearchEvent {
  const SearchSourceChanged(this.sourceId);
  final String? sourceId;
  @override
  List<Object?> get props => [sourceId];
}

class SearchGenreChanged extends SearchEvent {
  const SearchGenreChanged(this.genre);
  final String? genre;
  @override
  List<Object?> get props => [genre];
}

class SearchSortChanged extends SearchEvent {
  const SearchSortChanged(this.sort);
  final SearchSort sort;
  @override
  List<Object?> get props => [sort];
}

class SearchSubmitted extends SearchEvent {
  const SearchSubmitted();
}
