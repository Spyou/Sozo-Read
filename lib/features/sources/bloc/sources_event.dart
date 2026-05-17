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
  const SourceInstalled({required this.name, required this.url});
  final String name;
  final String url;
  @override
  List<Object?> get props => [name, url];
}

class SourceUninstalled extends SourcesEvent {
  const SourceUninstalled(this.name);
  final String name;
  @override
  List<Object?> get props => [name];
}

class SourceUpdated extends SourcesEvent {
  const SourceUpdated(this.name);
  final String name;
  @override
  List<Object?> get props => [name];
}

class SourceHealthReset extends SourcesEvent {
  const SourceHealthReset(this.name);
  final String name;
  @override
  List<Object?> get props => [name];
}
