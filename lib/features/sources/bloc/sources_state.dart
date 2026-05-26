import 'package:equatable/equatable.dart';

import '../../../core/models/provider_info.dart';
import '../../../core/provider/provider_manager.dart';
import '../../../core/services/remote_health_service.dart';

class SourceItem extends Equatable {
  final String name;
  final String url;
  final bool loaded;
  final ProviderInfo? info;
  final String? error;
  final ProviderHealthStatus health;
  final String? healthError;
  final String repoUrl;
  final String repoDisplayName;
  /// CI-reported health for this source, if the providers repo has a
  /// status.json entry for it. Null when remote health hasn't loaded or
  /// the source isn't in the manifest.
  final RemoteHealthEntry? remoteHealth;

  const SourceItem({
    required this.name,
    required this.url,
    this.loaded = false,
    this.info,
    this.error,
    this.health = ProviderHealthStatus.healthy,
    this.healthError,
    this.repoUrl = '',
    this.repoDisplayName = '',
    this.remoteHealth,
  });

  SourceItem copyWith({
    bool? loaded,
    ProviderInfo? info,
    String? error,
    bool clearError = false,
    ProviderHealthStatus? health,
    String? healthError,
    String? repoUrl,
    String? repoDisplayName,
    RemoteHealthEntry? remoteHealth,
    bool clearRemoteHealth = false,
  }) =>
      SourceItem(
        name: name,
        url: url,
        loaded: loaded ?? this.loaded,
        info: info ?? this.info,
        error: clearError ? null : (error ?? this.error),
        health: health ?? this.health,
        healthError: healthError ?? this.healthError,
        repoUrl: repoUrl ?? this.repoUrl,
        repoDisplayName: repoDisplayName ?? this.repoDisplayName,
        remoteHealth:
            clearRemoteHealth ? null : (remoteHealth ?? this.remoteHealth),
      );

  /// Worst-of merge between local + remote. Local takes priority when it
  /// reports trouble — the user is hitting real failures, that's more
  /// recent than the last CI run. When local is clean, defer to the
  /// remote signal (CI noticed something the user hasn't bumped into yet).
  /// `blocked-ci` is treated as no-signal, since it doesn't reflect real
  /// user conditions.
  ProviderHealthStatus get effectiveHealth {
    if (health != ProviderHealthStatus.healthy) return health;
    final r = remoteHealth;
    if (r == null) return health;
    switch (r.status) {
      case RemoteProviderStatus.brokenParse:
      case RemoteProviderStatus.brokenHttp:
      case RemoteProviderStatus.timeout:
        return ProviderHealthStatus.broken;
      case RemoteProviderStatus.degraded:
        return ProviderHealthStatus.degraded;
      case RemoteProviderStatus.ok:
      case RemoteProviderStatus.slow:
      case RemoteProviderStatus.blockedCi:
      case RemoteProviderStatus.unknown:
        return ProviderHealthStatus.healthy;
    }
  }

  @override
  List<Object?> get props => [
        name,
        url,
        loaded,
        info,
        error,
        health,
        healthError,
        repoUrl,
        repoDisplayName,
        remoteHealth?.toJson(),
      ];
}

enum SourcesStatus { initial, loading, ready }

class SourcesState extends Equatable {
  final SourcesStatus status;
  final List<SourceItem> items;
  final String? error;
  /// Transient user-facing notice (e.g. "Updated X to v1.0.3"). Paired
  /// with [noticeSeq] so the UI's BlocListener can detect repeats — two
  /// identical messages still need to fire two snackbars, which would
  /// otherwise be deduped by Equatable.
  final String? notice;
  final int noticeSeq;

  const SourcesState({
    this.status = SourcesStatus.initial,
    this.items = const [],
    this.error,
    this.notice,
    this.noticeSeq = 0,
  });

  SourcesState copyWith({
    SourcesStatus? status,
    List<SourceItem>? items,
    String? error,
    bool clearError = false,
    String? notice,
    int? noticeSeq,
  }) =>
      SourcesState(
        status: status ?? this.status,
        items: items ?? this.items,
        error: clearError ? null : (error ?? this.error),
        notice: notice ?? this.notice,
        noticeSeq: noticeSeq ?? this.noticeSeq,
      );

  @override
  List<Object?> get props => [status, items, error, notice, noticeSeq];
}
