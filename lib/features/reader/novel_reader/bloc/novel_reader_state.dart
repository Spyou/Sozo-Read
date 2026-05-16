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

  const NovelReaderState({
    this.book,
    this.chapterIndex = 0,
    this.status = NovelReaderStatus.idle,
    this.text = '',
    this.error,
    this.fontSize = 16.0,
    this.progress = 0,
  });

  NovelReaderState copyWith({
    BookDetail? book,
    int? chapterIndex,
    NovelReaderStatus? status,
    String? text,
    String? error,
    double? fontSize,
    double? progress,
    bool clearError = false,
  }) =>
      NovelReaderState(
        book: book ?? this.book,
        chapterIndex: chapterIndex ?? this.chapterIndex,
        status: status ?? this.status,
        text: text ?? this.text,
        error: clearError ? null : (error ?? this.error),
        fontSize: fontSize ?? this.fontSize,
        progress: progress ?? this.progress,
      );

  @override
  List<Object?> get props => [book, chapterIndex, status, text, error, fontSize, progress];
}
