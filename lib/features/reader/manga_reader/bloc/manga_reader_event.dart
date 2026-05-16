import 'package:equatable/equatable.dart';

import '../../../../core/models/book_detail.dart';

abstract class MangaReaderEvent extends Equatable {
  const MangaReaderEvent();
  @override
  List<Object?> get props => [];
}

class MangaReaderStarted extends MangaReaderEvent {
  const MangaReaderStarted({required this.book, required this.chapterIndex});
  final BookDetail book;
  final int chapterIndex;
  @override
  List<Object?> get props => [book, chapterIndex];
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
