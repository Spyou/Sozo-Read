import 'package:equatable/equatable.dart';

import '../../../core/repository/library_repository.dart';

abstract class DetailEvent extends Equatable {
  const DetailEvent();
  @override
  List<Object?> get props => [];
}

class DetailLoaded extends DetailEvent {
  const DetailLoaded({
    required this.sourceId,
    required this.url,
    this.bookId,
  });
  final String sourceId;
  final String url;

  /// Optional — passed when the caller already has the bookId on hand
  /// (typically from the placeholder [BookItem] in `extra`). Lets the
  /// bloc serve a cached [BookDetail] instantly without waiting for the
  /// network round-trip. Falls back to a cache-miss when omitted.
  final String? bookId;

  @override
  List<Object?> get props => [sourceId, url, bookId];
}

class DetailReloaded extends DetailEvent {
  const DetailReloaded();
}

/// Adds the current book to the library (or updates its status if already
/// there). The status picker in the detail screen surfaces all four
/// [LibraryStatus] values; the bloc treats them uniformly.
class DetailLibrarySaved extends DetailEvent {
  const DetailLibrarySaved(this.status);
  final LibraryStatus status;
  @override
  List<Object?> get props => [status];
}

/// Removes the current book from the library.
class DetailLibraryRemoved extends DetailEvent {
  const DetailLibraryRemoved();
}

/// Fetches "More like this" suggestions for the loaded book. Internal event —
/// emitted after the main detail load succeeds.
class DetailSimilarRequested extends DetailEvent {
  const DetailSimilarRequested();
}

/// Refresh the cached set of read chapter IDs from the local repo. Fired
/// internally whenever the read_chapters Hive box changes (local mark or
/// cloud pull).
class DetailReadChaptersRefreshed extends DetailEvent {
  const DetailReadChaptersRefreshed();
}

/// User explicitly dismissed the cross-source fallback suggestion (e.g.
/// hit Cancel on the snackbar). Clears `state.fallbackSuggestion`.
class DetailDismissFallback extends DetailEvent {
  const DetailDismissFallback();
}

/// Internal: a cross-source match was resolved (either from the cache
/// or via a fanout search). Carries the four fields needed to render
/// the snackbar suggestion. Not emitted by UI code.
class DetailFallbackResolved extends DetailEvent {
  const DetailFallbackResolved({
    required this.sourceId,
    required this.bookId,
    required this.url,
    required this.displayName,
  });

  final String sourceId;
  final String bookId;
  final String url;
  final String displayName;

  @override
  List<Object?> get props => [sourceId, bookId, url, displayName];
}
