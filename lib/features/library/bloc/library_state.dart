import 'package:equatable/equatable.dart';

import '../../../core/repository/library_repository.dart';

enum LibrarySort {
  recentlyUpdated,
  recentlyAdded,
  titleAsc,
  titleDesc,
  progress,
}

extension LibrarySortX on LibrarySort {
  String get label {
    switch (this) {
      case LibrarySort.recentlyUpdated:
        return 'Recently updated';
      case LibrarySort.recentlyAdded:
        return 'Recently added';
      case LibrarySort.titleAsc:
        return 'Title A-Z';
      case LibrarySort.titleDesc:
        return 'Title Z-A';
      case LibrarySort.progress:
        return 'Reading progress';
    }
  }

  String get storageKey {
    switch (this) {
      case LibrarySort.recentlyUpdated:
        return 'recentlyUpdated';
      case LibrarySort.recentlyAdded:
        return 'recentlyAdded';
      case LibrarySort.titleAsc:
        return 'titleAsc';
      case LibrarySort.titleDesc:
        return 'titleDesc';
      case LibrarySort.progress:
        return 'progress';
    }
  }

  static LibrarySort fromKey(String? key) {
    for (final s in LibrarySort.values) {
      if (s.storageKey == key) return s;
    }
    return LibrarySort.recentlyUpdated;
  }
}

class LibraryState extends Equatable {
  final List<LibraryEntry> entries;
  final LibraryStatus tab;
  final String query;
  final LibrarySort sort;

  const LibraryState({
    this.entries = const [],
    this.tab = LibraryStatus.reading,
    this.query = '',
    this.sort = LibrarySort.recentlyUpdated,
  });

  LibraryState copyWith({
    List<LibraryEntry>? entries,
    LibraryStatus? tab,
    String? query,
    LibrarySort? sort,
  }) =>
      LibraryState(
        entries: entries ?? this.entries,
        tab: tab ?? this.tab,
        query: query ?? this.query,
        sort: sort ?? this.sort,
      );

  List<LibraryEntry> get filtered {
    final q = query.trim().toLowerCase();
    final base = entries.where((e) {
      if (e.status != tab) return false;
      if (q.isEmpty) return true;
      return e.book.title.toLowerCase().contains(q);
    }).toList();

    int progressScore(LibraryEntry e) {
      // Combine chapter index and per-chapter progress into one comparable score.
      final p = (e.lastChapterProgress ?? 0).clamp(0.0, 1.0);
      return (e.lastChapterIndex * 1000) + (p * 1000).round();
    }

    switch (sort) {
      case LibrarySort.recentlyUpdated:
        base.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        break;
      case LibrarySort.recentlyAdded:
        base.sort((a, b) => b.addedAt.compareTo(a.addedAt));
        break;
      case LibrarySort.titleAsc:
        base.sort((a, b) =>
            a.book.title.toLowerCase().compareTo(b.book.title.toLowerCase()));
        break;
      case LibrarySort.titleDesc:
        base.sort((a, b) =>
            b.book.title.toLowerCase().compareTo(a.book.title.toLowerCase()));
        break;
      case LibrarySort.progress:
        base.sort((a, b) => progressScore(b).compareTo(progressScore(a)));
        break;
    }
    return base;
  }

  @override
  List<Object?> get props => [entries, tab, query, sort];
}
