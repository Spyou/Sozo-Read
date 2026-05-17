import 'package:equatable/equatable.dart';

import '../../../../core/models/book_detail.dart';

enum NovelReaderStatus { idle, loading, success, error }

class NovelReaderState extends Equatable {
  final BookDetail? book;
  final int chapterIndex;
  final NovelReaderStatus status;
  final String text;
  final String? error;
  final double fontSize;
  final double progress;
  /// One-shot resume hint (0..1) for the screen to apply after pages load.
  final double? pendingResumeProgress;

  const NovelReaderState({
    this.book,
    this.chapterIndex = 0,
    this.status = NovelReaderStatus.idle,
    this.text = '',
    this.error,
    this.fontSize = 16.0,
    this.progress = 0,
    this.pendingResumeProgress,
  });

  NovelReaderState copyWith({
    BookDetail? book,
    int? chapterIndex,
    NovelReaderStatus? status,
    String? text,
    String? error,
    double? fontSize,
    double? progress,
    double? pendingResumeProgress,
    bool clearError = false,
    bool clearResume = false,
  }) =>
      NovelReaderState(
        book: book ?? this.book,
        chapterIndex: chapterIndex ?? this.chapterIndex,
        status: status ?? this.status,
        text: text ?? this.text,
        error: clearError ? null : (error ?? this.error),
        fontSize: fontSize ?? this.fontSize,
        progress: progress ?? this.progress,
        pendingResumeProgress: clearResume
            ? null
            : (pendingResumeProgress ?? this.pendingResumeProgress),
      );

  @override
  List<Object?> get props =>
      [book, chapterIndex, status, text, error, fontSize, progress, pendingResumeProgress];
}
