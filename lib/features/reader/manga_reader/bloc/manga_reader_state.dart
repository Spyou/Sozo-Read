import 'package:equatable/equatable.dart';

import '../../../../core/models/book_detail.dart';
import '../../../../core/models/page_content.dart';

enum ReaderStatus { idle, loading, success, error }

enum ReaderMode { vertical, horizontal }

/// Right-to-left reading (Japanese manga). Applied to horizontal page mode.
enum ReadingDirection { ltr, rtl }

class MangaReaderState extends Equatable {
  final BookDetail? book;
  final int chapterIndex;
  final ReaderStatus status;
  final List<PageContent> pages;
  final String? error;
  final int pageIndex;
  final ReaderMode mode;
  final ReadingDirection direction;
  /// 0..1 — fraction of black overlay tinted over the pages.
  final double brightness;
  /// Loading-spinner shown while auto-advancing to the next chapter.
  final bool autoAdvancing;

  const MangaReaderState({
    this.book,
    this.chapterIndex = 0,
    this.status = ReaderStatus.idle,
    this.pages = const [],
    this.error,
    this.pageIndex = 0,
    this.mode = ReaderMode.vertical,
    this.direction = ReadingDirection.ltr,
    this.brightness = 0,
    this.autoAdvancing = false,
  });

  MangaReaderState copyWith({
    BookDetail? book,
    int? chapterIndex,
    ReaderStatus? status,
    List<PageContent>? pages,
    String? error,
    int? pageIndex,
    ReaderMode? mode,
    ReadingDirection? direction,
    double? brightness,
    bool? autoAdvancing,
    bool clearError = false,
  }) =>
      MangaReaderState(
        book: book ?? this.book,
        chapterIndex: chapterIndex ?? this.chapterIndex,
        status: status ?? this.status,
        pages: pages ?? this.pages,
        error: clearError ? null : (error ?? this.error),
        pageIndex: pageIndex ?? this.pageIndex,
        mode: mode ?? this.mode,
        direction: direction ?? this.direction,
        brightness: brightness ?? this.brightness,
        autoAdvancing: autoAdvancing ?? this.autoAdvancing,
      );

  @override
  List<Object?> get props => [
        book,
        chapterIndex,
        status,
        pages,
        error,
        pageIndex,
        mode,
        direction,
        brightness,
        autoAdvancing,
      ];
}
