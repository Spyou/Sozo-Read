import 'package:equatable/equatable.dart';

import '../../../core/services/remote_health_service.dart';

abstract class SourcesEvent extends Equatable {
  const SourcesEvent();
  @override
  List<Object?> get props => [];
}

class SourcesStarted extends SourcesEvent {
  const SourcesStarted();
}

class SourcesRefreshed extends SourcesEvent {
  const SourcesRefreshed();
}

class SourceInstalled extends SourcesEvent {
  const SourceInstalled({
    required this.name,
    required this.url,
    this.repoUrl = '',
    this.displayName = '',
  });
  final String name;
  final String url;
  final String repoUrl;
  final String displayName;
  @override
  List<Object?> get props => [name, url, repoUrl, displayName];
}

class SourceUninstalled extends SourcesEvent {
  const SourceUninstalled(this.name, {this.repoUrl});
  final String name;
  final String? repoUrl;
  @override
  List<Object?> get props => [name, repoUrl];
}

class SourceUpdated extends SourcesEvent {
  const SourceUpdated(this.name, {this.repoUrl});
  final String name;
  final String? repoUrl;
  @override
  List<Object?> get props => [name, repoUrl];
}

class SourceHealthReset extends SourcesEvent {
  const SourceHealthReset(this.name);
  final String name;
  @override
  List<Object?> get props => [name];
}

/// Internal event: the background remote-health fetch finished and has
/// the freshest map. Dispatched by the bloc itself, not the UI. Carries
/// the full map keyed by sourceId so the handler can rebuild items in
/// one pass.
class SourcesRemoteHealthArrived extends SourcesEvent {
  const SourcesRemoteHealthArrived(this.entries);
  final Map<String, RemoteHealthEntry> entries;
  @override
  List<Object?> get props => [entries];
}
