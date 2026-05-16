import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/models/book_item.dart';
import '../../../core/repository/provider_repository.dart';

enum GenreBrowseStatus { initial, loading, success, error }

class GenreBrowseState extends Equatable {
  const GenreBrowseState({
    this.status = GenreBrowseStatus.initial,
    this.results = const [],
    this.error,
  });

  final GenreBrowseStatus status;
  final List<BookItem> results;
  final String? error;

  GenreBrowseState copyWith({
    GenreBrowseStatus? status,
    List<BookItem>? results,
    String? error,
    bool clearError = false,
  }) =>
      GenreBrowseState(
        status: status ?? this.status,
        results: results ?? this.results,
        error: clearError ? null : (error ?? this.error),
      );

  @override
  List<Object?> get props => [status, results, error];
}

/// Single-shot async load: searches the source for the given genre name and
/// renders the result list. Pull-to-refresh re-issues the same call.
class GenreBrowseCubit extends Cubit<GenreBrowseState> {
  GenreBrowseCubit({
    required ProviderRepository repository,
    required this.sourceId,
    required this.genre,
  })  : _repo = repository,
        super(const GenreBrowseState());

  final ProviderRepository _repo;
  final String sourceId;
  final String genre;

  Future<void> load() async {
    emit(state.copyWith(status: GenreBrowseStatus.loading, clearError: true));
    final result = await _repo.search(sourceId, genre);
    result.fold(
      (f) => emit(state.copyWith(status: GenreBrowseStatus.error, error: f.message)),
      (items) => emit(state.copyWith(status: GenreBrowseStatus.success, results: items)),
    );
  }

  Future<void> refresh() => load();
}
