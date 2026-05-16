import 'package:equatable/equatable.dart';

import '../../../core/repository/library_repository.dart';

class LibraryState extends Equatable {
  final List<LibraryEntry> entries;
  final LibraryStatus tab;

  const LibraryState({
    this.entries = const [],
    this.tab = LibraryStatus.reading,
  });

  LibraryState copyWith({
    List<LibraryEntry>? entries,
    LibraryStatus? tab,
  }) =>
      LibraryState(entries: entries ?? this.entries, tab: tab ?? this.tab);

  List<LibraryEntry> get filtered => entries.where((e) => e.status == tab).toList();

  @override
  List<Object?> get props => [entries, tab];
}
