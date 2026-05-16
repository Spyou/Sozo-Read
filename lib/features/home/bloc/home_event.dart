import 'package:equatable/equatable.dart';

abstract class HomeEvent extends Equatable {
  const HomeEvent();
  @override
  List<Object?> get props => [];
}

class HomeStarted extends HomeEvent {
  const HomeStarted();
}

class HomeRefreshed extends HomeEvent {
  const HomeRefreshed();
}

class HomeSourceChanged extends HomeEvent {
  const HomeSourceChanged(this.sourceId);
  final String sourceId;
  @override
  List<Object?> get props => [sourceId];
}

/// Emitted whenever the LibraryRepository changes (chapter progress write,
/// add, remove). Triggers a re-read of the "Continue Reading" slice.
class HomeLibraryChanged extends HomeEvent {
  const HomeLibraryChanged();
}
