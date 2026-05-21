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

  /// 0..1 — resume position requested by the library entry for the *current*
  /// pages load. Consumed once by the screen and then cleared via
  /// [MangaReaderResumeConsumed].
  final double? pendingResumeProgress;

  /// 0..1 — continuous scroll fraction for vertical/webtoon mode. Drives
  /// the smooth progress slider in the bottom bar (so manhwa with only
  /// a handful of long strips doesn't jump in big chunks per "page").
  /// Always derived from the live ScrollController; reset to 0 when a
  /// new chapter loads. Paged mode keeps this at 0 and uses pageIndex
  /// for its slider value.
  final double chapterScrollFraction;

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
    this.pendingResumeProgress,
    this.chapterScrollFraction = 0,
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
    double? pendingResumeProgress,
    double? chapterScrollFraction,
    bool clearError = false,
    bool clearResume = false,
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
        pendingResumeProgress: clearResume
            ? null
            : (pendingResumeProgress ?? this.pendingResumeProgress),
        chapterScrollFraction:
            chapterScrollFraction ?? this.chapterScrollFraction,
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
        pendingResumeProgress,
        chapterScrollFraction,
      ];
}
