import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/repository/provider_repository.dart';
import 'home_event.dart';
import 'home_state.dart';

/// Single-source home BLoC (Sozo-style): the user picks one source from the
/// top tab bar and the home only shows that source's content (featured hero
/// + popular list).
class HomeBloc extends Bloc<HomeEvent, HomeState> {
  HomeBloc({required ProviderRepository repository})
      : _repo = repository,
        super(const HomeState()) {
    on<HomeStarted>(_onStarted);
    on<HomeRefreshed>(_onRefreshed);
    on<HomeSourceChanged>(_onSourceChanged);
  }

  final ProviderRepository _repo;

  Future<void> _onStarted(HomeStarted event, Emitter<HomeState> emit) async {
    final ids = _repo.providers.map((p) => p.sourceId).toList();
    if (ids.isEmpty) {
      emit(state.copyWith(
        status: HomeStatus.error,
        error: 'No providers installed. Add one in Sources.',
      ));
      return;
    }
    emit(state.copyWith(
      status: HomeStatus.ready,
      sourceIds: ids,
      activeSourceId: state.activeSourceId ?? ids.first,
    ));
    await _loadPopular(emit);
  }

  Future<void> _onRefreshed(HomeRefreshed event, Emitter<HomeState> emit) => _loadPopular(emit);

  Future<void> _onSourceChanged(HomeSourceChanged event, Emitter<HomeState> emit) async {
    if (event.sourceId == state.activeSourceId) return;
    emit(state.copyWith(
      activeSourceId: event.sourceId,
      popular: const [],
      clearFeatured: true,
      clearError: true,
    ));
    await _loadPopular(emit);
  }

  Future<void> _loadPopular(Emitter<HomeState> emit) async {
    final src = state.activeSourceId;
    if (src == null) return;
    emit(state.copyWith(loadingPopular: true, clearError: true));
    try {
      final result = await _repo.search(src, '').timeout(const Duration(seconds: 25));
      result.fold(
        (failure) => emit(state.copyWith(
          loadingPopular: false,
          error: failure.message,
          popular: const [],
        )),
        (books) {
          final withCover = books.where((b) => b.cover != null && b.cover!.isNotEmpty);
          final featured = withCover.isNotEmpty
              ? withCover.first
              : (books.isNotEmpty ? books.first : null);
          emit(state.copyWith(
            loadingPopular: false,
            popular: books,
            featured: featured,
            clearFeatured: featured == null,
          ));
        },
      );
    } catch (e) {
      emit(state.copyWith(loadingPopular: false, error: e.toString(), popular: const []));
    }
  }
}
