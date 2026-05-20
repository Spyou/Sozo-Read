import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive/hive.dart';

import '../../../core/repository/library_repository.dart';
import 'library_event.dart';
import 'library_state.dart';

class LibraryBloc extends Bloc<LibraryEvent, LibraryState> {
  LibraryBloc({required LibraryRepository repository})
      : _repo = repository,
        super(LibraryState(
          sort: LibrarySortX.fromKey(
            Hive.isBoxOpen(_settingsBox)
                ? Hive.box(_settingsBox).get(_sortKey) as String?
                : null,
          ),
        )) {
    on<LibraryStarted>(_onStarted);
    on<LibraryTabChanged>(_onTabChanged);
    on<LibraryRemoved>(_onRemoved);
    on<LibrarySearchChanged>(_onSearchChanged);
    on<LibrarySortChanged>(_onSortChanged);
  }

  static const String _settingsBox = 'settings';
  static const String _sortKey = 'library.sort';

  final LibraryRepository _repo;
  StreamSubscription<BoxEvent>? _sub;
  Timer? _searchDebounce;
  Completer<void>? _pendingSearch;

  Future<void> _onStarted(LibraryStarted event, Emitter<LibraryState> emit) async {
    emit(state.copyWith(entries: _repo.getAll()));
    await _sub?.cancel();
    _sub = _repo.watch().listen((_) {
      add(const LibraryStarted());
    });
  }

  void _onTabChanged(LibraryTabChanged event, Emitter<LibraryState> emit) {
    // `event.status == null` selects the "All" tab — route through
    // clearTab so copyWith's `??` fallback doesn't preserve the prior
    // tab.
    emit(state.copyWith(
      tab: event.status,
      clearTab: event.status == null,
    ));
  }

  Future<void> _onRemoved(LibraryRemoved event, Emitter<LibraryState> emit) async {
    await _repo.remove(event.sourceId, event.bookId);
    emit(state.copyWith(entries: _repo.getAll()));
  }

  Future<void> _onSearchChanged(
      LibrarySearchChanged event, Emitter<LibraryState> emit) async {
    // Cancel any in-flight debounce so the prior handler exits without emitting.
    _searchDebounce?.cancel();
    final prior = _pendingSearch;
    if (prior != null && !prior.isCompleted) {
      prior.complete();
    }

    final q = event.query;
    if (q.isEmpty) {
      _pendingSearch = null;
      emit(state.copyWith(query: ''));
      return;
    }

    final completer = Completer<void>();
    _pendingSearch = completer;
    final timer = Timer(const Duration(milliseconds: 400), () {
      if (!completer.isCompleted) completer.complete();
    });
    _searchDebounce = timer;

    await completer.future;
    if (emit.isDone) return;
    // If this completer was superseded, do nothing.
    if (_pendingSearch != completer) return;
    _pendingSearch = null;
    emit(state.copyWith(query: q));
  }

  void _onSortChanged(LibrarySortChanged event, Emitter<LibraryState> emit) {
    if (Hive.isBoxOpen(_settingsBox)) {
      Hive.box(_settingsBox).put(_sortKey, event.sort.storageKey);
    }
    emit(state.copyWith(sort: event.sort));
  }

  @override
  Future<void> close() async {
    _searchDebounce?.cancel();
    await _sub?.cancel();
    return super.close();
  }
}
