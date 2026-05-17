import 'package:equatable/equatable.dart';

import '../../../core/models/book_detail.dart';
import '../../../core/models/book_item.dart';
import '../../../core/repository/library_repository.dart';

enum DetailStatus { initial, loading, success, error }

enum SimilarStatus { idle, loading, success, error }

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

  const DetailState({
    this.status = DetailStatus.initial,
    this.book,
    this.error,
    this.library,
    this.similarStatus = SimilarStatus.idle,
    this.similar = const [],
    this.readChapterIds = const {},
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
  }) =>
      DetailState(
        status: status ?? this.status,
        book: book ?? this.book,
        error: clearError ? null : (error ?? this.error),
        library: clearLibrary ? null : (library ?? this.library),
        similarStatus: similarStatus ?? this.similarStatus,
        similar: similar ?? this.similar,
        readChapterIds: readChapterIds ?? this.readChapterIds,
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
      ];
}
