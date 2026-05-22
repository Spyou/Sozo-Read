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

/// How a manga page sizes to the screen. `fitScreen` is the historical
/// `BoxFit.contain` behavior (whole page visible, may letterbox);
/// `fitWidth` fills the screen horizontally (taller pages overflow and
/// require pan in vertical mode this means natural webtoon scroll);
/// `fitHeight` fills vertically (mostly useful in horizontal/paged
/// mode — the reader silently falls back to `fitWidth` when the user
/// is in vertical mode since `fitHeight` inside a lazy ListView would
/// break).
enum MangaFitMode { fitWidth, fitHeight, fitScreen }

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
  static const String _kFitMode = 'manga.fit_mode';
  static const String _kOrientationLock = 'manga.orientation_lock';
  static const String _kKeepScreenOn = 'manga.keep_screen_on';
  static const String _kTapZoneNavigation = 'manga.tap_zone_navigation';
  static const String _kAutoScrollSpeed = 'manga.auto_scroll_speed';
  static const String _kShowFloatingAutoScroll =
      'manga.show_floating_auto_scroll';
  /// Per-book auto-scroll opt-in. Stored as a `List<String>` of
  /// `sourceId::bookId` keys; absent keys default to off. Replaces the
  /// historical global [_kAutoScroll] toggle so switching between books
  /// doesn't carry auto-scroll over (Blue Lock vs One Piece behave
  /// independently).
  static const String _kAutoScrollEnabledBooks =
      'manga.auto_scroll_enabled_books';
  // Downloads scope. Lives on this cubit rather than its own so we don't
  // have to wire a new BlocProvider into the settings screen — the key
  // is read directly out of the same Hive `settings` box by
  // DownloadsRepository.
  static const String _kDownloadsWifiOnly = 'downloads.wifi_only';

  static const MangaReadingDirection defaultDirection =
      MangaReadingDirection.vertical;
  static const bool defaultCropEdges = false;
  static const MangaColorFilter defaultColorFilter = MangaColorFilter.none;
  static const MangaAutoScroll defaultAutoScroll = MangaAutoScroll.off;
  static const MangaImageQuality defaultImageQuality = MangaImageQuality.auto;
  static const MangaFitMode defaultFitMode = MangaFitMode.fitScreen;
  static const MangaOrientationLock defaultOrientationLock =
      MangaOrientationLock.auto;
  static const bool defaultKeepScreenOn = true;
  static const bool defaultTapZoneNavigation = true;

  /// Continuous auto-scroll speed in `[0..1]`. 0.33 ≈ medium preset.
  /// Maps to ~15-300 px/sec in [MangaReaderBloc._applyAutoScroll].
  static const double defaultAutoScrollSpeed = 0.33;
  static const bool defaultShowFloatingAutoScroll = true;
  static const bool defaultDownloadsWifiOnly = false;

  static Box get _box => Hive.box(_boxName);

  static MangaPrefs _loadInitial() {
    return MangaPrefs(
      readingDirection: _readDirection(_box.get(_kDirection) as String?),
      cropEdges: (_box.get(_kCropEdges) as bool?) ?? defaultCropEdges,
      colorFilter: _readColorFilter(_box.get(_kColorFilter) as String?),
      autoScroll: _readAutoScroll(_box.get(_kAutoScroll) as String?),
      imageQuality: _readImageQuality(_box.get(_kImageQuality) as String?),
      fitMode: _readFitMode(_box.get(_kFitMode) as String?),
      orientationLock:
          _readOrientationLock(_box.get(_kOrientationLock) as String?),
      keepScreenOn: (_box.get(_kKeepScreenOn) as bool?) ?? defaultKeepScreenOn,
      tapZoneNavigation:
          (_box.get(_kTapZoneNavigation) as bool?) ?? defaultTapZoneNavigation,
      autoScrollSpeed: ((_box.get(_kAutoScrollSpeed) as num?)?.toDouble() ??
              defaultAutoScrollSpeed)
          .clamp(0.0, 1.0),
      showFloatingAutoScroll:
          (_box.get(_kShowFloatingAutoScroll) as bool?) ??
              defaultShowFloatingAutoScroll,
      autoScrollEnabledBooks: _readEnabledBooks(),
      downloadsWifiOnly:
          (_box.get(_kDownloadsWifiOnly) as bool?) ?? defaultDownloadsWifiOnly,
    );
  }

  static Set<String> _readEnabledBooks() {
    final raw = _box.get(_kAutoScrollEnabledBooks);
    if (raw is List) {
      return raw.whereType<String>().toSet();
    }
    return <String>{};
  }

  static String bookKey(String sourceId, String bookId) =>
      '$sourceId::$bookId';

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

  static MangaFitMode _readFitMode(String? raw) {
    if (raw == null) return defaultFitMode;
    return MangaFitMode.values.firstWhere(
      (v) => v.name == raw,
      orElse: () => defaultFitMode,
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

  void setFitMode(MangaFitMode v) {
    if (v == state.fitMode) return;
    _box.put(_kFitMode, v.name);
    emit(state.copyWith(fitMode: v));
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

  void setAutoScrollSpeed(double v) {
    final clamped = v.clamp(0.0, 1.0);
    if (clamped == state.autoScrollSpeed) return;
    _box.put(_kAutoScrollSpeed, clamped);
    emit(state.copyWith(autoScrollSpeed: clamped));
  }

  void setShowFloatingAutoScroll(bool v) {
    if (v == state.showFloatingAutoScroll) return;
    _box.put(_kShowFloatingAutoScroll, v);
    emit(state.copyWith(showFloatingAutoScroll: v));
  }

  /// True iff the user has explicitly opted this book into auto-scroll.
  /// Defaults to false — switching between books does NOT carry the
  /// toggle over.
  bool isAutoScrollEnabledForBook(String sourceId, String bookId) =>
      state.autoScrollEnabledBooks.contains(bookKey(sourceId, bookId));

  /// Toggle per-book auto-scroll. Persists immediately via Hive.
  void setAutoScrollForBook(String sourceId, String bookId, bool enabled) {
    final key = bookKey(sourceId, bookId);
    final current = state.autoScrollEnabledBooks;
    if (enabled && current.contains(key)) return;
    if (!enabled && !current.contains(key)) return;
    final next = Set<String>.from(current);
    if (enabled) {
      next.add(key);
    } else {
      next.remove(key);
    }
    _box.put(_kAutoScrollEnabledBooks, next.toList());
    emit(state.copyWith(autoScrollEnabledBooks: next));
  }

  /// Toggle the "WiFi only" gate for the downloads worker pool. Read by
  /// [DownloadsRepository] before picking up a job — when on and the
  /// current link is not WiFi, the job is flipped to `paused` with a
  /// "Waiting for WiFi" note.
  void setDownloadsWifiOnly(bool v) {
    if (v == state.downloadsWifiOnly) return;
    _box.put(_kDownloadsWifiOnly, v);
    emit(state.copyWith(downloadsWifiOnly: v));
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
    this.autoScrollSpeed = MangaPrefsCubit.defaultAutoScrollSpeed,
    this.showFloatingAutoScroll =
        MangaPrefsCubit.defaultShowFloatingAutoScroll,
    this.autoScrollEnabledBooks = const <String>{},
    this.fitMode = MangaPrefsCubit.defaultFitMode,
    this.downloadsWifiOnly = MangaPrefsCubit.defaultDownloadsWifiOnly,
  });

  final MangaReadingDirection readingDirection;
  final bool cropEdges;
  final MangaColorFilter colorFilter;
  final MangaAutoScroll autoScroll;
  final MangaImageQuality imageQuality;
  final MangaOrientationLock orientationLock;
  final bool keepScreenOn;
  final bool tapZoneNavigation;

  /// Continuous 0..1 speed for auto-scroll. The reader maps this to
  /// pixels/sec at runtime so the preset enum [autoScroll] stays usable
  /// as a coarse on/off + bucket signal for older code paths, while
  /// fine-grained tuning happens here.
  final double autoScrollSpeed;

  /// Whether the floating pause/play pill shows on the reader while
  /// auto-scroll is enabled. Default true.
  final bool showFloatingAutoScroll;

  /// Books (keyed `sourceId::bookId`) the user has explicitly opted
  /// into auto-scroll on. Absent = off. Per-book so opening a new
  /// series doesn't carry the previous one's toggle.
  final Set<String> autoScrollEnabledBooks;

  /// How manga pages size to the screen. See [MangaFitMode] for the
  /// vertical-mode fall-back behavior.
  final MangaFitMode fitMode;

  /// When true, the downloads worker pool refuses to start a chapter
  /// transfer unless the current network link is WiFi. Jobs picked up
  /// off-WiFi flip to `paused` with a "Waiting for WiFi" note and resume
  /// automatically when the link comes back. Default false.
  final bool downloadsWifiOnly;

  MangaPrefs copyWith({
    MangaReadingDirection? readingDirection,
    bool? cropEdges,
    MangaColorFilter? colorFilter,
    MangaAutoScroll? autoScroll,
    MangaImageQuality? imageQuality,
    MangaOrientationLock? orientationLock,
    bool? keepScreenOn,
    bool? tapZoneNavigation,
    double? autoScrollSpeed,
    bool? showFloatingAutoScroll,
    Set<String>? autoScrollEnabledBooks,
    MangaFitMode? fitMode,
    bool? downloadsWifiOnly,
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
        autoScrollSpeed: autoScrollSpeed ?? this.autoScrollSpeed,
        showFloatingAutoScroll:
            showFloatingAutoScroll ?? this.showFloatingAutoScroll,
        autoScrollEnabledBooks:
            autoScrollEnabledBooks ?? this.autoScrollEnabledBooks,
        fitMode: fitMode ?? this.fitMode,
        downloadsWifiOnly: downloadsWifiOnly ?? this.downloadsWifiOnly,
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
        autoScrollSpeed,
        showFloatingAutoScroll,
        autoScrollEnabledBooks,
        fitMode,
        downloadsWifiOnly,
      ];
}
