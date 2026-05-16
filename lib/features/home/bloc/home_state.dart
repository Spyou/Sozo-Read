import 'package:equatable/equatable.dart';

import '../../../core/models/book_item.dart';

enum HomeStatus { initial, loading, ready, error }

class HomeState extends Equatable {
  final HomeStatus status;
  final List<String> sourceIds;
  final String? activeSourceId;
  final List<BookItem> popular;
  final BookItem? featured;
  final bool loadingPopular;
  final String? error;

  const HomeState({
    this.status = HomeStatus.initial,
    this.sourceIds = const [],
    this.activeSourceId,
    this.popular = const [],
    this.featured,
    this.loadingPopular = false,
    this.error,
  });

  HomeState copyWith({
    HomeStatus? status,
    List<String>? sourceIds,
    String? activeSourceId,
    List<BookItem>? popular,
    BookItem? featured,
    bool clearFeatured = false,
    bool? loadingPopular,
    String? error,
    bool clearError = false,
  }) =>
      HomeState(
        status: status ?? this.status,
        sourceIds: sourceIds ?? this.sourceIds,
        activeSourceId: activeSourceId ?? this.activeSourceId,
        popular: popular ?? this.popular,
        featured: clearFeatured ? null : (featured ?? this.featured),
        loadingPopular: loadingPopular ?? this.loadingPopular,
        error: clearError ? null : (error ?? this.error),
      );

  @override
  List<Object?> get props => [
        status,
        sourceIds,
        activeSourceId,
        popular,
        featured,
        loadingPopular,
        error,
      ];
}
