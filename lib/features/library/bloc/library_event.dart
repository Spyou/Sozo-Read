import 'package:equatable/equatable.dart';

import '../../../core/repository/library_repository.dart';

abstract class LibraryEvent extends Equatable {
  const LibraryEvent();
  @override
  List<Object?> get props => [];
}

class LibraryStarted extends LibraryEvent {
  const LibraryStarted();
}

class LibraryTabChanged extends LibraryEvent {
  const LibraryTabChanged(this.status);
  final LibraryStatus status;
  @override
  List<Object?> get props => [status];
}

class LibraryRemoved extends LibraryEvent {
  const LibraryRemoved({required this.sourceId, required this.bookId});
  final String sourceId;
  final String bookId;
  @override
  List<Object?> get props => [sourceId, bookId];
}
