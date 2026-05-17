import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive/hive.dart';

import '../../../core/models/book_detail.dart';
import '../../../core/models/book_item.dart';
import '../../../core/repository/library_repository.dart';
import '../../../core/repository/provider_repository.dart';
import 'home_event.dart';
import 'home_state.dart';

/// Home BLoC fetches a fixed set of three sections (Popular / Latest Updates /
/// Trending) for whatever the user has chosen as the active source.
/// Sections are fetched in parallel and emitted as they complete.
///
/// It also subscribes to LibraryRepository to surface a "Continue Reading"
/// slice (entries with 0 < lastChapterProgress < 1) that is independent of
/// the active source and refreshes live as the user reads.
class HomeBloc extends Bloc<HomeEvent, HomeState> {
  HomeBloc({
    required ProviderRepository repository,
    required LibraryRepository libraryRepository,
  })  : _repo = repository,
        _library = libraryRepository,
        super(HomeState(continueReading: _seed(libraryRepository))) {
    on<HomeStarted>(_onStarted);
    on<HomeRefreshed>(_onRefreshed);
    on<HomeSourceChanged>(_onSourceChanged);
    on<HomeLibraryChanged>(_onLibraryChanged);

    _librarySub = _library.watch().listen((_) {
      add(const HomeLibraryChanged());
    });
  }

  /// Static helper used as the initial state seed for Continue Reading so
  /// the row paints on first frame if the user already has saved books.
  ///
  /// Filter rule: any entry with status `reading` (the default), sorted by
  /// most-recently-updated first. We deliberately do NOT gate on
  /// `lastChapterProgress` — that field is null for never-opened books and
  /// exactly 1.0 right after finishing a chapter, both of which we still
  /// want surfaced as "pick this up next". Completed/on-hold/planning
  /// books are excluded — those live in their own Library tabs.
  static List<LibraryEntry> _seed(LibraryRepository lib) =>
      _filterContinueReading(lib.getAll());

  static List<LibraryEntry> _filterContinueReading(List<LibraryEntry> all) {
    final filtered = all
        .where((e) => e.status == LibraryStatus.reading)
        .toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    if (filtered.length > 12) return filtered.sublist(0, 12);
    return filtered;
  }

  final ProviderRepository _repo;
  final LibraryRepository _library;
  StreamSubscription<BoxEvent>? _librarySub;

  List<LibraryEntry> _readContinueReading() =>
      _filterContinueReading(_library.getAll());

  void _onLibraryChanged(HomeLibraryChanged event, Emitter<HomeState> emit) {
    emit(state.copyWith(continueReading: _readContinueReading()));
  }

  @override
  Future<void> close() async {
    await _librarySub?.cancel();
    return super.close();
  }

  static const _sections = <({String id, String title})>[
    (id: 'popular', title: 'Popular'),
    (id: 'latest', title: 'Latest Updates'),
    (id: 'trending', title: 'Trending'),
  ];

  Future<void> _onStarted(HomeStarted event, Emitter<HomeState> emit) async {
    if (state.sourceId != null) {
      await _load(state.sourceId!, emit);
    }
  }

  Future<void> _onRefreshed(HomeRefreshed event, Emitter<HomeState> emit) async {
    if (state.sourceId != null) await _load(state.sourceId!, emit);
  }

  Future<void> _onSourceChanged(HomeSourceChanged event, Emitter<HomeState> emit) async {
    if (event.sourceId == state.sourceId && state.sections.isNotEmpty) return;
    emit(state.copyWith(
      sourceId: event.sourceId,
      featured: const [],
      featuredDetails: const {},
      sections: const [],
    ));
    await _load(event.sourceId, emit);
  }

  Future<void> _load(String sourceId, Emitter<HomeState> emit) async {
    final placeholders = _sections
        .map((s) => HomeSection(id: s.id, title: s.title, loading: true))
        .toList();
    emit(state.copyWith(
      status: HomeStatus.loading,
      sourceId: sourceId,
      sections: placeholders,
      clearError: true,
    ));

    final current = List<HomeSection>.from(placeholders);
    final seenIds = <String>{};

    Future<void> fetch(int index) async {
      final cat = _sections[index].id;
      final result = await _repo.search(sourceId, '', category: cat);
      result.fold(
        (failure) {
          current[index] = current[index].copyWith(
            loading: false,
            error: failure.message,
          );
        },
        (books) {
          // De-dupe across earlier sections so duplicate categories (e.g. when
          // a provider can't distinguish "trending" from "popular") don't
          // re-show the same books.
          final unique = books.where((b) => !seenIds.contains(b.id)).toList();
          for (final b in unique) {
            seenIds.add(b.id);
          }
          current[index] = current[index].copyWith(loading: false, books: unique);
        },
      );
    }

    await Future.wait(List.generate(_sections.length, fetch));

    // Pick the top-N covered books (deduped by id) as carousel slides.
    const maxFeatured = 5;
    final featured = <BookItem>[];
    final seenFeatured = <String>{};
    for (final s in current) {
      for (final b in s.books) {
        if (b.cover == null || b.cover!.isEmpty) continue;
        if (seenFeatured.contains(b.id)) continue;
        seenFeatured.add(b.id);
        featured.add(b);
        if (featured.length >= maxFeatured) break;
      }
      if (featured.length >= maxFeatured) break;
    }

    final allEmpty = current.every((s) => s.books.isEmpty);

    // Prefetch detail for the FIRST featured book before revealing the home,
    // so the hero banner has status/genres/description on first paint. Other
    // slides stream in afterwards.
    var initialDetails = const <String, BookDetail>{};
    if (featured.isNotEmpty) {
      final first = featured.first;
      final firstResult = await _repo.detail(first.sourceId, first.url);
      if (state.sourceId != sourceId) return; // user switched
      initialDetails = firstResult.fold(
        (_) => const {},
        (d) => {first.id: d},
      );
    }

    emit(state.copyWith(
      status: allEmpty ? HomeStatus.empty : HomeStatus.ready,
      sections: current.where((s) => s.books.isNotEmpty || s.error != null).toList(),
      featured: featured,
      featuredDetails: initialDetails,
    ));

    // Background-fetch remaining slides; emit as each one arrives.
    final remaining = featured.skip(1);
    final futures = remaining.map((b) {
      return _repo.detail(b.sourceId, b.url).then((r) {
        if (state.sourceId != sourceId) return;
        r.fold((_) {}, (d) {
          final merged = Map<String, BookDetail>.from(state.featuredDetails);
          merged[b.id] = d;
          emit(state.copyWith(featuredDetails: merged));
        });
      });
    }).toList();
    await Future.wait(futures);
  }
}
