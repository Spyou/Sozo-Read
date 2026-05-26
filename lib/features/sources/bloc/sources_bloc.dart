import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive/hive.dart';

import '../../../core/provider/provider_manager.dart';
import '../../../core/provider/provider_registry.dart';
import '../../../core/repository/provider_repository.dart';
import '../../../core/services/remote_health_service.dart';
import 'sources_event.dart';
import 'sources_state.dart';

class SourcesBloc extends Bloc<SourcesEvent, SourcesState> {
  SourcesBloc({
    required ProviderRegistry registry,
    required ProviderRepository repository,
    required RemoteHealthService remoteHealth,
  })  : _registry = registry,
        _repo = repository,
        _remoteHealth = remoteHealth,
        super(const SourcesState()) {
    on<SourcesStarted>(_onStarted);
    on<SourcesRefreshed>(_onRefreshed);
    on<SourceInstalled>(_onInstalled);
    on<SourceUninstalled>(_onUninstalled);
    on<SourceUpdated>(_onUpdated);
    on<SourceHealthReset>(_onHealthReset);
    on<SourcesRemoteHealthArrived>(_onRemoteHealthArrived);
    // Subscribe to the providers Hive box so the Installed tab refreshes
    // automatically when ANY caller changes the registry — including the
    // Repos tab's per-source install/uninstall buttons that call the
    // registry directly. Without this the Installed tab stayed in sync
    // only when the change came via a SourcesEvent.
    final box = Hive.box<Map>(ProviderRegistry.boxName);
    _boxSub = box.watch().listen((_) {
      if (!isClosed) add(const SourcesRefreshed());
    });
  }

  final ProviderRegistry _registry;
  final ProviderRepository _repo;
  final RemoteHealthService _remoteHealth;
  StreamSubscription<BoxEvent>? _boxSub;

  @override
  Future<void> close() async {
    await _boxSub?.cancel();
    return super.close();
  }

  Future<void> _onStarted(SourcesStarted event, Emitter<SourcesState> emit) => _load(emit);
  Future<void> _onRefreshed(SourcesRefreshed event, Emitter<SourcesState> emit) => _load(emit);

  Future<void> _load(Emitter<SourcesState> emit) async {
    emit(state.copyWith(status: SourcesStatus.loading, clearError: true));
    final entries = _registry.getInstalled();

    // Pull cached remote health synchronously for first paint. Background
    // refresh fires below; UI updates again when it lands.
    final cachedHealth = _remoteHealth.cached();

    final items = <SourceItem>[];
    for (final e in entries) {
      // Runtime is keyed by sourceId only — at most one (repoUrl,
      // sourceId) pair is live at a time. Match origins so a registry
      // entry for repo A doesn't flip to "loaded" when repo B's copy
      // is the live one for the same sourceId.
      final live = _repo.provider(e.name);
      final loaded = live != null && live.originRepoUrl == e.originRepoUrl;
      final provider = loaded ? live : null;
      var item = SourceItem(
        name: e.name,
        url: e.url,
        loaded: loaded,
        health: provider?.healthStatus ?? ProviderHealthStatus.healthy,
        healthError: provider?.lastError,
        repoUrl: e.originRepoUrl,
        repoDisplayName: e.displayName,
        remoteHealth: cachedHealth[e.name],
      );
      if (loaded) {
        final info = await _repo.info(e.name);
        info.fold(
          (f) => item = item.copyWith(error: f.message),
          (i) => item = item.copyWith(info: i),
        );
        // info() may have flipped health; refresh.
        item = item.copyWith(
          health: provider?.healthStatus ?? ProviderHealthStatus.healthy,
          healthError: provider?.lastError,
        );
      }
      items.add(item);
    }
    emit(state.copyWith(status: SourcesStatus.ready, items: items));

    // Background refresh — fire-and-forget. If the cache was already
    // fresh this is a no-op; otherwise we re-emit with the new data.
    unawaited(_refreshRemoteHealth());
  }

  Future<void> _refreshRemoteHealth() async {
    try {
      final fresh = await _remoteHealth.getOrRefresh();
      if (isClosed) return;
      add(SourcesRemoteHealthArrived(fresh));
    } catch (_) {
      // Network down / parse error — keep showing the cached map.
    }
  }

  Future<void> _onRemoteHealthArrived(
    SourcesRemoteHealthArrived event,
    Emitter<SourcesState> emit,
  ) async {
    final updated = state.items
        .map((s) => s.copyWith(
              remoteHealth: event.entries[s.name],
              clearRemoteHealth: event.entries[s.name] == null,
            ))
        .toList();
    emit(state.copyWith(items: updated));
  }

  Future<void> _onInstalled(SourceInstalled event, Emitter<SourcesState> emit) async {
    final result = await _repo.install(
      event.name,
      event.url,
      repoUrl: event.repoUrl,
      displayName: event.displayName,
    );
    result.fold(
      (f) => emit(state.copyWith(error: f.message)),
      (_) {},
    );
    await _load(emit);
  }

  Future<void> _onUninstalled(SourceUninstalled event, Emitter<SourcesState> emit) async {
    await _repo.uninstall(event.name, repoUrl: event.repoUrl);
    await _load(emit);
  }

  Future<void> _onUpdated(SourceUpdated event, Emitter<SourcesState> emit) async {
    // Snapshot the displayed version + name BEFORE the refresh so we
    // can tell the user whether the update actually changed anything.
    final before = _findItem(event.name);
    final beforeVersion = before?.info?.version;
    final displayName = before?.info?.name ?? event.name;

    final result = await _repo.refresh(event.name, repoUrl: event.repoUrl);
    await _load(emit);
    result.fold(
      (f) {
        emit(state.copyWith(
          notice: 'Update failed: ${f.message}',
          noticeSeq: state.noticeSeq + 1,
        ));
      },
      (_) {
        final afterVersion = _findItem(event.name)?.info?.version;
        final changed = beforeVersion != null &&
            afterVersion != null &&
            beforeVersion != afterVersion;
        final msg = changed
            ? 'Updated $displayName to v$afterVersion'
            : afterVersion != null
                ? '$displayName is up to date (v$afterVersion)'
                : '$displayName reloaded';
        emit(state.copyWith(
          notice: msg,
          noticeSeq: state.noticeSeq + 1,
        ));
      },
    );
  }

  SourceItem? _findItem(String name) {
    for (final s in state.items) {
      if (s.name == name) return s;
    }
    return null;
  }

  Future<void> _onHealthReset(
      SourceHealthReset event, Emitter<SourcesState> emit) async {
    _repo.provider(event.name)?.resetHealth();
    await _load(emit);
  }
}
