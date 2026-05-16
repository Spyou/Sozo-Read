import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive/hive.dart';

import '../../../core/repository/library_repository.dart';
import 'library_event.dart';
import 'library_state.dart';

class LibraryBloc extends Bloc<LibraryEvent, LibraryState> {
  LibraryBloc({required LibraryRepository repository})
      : _repo = repository,
        super(const LibraryState()) {
    on<LibraryStarted>(_onStarted);
    on<LibraryTabChanged>(_onTabChanged);
    on<LibraryRemoved>(_onRemoved);
  }

  final LibraryRepository _repo;
  StreamSubscription<BoxEvent>? _sub;

  Future<void> _onStarted(LibraryStarted event, Emitter<LibraryState> emit) async {
    emit(state.copyWith(entries: _repo.getAll()));
    await _sub?.cancel();
    _sub = _repo.watch().listen((_) {
      add(const LibraryStarted());
    });
  }

  void _onTabChanged(LibraryTabChanged event, Emitter<LibraryState> emit) {
    emit(state.copyWith(tab: event.status));
  }

  Future<void> _onRemoved(LibraryRemoved event, Emitter<LibraryState> emit) async {
    await _repo.remove(event.sourceId, event.bookId);
    emit(state.copyWith(entries: _repo.getAll()));
  }

  @override
  Future<void> close() async {
    await _sub?.cancel();
    return super.close();
  }
}
