import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive/hive.dart';

/// Reading direction applied to the manga reader. Persisted globally so the
/// user's choice carries across sessions and chapters.
enum MangaReadingDirection {
  /// Vertical scroll (webtoon style) — the historical default.
  vertical,

  /// Horizontal pagination, left-to-right reading order (western comics).
  horizontalLtr,

  /// Horizontal pagination, right-to-left reading order (Japanese manga).
  horizontalRtl,
}

/// Global manga-reader layout preferences. Persisted in the shared Hive
/// `settings` box (already opened during bootstrap by [NovelPrefsCubit]).
class MangaPrefsCubit extends Cubit<MangaPrefs> {
  MangaPrefsCubit() : super(_loadInitial());

  static const String _boxName = 'settings';
  static const String _kDirection = 'manga.reading_direction';

  static const MangaReadingDirection defaultDirection =
      MangaReadingDirection.vertical;

  static Box get _box => Hive.box(_boxName);

  static MangaPrefs _loadInitial() {
    return MangaPrefs(
      readingDirection: _readDirection(_box.get(_kDirection) as String?),
    );
  }

  static MangaReadingDirection _readDirection(String? raw) {
    if (raw == null) return defaultDirection;
    return MangaReadingDirection.values.firstWhere(
      (d) => d.name == raw,
      orElse: () => defaultDirection,
    );
  }

  /// User-facing label for the direction picker / settings subtitle.
  static String directionLabel(MangaReadingDirection d) {
    switch (d) {
      case MangaReadingDirection.vertical:
        return 'Vertical (Webtoon)';
      case MangaReadingDirection.horizontalLtr:
        return 'Horizontal — Left to right';
      case MangaReadingDirection.horizontalRtl:
        return 'Horizontal — Right to left';
    }
  }

  void setDirection(MangaReadingDirection d) {
    if (d == state.readingDirection) return;
    _box.put(_kDirection, d.name);
    emit(state.copyWith(readingDirection: d));
  }
}

class MangaPrefs extends Equatable {
  const MangaPrefs({required this.readingDirection});

  final MangaReadingDirection readingDirection;

  MangaPrefs copyWith({MangaReadingDirection? readingDirection}) => MangaPrefs(
        readingDirection: readingDirection ?? this.readingDirection,
      );

  @override
  List<Object?> get props => [readingDirection];
}
