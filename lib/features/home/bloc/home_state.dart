import 'package:equatable/equatable.dart';

import '../../../core/models/book_detail.dart';
import '../../../core/models/book_item.dart';
import '../../../core/repository/library_repository.dart';

enum HomeStatus { initial, loading, ready, error, empty }

class HomeSection extends Equatable {
  final String id;       // 'popular' | 'latest' | 'trending'
  final String title;    // 'Popular' | 'Latest Updates' | 'Trending'
  final List<BookItem> books;
  final bool loading;
  final String? error;

  const HomeSection({
    required this.id,
    required this.title,
    this.books = const [],
    this.loading = false,
    this.error,
  });

  HomeSection copyWith({
    List<BookItem>? books,
    bool? loading,
    String? error,
    bool clearError = false,
  }) =>
      HomeSection(
        id: id,
        title: title,
        books: books ?? this.books,
        loading: loading ?? this.loading,
        error: clearError ? null : (error ?? this.error),
      );

  @override
  List<Object?> get props => [id, title, books, loading, error];
}

class HomeState extends Equatable {
  final HomeStatus status;
  final String? sourceId;
  final List<BookItem> featured;
  // Map of bookId -> fetched detail (filled in lazily after sections load).
  final Map<String, BookDetail> featuredDetails;
  final List<HomeSection> sections;
  /// Library entries with in-progress reading (0 < progress < 1) sorted by
  /// updatedAt desc, capped at 12. Pulled from ALL sources, independent of the
  /// active source.
  final List<LibraryEntry> continueReading;
  final String? error;

  const HomeState({
    this.status = HomeStatus.initial,
    this.sourceId,
    this.featured = const [],
    this.featuredDetails = const {},
    this.sections = const [],
    this.continueReading = const [],
    this.error,
  });

  HomeState copyWith({
    HomeStatus? status,
    String? sourceId,
    bool clearSourceId = false,
    List<BookItem>? featured,
    Map<String, BookDetail>? featuredDetails,
    List<HomeSection>? sections,
    List<LibraryEntry>? continueReading,
    String? error,
    bool clearError = false,
  }) =>
      HomeState(
        status: status ?? this.status,
        sourceId: clearSourceId ? null : (sourceId ?? this.sourceId),
        featured: featured ?? this.featured,
        featuredDetails: featuredDetails ?? this.featuredDetails,
        sections: sections ?? this.sections,
        continueReading: continueReading ?? this.continueReading,
        error: clearError ? null : (error ?? this.error),
      );

  @override
  List<Object?> get props =>
      [status, sourceId, featured, featuredDetails, sections, continueReading, error];
}
