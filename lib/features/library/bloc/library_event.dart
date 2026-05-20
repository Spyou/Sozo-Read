import 'package:equatable/equatable.dart';

import '../../../core/repository/library_repository.dart';
import 'library_state.dart';

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

  /// `null` selects the "All" tab — every library entry regardless of
  /// its status bucket.
  final LibraryStatus? status;
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

class LibrarySearchChanged extends LibraryEvent {
  const LibrarySearchChanged(this.query);
  final String query;
  @override
  List<Object?> get props => [query];
}

class LibrarySortChanged extends LibraryEvent {
  const LibrarySortChanged(this.sort);
  final LibrarySort sort;
  @override
  List<Object?> get props => [sort];
}
