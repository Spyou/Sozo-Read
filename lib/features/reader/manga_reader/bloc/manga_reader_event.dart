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

  @override
  List<Object?> get props => [book, chapterIndex, initialMode, initialDirection];
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
