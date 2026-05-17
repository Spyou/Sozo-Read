import 'package:equatable/equatable.dart';

import '../../../../core/models/book_detail.dart';

abstract class NovelReaderEvent extends Equatable {
  const NovelReaderEvent();
  @override
  List<Object?> get props => [];
}

class NovelReaderStarted extends NovelReaderEvent {
  const NovelReaderStarted({required this.book, required this.chapterIndex});
  final BookDetail book;
  final int chapterIndex;
  @override
  List<Object?> get props => [book, chapterIndex];
}

class NovelReaderChapterChanged extends NovelReaderEvent {
  const NovelReaderChapterChanged(this.chapterIndex);
  final int chapterIndex;
  @override
  List<Object?> get props => [chapterIndex];
}

class NovelReaderFontSizeChanged extends NovelReaderEvent {
  const NovelReaderFontSizeChanged(this.delta);
  final double delta;
  @override
  List<Object?> get props => [delta];
}

class NovelReaderProgressUpdated extends NovelReaderEvent {
  const NovelReaderProgressUpdated(this.progress);
  final double progress;
  @override
  List<Object?> get props => [progress];
}

class NovelReaderResumeConsumed extends NovelReaderEvent {
  const NovelReaderResumeConsumed();
}
