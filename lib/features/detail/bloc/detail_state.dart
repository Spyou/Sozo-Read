import 'package:equatable/equatable.dart';

import '../../../core/models/book_detail.dart';
import '../../../core/models/book_item.dart';
import '../../../core/repository/library_repository.dart';

enum DetailStatus { initial, loading, success, error }

enum SimilarStatus { idle, loading, success, error }

/// Cross-source fallback descriptor. Surfaced when the primary source's
/// detail load fails AND `AutoSwitchPrefs` is enabled AND a matching
/// entry was discovered (or cached) on another provider.
class DetailFallbackSuggestion extends Equatable {
  const DetailFallbackSuggestion({
    required this.sourceId,
    required this.bookId,
    required this.url,
    required this.displayName,
  });

  final String sourceId;
  final String bookId;
  final String url;
  final String displayName;

  @override
  List<Object?> get props => [sourceId, bookId, url, displayName];
}

class DetailState extends Equatable {
  final DetailStatus status;
  final BookDetail? book;
  final String? error;
  final LibraryEntry? library;
  final SimilarStatus similarStatus;
  final List<BookItem> similar;
  /// IDs of chapters the user has finished for the current book.
  /// Populated on load and refreshed whenever the read_chapters Hive box
  /// changes (e.g. via cloud sync).
  final Set<String> readChapterIds;

  /// Set when the primary source failed and the bloc found / had cached a
  /// matching entry on a different provider. Cleared by `DetailDismissFallback`.
  final DetailFallbackSuggestion? fallbackSuggestion;

  const DetailState({
    this.status = DetailStatus.initial,
    this.book,
    this.error,
    this.library,
    this.similarStatus = SimilarStatus.idle,
    this.similar = const [],
    this.readChapterIds = const {},
    this.fallbackSuggestion,
  });

  bool get inLibrary => library != null;

  DetailState copyWith({
    DetailStatus? status,
    BookDetail? book,
    String? error,
    LibraryEntry? library,
    bool clearLibrary = false,
    bool clearError = false,
    SimilarStatus? similarStatus,
    List<BookItem>? similar,
    Set<String>? readChapterIds,
    DetailFallbackSuggestion? fallbackSuggestion,
    bool clearFallback = false,
  }) =>
      DetailState(
        status: status ?? this.status,
        book: book ?? this.book,
        error: clearError ? null : (error ?? this.error),
        library: clearLibrary ? null : (library ?? this.library),
        similarStatus: similarStatus ?? this.similarStatus,
        similar: similar ?? this.similar,
        readChapterIds: readChapterIds ?? this.readChapterIds,
        fallbackSuggestion:
            clearFallback ? null : (fallbackSuggestion ?? this.fallbackSuggestion),
      );

  @override
  List<Object?> get props => [
        status,
        book,
        error,
        library,
        similarStatus,
        similar,
        readChapterIds,
        fallbackSuggestion,
      ];
}
