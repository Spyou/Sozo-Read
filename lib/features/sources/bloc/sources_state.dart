import 'package:equatable/equatable.dart';

import '../../../core/models/provider_info.dart';

class SourceItem extends Equatable {
  final String name;
  final String url;
  final bool loaded;
  final ProviderInfo? info;
  final String? error;

  const SourceItem({
    required this.name,
    required this.url,
    this.loaded = false,
    this.info,
    this.error,
  });

  SourceItem copyWith({bool? loaded, ProviderInfo? info, String? error, bool clearError = false}) =>
      SourceItem(
        name: name,
        url: url,
        loaded: loaded ?? this.loaded,
        info: info ?? this.info,
        error: clearError ? null : (error ?? this.error),
      );

  @override
  List<Object?> get props => [name, url, loaded, info, error];
}

enum SourcesStatus { initial, loading, ready }

class SourcesState extends Equatable {
  final SourcesStatus status;
  final List<SourceItem> items;
  final String? error;

  const SourcesState({
    this.status = SourcesStatus.initial,
    this.items = const [],
    this.error,
  });

  SourcesState copyWith({
    SourcesStatus? status,
    List<SourceItem>? items,
    String? error,
    bool clearError = false,
  }) =>
      SourcesState(
        status: status ?? this.status,
        items: items ?? this.items,
        error: clearError ? null : (error ?? this.error),
      );

  @override
  List<Object?> get props => [status, items, error];
}
