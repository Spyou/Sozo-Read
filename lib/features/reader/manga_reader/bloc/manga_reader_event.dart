import 'package:equatable/equatable.dart';

import '../../../../core/models/book_detail.dart';
import 'manga_reader_state.dart';

abstract class MangaReaderEvent extends Equatable {
  const MangaReaderEvent();
  @override
  List<Object?> get props => [];
}

class MangaReaderStarted extends MangaReaderEvent {
  const MangaReaderStarted({
    required this.book,
    required this.chapterIndex,
    this.initialMode,
    this.initialDirection,
    this.initialPageIndex,
  });
  final BookDetail book;
  final int chapterIndex;

  /// If provided, seeds the reader's layout mode on first load (persisted
  /// from [MangaPrefsCubit]). The in-reader settings sheet can still toggle
  /// it for a one-shot override.
  final ReaderMode? initialMode;

  /// If provided, seeds the paged-reading direction. Only meaningful when
  /// [initialMode] is [ReaderMode.horizontal].
  final ReadingDirection? initialDirection;

  /// If provided, the reader jumps to this page after the first pages-fetch
  /// completes — used when navigating from a page bookmark so the user
  /// lands on the exact page they saved, not the chapter's beginning.
  /// Overrides the library's "lastChapterProgress" resume.
  final int? initialPageIndex;

  @override
  List<Object?> get props =>
      [book, chapterIndex, initialMode, initialDirection, initialPageIndex];
}

class MangaReaderChapterChanged extends MangaReaderEvent {
  const MangaReaderChapterChanged(this.chapterIndex);
  final int chapterIndex;
  @override
  List<Object?> get props => [chapterIndex];
}

class MangaReaderPageChanged extends MangaReaderEvent {
  const MangaReaderPageChanged(this.pageIndex);
  final int pageIndex;
  @override
  List<Object?> get props => [pageIndex];
}

/// Vertical/webtoon mode emits this on every scroll update so the
/// progress slider in the bottom bar tracks the user's scroll smoothly.
/// Distinct from [MangaReaderPageChanged] — that one only fires when
/// crossing a page boundary, which is too coarse for manhwa (3-8 long
/// strips per chapter = 12-25% jumps per page).
class MangaReaderScrollFractionUpdated extends MangaReaderEvent {
  const MangaReaderScrollFractionUpdated(this.fraction);
  final double fraction;
  @override
  List<Object?> get props => [fraction];
}

class MangaReaderModeToggled extends MangaReaderEvent {
  const MangaReaderModeToggled();
}

class MangaReaderDirectionToggled extends MangaReaderEvent {
  const MangaReaderDirectionToggled();
}

class MangaReaderModeSet extends MangaReaderEvent {
  const MangaReaderModeSet(this.mode);
  final ReaderMode mode;
  @override
  List<Object?> get props => [mode];
}

class MangaReaderBrightnessChanged extends MangaReaderEvent {
  const MangaReaderBrightnessChanged(this.value);
  final double value;
  @override
  List<Object?> get props => [value];
}

/// Fired by the screen after it has scrolled to the pending resume offset, so
/// the bloc clears the one-shot resume hint.
class MangaReaderResumeConsumed extends MangaReaderEvent {
  const MangaReaderResumeConsumed();
}
