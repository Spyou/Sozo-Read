import 'package:equatable/equatable.dart';

abstract class DetailEvent extends Equatable {
  const DetailEvent();
  @override
  List<Object?> get props => [];
}

class DetailLoaded extends DetailEvent {
  const DetailLoaded({required this.sourceId, required this.url});
  final String sourceId;
  final String url;
  @override
  List<Object?> get props => [sourceId, url];
}

class DetailReloaded extends DetailEvent {
  const DetailReloaded();
}

class DetailLibraryToggled extends DetailEvent {
  const DetailLibraryToggled();
}
