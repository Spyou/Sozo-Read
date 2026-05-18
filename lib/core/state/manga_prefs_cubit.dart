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

/// Color/tone filter applied to manga page images while reading.
enum MangaColorFilter { none, sepia, invert, blueLight }

/// Auto-scroll speed applied to vertical/webtoon reading.
enum MangaAutoScroll { off, slow, medium, fast }

/// Image quality preference. `auto` lets the reader pick based on network.
enum MangaImageQuality { auto, high, low }

/// Orientation lock preference for the manga reader screen.
enum MangaOrientationLock { auto, portrait, landscape }

/// Global manga-reader layout preferences. Persisted in the shared Hive
/// `settings` box (already opened during bootstrap by [NovelPrefsCubit]).
class MangaPrefsCubit extends Cubit<MangaPrefs> {
  MangaPrefsCubit() : super(_loadInitial());

  static const String _boxName = 'settings';
  static const String _kDirection = 'manga.reading_direction';
  static const String _kCropEdges = 'manga.crop_edges';
  static const String _kColorFilter = 'manga.color_filter';
  static const String _kAutoScroll = 'manga.auto_scroll';
  static const String _kImageQuality = 'manga.image_quality';
  static const String _kOrientationLock = 'manga.orientation_lock';
  static const String _kKeepScreenOn = 'manga.keep_screen_on';
  static const String _kTapZoneNavigation = 'manga.tap_zone_navigation';

  static const MangaReadingDirection defaultDirection =
      MangaReadingDirection.vertical;
  static const bool defaultCropEdges = false;
  static const MangaColorFilter defaultColorFilter = MangaColorFilter.none;
  static const MangaAutoScroll defaultAutoScroll = MangaAutoScroll.off;
  static const MangaImageQuality defaultImageQuality = MangaImageQuality.auto;
  static const MangaOrientationLock defaultOrientationLock =
      MangaOrientationLock.auto;
  static const bool defaultKeepScreenOn = true;
  static const bool defaultTapZoneNavigation = true;

  static Box get _box => Hive.box(_boxName);

  static MangaPrefs _loadInitial() {
    return MangaPrefs(
      readingDirection: _readDirection(_box.get(_kDirection) as String?),
      cropEdges: (_box.get(_kCropEdges) as bool?) ?? defaultCropEdges,
      colorFilter: _readColorFilter(_box.get(_kColorFilter) as String?),
      autoScroll: _readAutoScroll(_box.get(_kAutoScroll) as String?),
      imageQuality: _readImageQuality(_box.get(_kImageQuality) as String?),
      orientationLock:
          _readOrientationLock(_box.get(_kOrientationLock) as String?),
      keepScreenOn: (_box.get(_kKeepScreenOn) as bool?) ?? defaultKeepScreenOn,
      tapZoneNavigation:
          (_box.get(_kTapZoneNavigation) as bool?) ?? defaultTapZoneNavigation,
    );
  }

  static MangaReadingDirection _readDirection(String? raw) {
    if (raw == null) return defaultDirection;
    return MangaReadingDirection.values.firstWhere(
      (d) => d.name == raw,
      orElse: () => defaultDirection,
    );
  }

  static MangaColorFilter _readColorFilter(String? raw) {
    if (raw == null) return defaultColorFilter;
    return MangaColorFilter.values.firstWhere(
      (v) => v.name == raw,
      orElse: () => defaultColorFilter,
    );
  }

  static MangaAutoScroll _readAutoScroll(String? raw) {
    if (raw == null) return defaultAutoScroll;
    return MangaAutoScroll.values.firstWhere(
      (v) => v.name == raw,
      orElse: () => defaultAutoScroll,
    );
  }

  static MangaImageQuality _readImageQuality(String? raw) {
    if (raw == null) return defaultImageQuality;
    return MangaImageQuality.values.firstWhere(
      (v) => v.name == raw,
      orElse: () => defaultImageQuality,
    );
  }

  static MangaOrientationLock _readOrientationLock(String? raw) {
    if (raw == null) return defaultOrientationLock;
    return MangaOrientationLock.values.firstWhere(
      (v) => v.name == raw,
      orElse: () => defaultOrientationLock,
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

  void setCropEdges(bool v) {
    if (v == state.cropEdges) return;
    _box.put(_kCropEdges, v);
    emit(state.copyWith(cropEdges: v));
  }

  void setColorFilter(MangaColorFilter v) {
    if (v == state.colorFilter) return;
    _box.put(_kColorFilter, v.name);
    emit(state.copyWith(colorFilter: v));
  }

  void setAutoScroll(MangaAutoScroll v) {
    if (v == state.autoScroll) return;
    _box.put(_kAutoScroll, v.name);
    emit(state.copyWith(autoScroll: v));
  }

  void setImageQuality(MangaImageQuality v) {
    if (v == state.imageQuality) return;
    _box.put(_kImageQuality, v.name);
    emit(state.copyWith(imageQuality: v));
  }

  void setOrientationLock(MangaOrientationLock v) {
    if (v == state.orientationLock) return;
    _box.put(_kOrientationLock, v.name);
    emit(state.copyWith(orientationLock: v));
  }

  void setKeepScreenOn(bool v) {
    if (v == state.keepScreenOn) return;
    _box.put(_kKeepScreenOn, v);
    emit(state.copyWith(keepScreenOn: v));
  }

  void setTapZoneNavigation(bool v) {
    if (v == state.tapZoneNavigation) return;
    _box.put(_kTapZoneNavigation, v);
    emit(state.copyWith(tapZoneNavigation: v));
  }
}

class MangaPrefs extends Equatable {
  const MangaPrefs({
    required this.readingDirection,
    required this.cropEdges,
    required this.colorFilter,
    required this.autoScroll,
    required this.imageQuality,
    required this.orientationLock,
    required this.keepScreenOn,
    required this.tapZoneNavigation,
  });

  final MangaReadingDirection readingDirection;
  final bool cropEdges;
  final MangaColorFilter colorFilter;
  final MangaAutoScroll autoScroll;
  final MangaImageQuality imageQuality;
  final MangaOrientationLock orientationLock;
  final bool keepScreenOn;
  final bool tapZoneNavigation;

  MangaPrefs copyWith({
    MangaReadingDirection? readingDirection,
    bool? cropEdges,
    MangaColorFilter? colorFilter,
    MangaAutoScroll? autoScroll,
    MangaImageQuality? imageQuality,
    MangaOrientationLock? orientationLock,
    bool? keepScreenOn,
    bool? tapZoneNavigation,
  }) =>
      MangaPrefs(
        readingDirection: readingDirection ?? this.readingDirection,
        cropEdges: cropEdges ?? this.cropEdges,
        colorFilter: colorFilter ?? this.colorFilter,
        autoScroll: autoScroll ?? this.autoScroll,
        imageQuality: imageQuality ?? this.imageQuality,
        orientationLock: orientationLock ?? this.orientationLock,
        keepScreenOn: keepScreenOn ?? this.keepScreenOn,
        tapZoneNavigation: tapZoneNavigation ?? this.tapZoneNavigation,
      );

  @override
  List<Object?> get props => [
        readingDirection,
        cropEdges,
        colorFilter,
        autoScroll,
        imageQuality,
        orientationLock,
        keepScreenOn,
        tapZoneNavigation,
      ];
}
