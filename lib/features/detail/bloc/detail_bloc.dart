import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive/hive.dart';

import '../../../core/models/book_item.dart';
import '../../../core/repository/book_detail_cache.dart';
import '../../../core/repository/library_repository.dart';
import '../../../core/repository/provider_repository.dart';
import '../../../core/repository/read_chapters_repository.dart';
import 'detail_event.dart';
import 'detail_state.dart';

class DetailBloc extends Bloc<DetailEvent, DetailState> {
  DetailBloc({
    required ProviderRepository providerRepo,
    required LibraryRepository libraryRepo,
    required ReadChaptersRepository readChaptersRepo,
    required BookDetailCache cache,
  })  : _provider = providerRepo,
        _library = libraryRepo,
        _readChapters = readChaptersRepo,
        _cache = cache,
        super(const DetailState()) {
    on<DetailLoaded>(_onLoaded);
    on<DetailReloaded>(_onReloaded);
    on<DetailLibrarySaved>(_onLibrarySaved);
    on<DetailLibraryRemoved>(_onLibraryRemoved);
    on<DetailSimilarRequested>(_onSimilarRequested);
    on<DetailReadChaptersRefreshed>(_onReadChaptersRefreshed);
    // Watch the read-chapters Hive box so cloud pulls / external marks
    // refresh the chapter list without the user re-navigating.
    _readChaptersSub = _readChapters.watch().listen((_) {
      add(const DetailReadChaptersRefreshed());
    });
  }

  final ProviderRepository _provider;
  final LibraryRepository _library;
  final ReadChaptersRepository _readChapters;
  final BookDetailCache _cache;
  StreamSubscription<BoxEvent>? _readChaptersSub;

  String? _sourceId;
  String? _url;
  String? _bookId;

  @override
  Future<void> close() async {
    await _readChaptersSub?.cancel();
    return super.close();
  }

  Future<void> _onLoaded(DetailLoaded event, Emitter<DetailState> emit) async {
    _sourceId = event.sourceId;
    _url = event.url;
    _bookId = event.bookId;
    await _fetch(emit);
  }

  Future<void> _onReloaded(DetailReloaded event, Emitter<DetailState> emit) =>
      _fetch(emit, force: true);

  /// Stale-while-revalidate load:
  ///   1. Emit cached [BookDetail] immediately (if any) → screen renders.
  ///   2. Fire the network refresh in the same flow → emit again on success.
  /// Cache hits skip the JS-engine round trip on the first paint, which is
  /// the bulk of the detail-load latency for most sources.
  Future<void> _fetch(Emitter<DetailState> emit, {bool force = false}) async {
    if (_sourceId == null || _url == null) return;

    // Cache lookup. Requires bookId — the caller passes it from the
    // placeholder when navigating from a card; deep-link / search paths
    // skip this and just go straight to the network.
    final bookId = _bookId;
    final cached = bookId == null
        ? null
        : _cache.get(_sourceId!, bookId);

    if (cached != null) {
      // Render the cached entry NOW so the user sees content instantly.
      final entry = _library.get(cached.sourceId, cached.id);
      final reads = _readChapters.getReadChapterIds(cached.sourceId, cached.id);
      emit(state.copyWith(
        status: DetailStatus.success,
        book: cached,
        library: entry,
        clearLibrary: entry == null,
        readChapterIds: reads,
      ));
      // If the entry is fresh enough we still do a quiet background
      // refresh BELOW unless the caller forced it (pull-to-refresh).
      // For most sessions the fresh-cache path means the user never
      // sees a spinner on a re-open.
    } else {
      emit(state.copyWith(status: DetailStatus.loading, clearError: true));
    }

    // Skip the network when we already have a fresh cached entry and
    // this isn't a forced refresh. The user gets instant data and no
    // background work; pull-to-refresh on the detail screen forces a
    // refetch when they want fresh chapters.
    if (cached != null && !force && bookId != null) {
      if (_cache.isFresh(_sourceId!, bookId)) {
        // Still trigger similar-books since that wasn't cached above.
        if (cached.genres.isNotEmpty) {
          add(const DetailSimilarRequested());
        }
        return;
      }
    }

    final result = await _provider.detail(_sourceId!, _url!);
    result.fold(
      (f) {
        // If we already showed the cached entry, don't clobber it with
        // an error screen — keep the success state and let the user
        // pull-to-refresh manually. Only show error when nothing else
        // is on screen.
        if (cached != null) return;
        emit(state.copyWith(status: DetailStatus.error, error: f.message));
      },
      (book) {
        // ignore: discarded_futures
        _cache.put(book);
        final entry = _library.get(book.sourceId, book.id);
        final reads =
            _readChapters.getReadChapterIds(book.sourceId, book.id);
        emit(state.copyWith(
          status: DetailStatus.success,
          book: book,
          library: entry,
          clearLibrary: entry == null,
          readChapterIds: reads,
        ));
        // Kick off the similar-books fetch once the main detail is loaded.
        // Skipped when the source returned no genres — there's nothing to
        // query against.
        if (book.genres.isNotEmpty) {
          add(const DetailSimilarRequested());
        }
      },
    );
  }

  void _onReadChaptersRefreshed(
    DetailReadChaptersRefreshed event,
    Emitter<DetailState> emit,
  ) {
    final book = state.book;
    if (book == null) return;
    final reads = _readChapters.getReadChapterIds(book.sourceId, book.id);
    if (reads.length == state.readChapterIds.length &&
        reads.containsAll(state.readChapterIds)) {
      return; // no change → avoid a pointless rebuild
    }
    emit(state.copyWith(readChapterIds: reads));
  }

  Future<void> _onSimilarRequested(
    DetailSimilarRequested event,
    Emitter<DetailState> emit,
  ) async {
    final book = state.book;
    if (book == null || book.genres.isEmpty) return;
    final genre = book.genres.first;
    emit(state.copyWith(similarStatus: SimilarStatus.loading));
    final result = await _provider.search(book.sourceId, genre);
    result.fold(
      (f) => emit(state.copyWith(similarStatus: SimilarStatus.error)),
      (items) {
        // Filter out the current book by id and cap to 12.
        final filtered = items.where((b) => b.id != book.id).take(12).toList();
        emit(state.copyWith(
          similarStatus: SimilarStatus.success,
          similar: filtered,
        ));
      },
    );
  }

  Future<void> _onLibrarySaved(
    DetailLibrarySaved event,
    Emitter<DetailState> emit,
  ) async {
    final book = state.book;
    if (book == null) return;
    // If the book is already saved we just patch its status (keeps the
    // original addedAt + reading progress). Otherwise insert fresh.
    if (state.inLibrary) {
      final updated =
          await _library.setStatus(book.sourceId, book.id, event.status);
      if (updated != null) emit(state.copyWith(library: updated));
      return;
    }
    final item = BookItem(
      id: book.id,
      title: book.title,
      cover: book.cover,
      url: book.url,
      type: book.type,
      sourceId: book.sourceId,
    );
    final entry = await _library.add(item, status: event.status);
    emit(state.copyWith(library: entry));
  }

  Future<void> _onLibraryRemoved(
    DetailLibraryRemoved event,
    Emitter<DetailState> emit,
  ) async {
    final book = state.book;
    if (book == null) return;
    await _library.remove(book.sourceId, book.id);
    emit(state.copyWith(clearLibrary: true));
  }
}
