import 'package:equatable/equatable.dart';

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
