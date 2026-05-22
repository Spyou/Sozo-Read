import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive/hive.dart';

/// Reading background mode applied to the manga (vertical) and novel readers.
enum ReadingBgMode { system, white, sepia, black }

/// Global novel-reader typography preferences. Persisted in the shared
/// Hive `settings` box.
class NovelPrefsCubit extends Cubit<NovelPrefs> {
  NovelPrefsCubit() : super(_loadInitial());

  static const String _boxName = 'settings';
  static const String _kFontSize = 'novel.fontSize';
  static const String _kLineHeight = 'novel.lineHeight';
  static const String _kMargin = 'novel.horizontalMargin';
  static const String _kFontFamily = 'novel.fontFamily';
  static const String _kBg = 'novel.bg';
  /// Per-book background override. Stored as a `Map<String,String>` of
  /// `sourceId::bookId` → `ReadingBgMode.name`. Absent keys fall back to
  /// the global [_kBg].
  static const String _kPerBookBg = 'novel.per_book_bg';
  /// Per-book font override. Stored as a `Map<String,String>` of
  /// `sourceId::bookId` → font label (must be in [familyOptions]).
  static const String _kPerBookFontFamily = 'novel.per_book_font_family';
  /// Auto-scroll opt-in set + speed slider + floating-control
  /// visibility. Mirrors the manga reader's pattern. Speed is global,
  /// per-book on/off, floating control is global.
  static const String _kAutoScrollEnabledBooks =
      'novel.auto_scroll_enabled_books';
  static const String _kAutoScrollSpeed = 'novel.auto_scroll_speed';
  static const String _kShowFloatingAutoScroll =
      'novel.show_floating_auto_scroll';
  static const String _kVolumeButtons = 'reader.volume_buttons';
  /// Text-to-Speech voice rate. Mirrors the `autoScrollSpeed` pattern —
  /// a 0..1 continuous value, persisted in the shared settings box.
  static const String _kTtsRate = 'novel.tts_rate';
  static const String _kTtsLanguage = 'novel.tts_language';
  static const String _kTtsVoiceName = 'novel.tts_voice_name';
  static const String _kTtsPitch = 'novel.tts_pitch';
  static const String _kTtsVolume = 'novel.tts_volume';
  static const String _kTtsStopAtChapterEnd = 'novel.tts_stop_at_chapter_end';
  static const String _kTtsSkipMarkers = 'novel.tts_skip_markers';
  static const String _kTtsParagraphPauseMs = 'novel.tts_paragraph_pause_ms';
  static const String _kTtsPronunciations = 'novel.tts_pronunciations';
  static const String _kPerBookTtsVoice = 'novel.per_book_tts_voice';
  static const String _kPerBookTtsRate = 'novel.per_book_tts_rate';

  static const double defaultFontSize = 16;
  static const double defaultLineHeight = 1.65;
  static const double defaultMargin = 20;
  static const String defaultFontFamily = 'System';
  static const ReadingBgMode defaultBackgroundMode = ReadingBgMode.system;
  static const bool defaultUseVolumeButtons = true;
  /// Auto-scroll speed in `[0..1]`. Mapped to px/sec at runtime
  /// (novels are slower than manga panels — see the reader).
  static const double defaultAutoScrollSpeed = 0.33;
  static const bool defaultShowFloatingAutoScroll = true;
  /// Default TTS voice rate. The flutter_tts plugin maps 0..1 onto the
  /// native engine's range; 0.5 sounds natural on Android + iOS.
  static const double defaultTtsRate = 0.5;
  static const String defaultTtsLanguage = 'en-US';
  static const double defaultTtsPitch = 1.0;
  static const double defaultTtsVolume = 1.0;
  static const bool defaultTtsStopAtChapterEnd = false;
  static const bool defaultTtsSkipMarkers = true;
  static const int defaultTtsParagraphPauseMs = 300;

  /// Available font-family labels shown in the picker. System families
  /// come first (they're free — no download); the Google Fonts entries
  /// fetch on first use and cache to disk thereafter. Stored in the
  /// `fontFamily` field by label.
  static const List<String> familyOptions = [
    'System',
    'Serif',
    'Sans-serif',
    'Monospace',
    // Google Fonts — readable serifs and sans-serifs commonly used
    // for long-form reading. Add more here as needed; the resolver
    // matches by label.
    'Inter',
    'Lora',
    'Merriweather',
    'Source Sans 3',
    'EB Garamond',
    'Noto Sans',
    'Noto Serif',
    'Roboto Mono',
  ];

  /// Google-Font labels (must match a `GoogleFonts.<method>()` name).
  static const Set<String> _googleFontLabels = {
    'Inter',
    'Lora',
    'Merriweather',
    'Source Sans 3',
    'EB Garamond',
    'Noto Sans',
    'Noto Serif',
    'Roboto Mono',
  };

  /// Resolves a font label into a [TextStyle] applied on top of [base].
  /// System labels return the base with a `fontFamily:` override; Google
  /// Font labels return `GoogleFonts.getFont(...)` which downloads the
  /// font on first use and caches it locally.
  static TextStyle applyFontLabel(String label, TextStyle base) {
    if (_googleFontLabels.contains(label)) {
      try {
        return GoogleFonts.getFont(label, textStyle: base);
      } catch (_) {
        return base;
      }
    }
    switch (label) {
      case 'Serif':
        return base.copyWith(fontFamily: 'serif');
      case 'Sans-serif':
        return base.copyWith(fontFamily: 'sans-serif');
      case 'Monospace':
        return base.copyWith(fontFamily: 'monospace');
      case 'System':
      default:
        return base;
    }
  }

  /// Returns the effective font label for a given book: per-book
  /// override if set, else the global default.
  String resolveFontFor(String sourceId, String bookId) {
    final override = state.perBookFontFamily[bookKey(sourceId, bookId)];
    return override ?? state.fontFamily;
  }

  /// Set or clear the per-book font override. Pass `null` to drop the
  /// override and fall back to the global font.
  void setFontForBook(String sourceId, String bookId, String? label) {
    if (label != null && !familyOptions.contains(label)) return;
    final key = bookKey(sourceId, bookId);
    final next = Map<String, String>.from(state.perBookFontFamily);
    if (label == null) {
      if (!next.containsKey(key)) return;
      next.remove(key);
    } else {
      if (next[key] == label) return;
      next[key] = label;
    }
    _box.put(_kPerBookFontFamily, next);
    emit(state.copyWith(perBookFontFamily: next));
  }

  static Box get _box => Hive.box(_boxName);

  static String bookKey(String sourceId, String bookId) =>
      '$sourceId::$bookId';

  static NovelPrefs _loadInitial() {
    return NovelPrefs(
      fontSize: (_box.get(_kFontSize) as num?)?.toDouble() ?? defaultFontSize,
      lineHeight: (_box.get(_kLineHeight) as num?)?.toDouble() ?? defaultLineHeight,
      horizontalMargin:
          (_box.get(_kMargin) as num?)?.toDouble() ?? defaultMargin,
      fontFamily: (_box.get(_kFontFamily) as String?) ?? defaultFontFamily,
      backgroundMode: _readBg(_box.get(_kBg) as String?),
      perBookBackgroundMode: _readPerBookBg(),
      perBookFontFamily: _readPerBookFont(),
      autoScrollEnabledBooks: _readAutoScrollEnabledBooks(),
      autoScrollSpeed:
          ((_box.get(_kAutoScrollSpeed) as num?)?.toDouble() ??
                  defaultAutoScrollSpeed)
              .clamp(0.0, 1.0),
      showFloatingAutoScroll:
          (_box.get(_kShowFloatingAutoScroll) as bool?) ??
              defaultShowFloatingAutoScroll,
      useVolumeButtons:
          (_box.get(_kVolumeButtons) as bool?) ?? defaultUseVolumeButtons,
      ttsRate: ((_box.get(_kTtsRate) as num?)?.toDouble() ?? defaultTtsRate)
          .clamp(0.0, 1.0),
      ttsLanguage:
          (_box.get(_kTtsLanguage) as String?) ?? defaultTtsLanguage,
      ttsVoiceName: _box.get(_kTtsVoiceName) as String?,
      ttsPitch:
          ((_box.get(_kTtsPitch) as num?)?.toDouble() ?? defaultTtsPitch)
              .clamp(0.5, 2.0),
      ttsVolume:
          ((_box.get(_kTtsVolume) as num?)?.toDouble() ?? defaultTtsVolume)
              .clamp(0.0, 1.0),
      ttsStopAtChapterEnd:
          (_box.get(_kTtsStopAtChapterEnd) as bool?) ??
              defaultTtsStopAtChapterEnd,
      ttsSkipMarkers:
          (_box.get(_kTtsSkipMarkers) as bool?) ?? defaultTtsSkipMarkers,
      ttsParagraphPauseMs:
          ((_box.get(_kTtsParagraphPauseMs) as num?)?.toInt() ??
                  defaultTtsParagraphPauseMs)
              .clamp(0, 2000),
      ttsPronunciations: _readTtsPronunciations(),
      perBookTtsVoice: _readPerBookTtsVoice(),
      perBookTtsRate: _readPerBookTtsRate(),
    );
  }

  static Map<String, String> _readTtsPronunciations() {
    final raw = _box.get(_kTtsPronunciations);
    if (raw is Map) {
      return raw.map(
        (k, v) => MapEntry(k.toString().toLowerCase(), v.toString()),
      );
    }
    return const <String, String>{};
  }

  static Map<String, String> _readPerBookTtsVoice() {
    final raw = _box.get(_kPerBookTtsVoice);
    if (raw is Map) {
      return raw.map((k, v) => MapEntry(k.toString(), v.toString()));
    }
    return const <String, String>{};
  }

  static Map<String, double> _readPerBookTtsRate() {
    final raw = _box.get(_kPerBookTtsRate);
    if (raw is Map) {
      final out = <String, double>{};
      raw.forEach((k, v) {
        if (v is num) out[k.toString()] = v.toDouble().clamp(0.0, 1.0);
      });
      return out;
    }
    return const <String, double>{};
  }

  static Map<String, String> _readPerBookBg() {
    final raw = _box.get(_kPerBookBg);
    if (raw is Map) {
      return raw.map(
        (k, v) => MapEntry(k.toString(), v.toString()),
      );
    }
    return const <String, String>{};
  }

  static Map<String, String> _readPerBookFont() {
    final raw = _box.get(_kPerBookFontFamily);
    if (raw is Map) {
      return raw.map(
        (k, v) => MapEntry(k.toString(), v.toString()),
      );
    }
    return const <String, String>{};
  }

  static Set<String> _readAutoScrollEnabledBooks() {
    final raw = _box.get(_kAutoScrollEnabledBooks);
    if (raw is List) return raw.whereType<String>().toSet();
    return <String>{};
  }

  static ReadingBgMode _readBg(String? raw) {
    if (raw == null) return defaultBackgroundMode;
    return ReadingBgMode.values.firstWhere(
      (m) => m.name == raw,
      orElse: () => defaultBackgroundMode,
    );
  }

  void setFontSize(double v) {
    final clamped = v.clamp(12.0, 28.0);
    _box.put(_kFontSize, clamped);
    emit(state.copyWith(fontSize: clamped));
  }

  void bumpFontSize(double delta) => setFontSize(state.fontSize + delta);

  void setLineHeight(double v) {
    final clamped = v.clamp(1.0, 2.5);
    _box.put(_kLineHeight, clamped);
    emit(state.copyWith(lineHeight: clamped));
  }

  void setMargin(double v) {
    final clamped = v.clamp(8.0, 40.0);
    _box.put(_kMargin, clamped);
    emit(state.copyWith(horizontalMargin: clamped));
  }

  void setFontFamily(String label) {
    if (!familyOptions.contains(label)) return;
    if (label == state.fontFamily) return;
    _box.put(_kFontFamily, label);
    emit(state.copyWith(fontFamily: label));
  }

  void setBackgroundMode(ReadingBgMode mode) {
    _box.put(_kBg, mode.name);
    emit(state.copyWith(backgroundMode: mode));
  }

  /// Resolve the effective background for a given book: per-book
  /// override if the user set one, else the global default.
  ReadingBgMode resolveBackgroundFor(String sourceId, String bookId) {
    final override = state.perBookBackgroundMode[bookKey(sourceId, bookId)];
    if (override == null) return state.backgroundMode;
    return ReadingBgMode.values.firstWhere(
      (m) => m.name == override,
      orElse: () => state.backgroundMode,
    );
  }

  /// Set or clear the per-book background override. Pass `null` to drop
  /// the override and fall back to the global mode.
  void setBackgroundForBook(
    String sourceId,
    String bookId,
    ReadingBgMode? mode,
  ) {
    final key = bookKey(sourceId, bookId);
    final next = Map<String, String>.from(state.perBookBackgroundMode);
    if (mode == null) {
      if (!next.containsKey(key)) return;
      next.remove(key);
    } else {
      if (next[key] == mode.name) return;
      next[key] = mode.name;
    }
    _box.put(_kPerBookBg, next);
    emit(state.copyWith(perBookBackgroundMode: next));
  }

  void setUseVolumeButtons(bool v) {
    _box.put(_kVolumeButtons, v);
    emit(state.copyWith(useVolumeButtons: v));
  }

  bool isAutoScrollEnabledFor(String sourceId, String bookId) =>
      state.autoScrollEnabledBooks.contains(bookKey(sourceId, bookId));

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

  void setTtsRate(double v) {
    final clamped = v.clamp(0.0, 1.0);
    if (clamped == state.ttsRate) return;
    _box.put(_kTtsRate, clamped);
    emit(state.copyWith(ttsRate: clamped));
  }

  void setTtsLanguage(String code) {
    if (code.isEmpty) return;
    if (code == state.ttsLanguage) return;
    _box.put(_kTtsLanguage, code);
    emit(state.copyWith(ttsLanguage: code));
  }

  void setTtsVoiceName(String? name) {
    if (name == state.ttsVoiceName) return;
    if (name == null) {
      _box.delete(_kTtsVoiceName);
    } else {
      _box.put(_kTtsVoiceName, name);
    }
    emit(state.copyWith(ttsVoiceName: name, clearTtsVoiceName: name == null));
  }

  void setTtsPitch(double v) {
    final clamped = v.clamp(0.5, 2.0);
    if (clamped == state.ttsPitch) return;
    _box.put(_kTtsPitch, clamped);
    emit(state.copyWith(ttsPitch: clamped));
  }

  void setTtsVolume(double v) {
    final clamped = v.clamp(0.0, 1.0);
    if (clamped == state.ttsVolume) return;
    _box.put(_kTtsVolume, clamped);
    emit(state.copyWith(ttsVolume: clamped));
  }

  void setTtsStopAtChapterEnd(bool v) {
    if (v == state.ttsStopAtChapterEnd) return;
    _box.put(_kTtsStopAtChapterEnd, v);
    emit(state.copyWith(ttsStopAtChapterEnd: v));
  }

  void setTtsSkipMarkers(bool v) {
    if (v == state.ttsSkipMarkers) return;
    _box.put(_kTtsSkipMarkers, v);
    emit(state.copyWith(ttsSkipMarkers: v));
  }

  void setTtsParagraphPauseMs(int ms) {
    final clamped = ms.clamp(0, 2000);
    if (clamped == state.ttsParagraphPauseMs) return;
    _box.put(_kTtsParagraphPauseMs, clamped);
    emit(state.copyWith(ttsParagraphPauseMs: clamped));
  }

  void setTtsPronunciations(Map<String, String> map) {
    // Always store keys lowercase so lookup at speak-time is a simple
    // direct-map get rather than a per-paragraph iteration over keys.
    final normalized = <String, String>{
      for (final e in map.entries) e.key.toLowerCase(): e.value,
    };
    _box.put(_kTtsPronunciations, normalized);
    emit(state.copyWith(ttsPronunciations: normalized));
  }

  void setTtsPronunciation(String original, String? phonetic) {
    final key = original.toLowerCase();
    final next = Map<String, String>.from(state.ttsPronunciations);
    if (phonetic == null || phonetic.isEmpty) {
      if (!next.containsKey(key)) return;
      next.remove(key);
    } else {
      if (next[key] == phonetic) return;
      next[key] = phonetic;
    }
    _box.put(_kTtsPronunciations, next);
    emit(state.copyWith(ttsPronunciations: next));
  }

  /// Per-book voice override. Value is the engine's voice label or a
  /// `lang::voiceName` composite — whichever caller stored. Null clears.
  void setTtsVoiceForBook(String sourceId, String bookId, String? voice) {
    final key = bookKey(sourceId, bookId);
    final next = Map<String, String>.from(state.perBookTtsVoice);
    if (voice == null || voice.isEmpty) {
      if (!next.containsKey(key)) return;
      next.remove(key);
    } else {
      if (next[key] == voice) return;
      next[key] = voice;
    }
    _box.put(_kPerBookTtsVoice, next);
    emit(state.copyWith(perBookTtsVoice: next));
  }

  void setTtsRateForBook(String sourceId, String bookId, double? rate) {
    final key = bookKey(sourceId, bookId);
    final next = Map<String, double>.from(state.perBookTtsRate);
    if (rate == null) {
      if (!next.containsKey(key)) return;
      next.remove(key);
    } else {
      final clamped = rate.clamp(0.0, 1.0);
      if (next[key] == clamped) return;
      next[key] = clamped;
    }
    _box.put(_kPerBookTtsRate, next);
    emit(state.copyWith(perBookTtsRate: next));
  }

  /// Effective voice for a book: per-book override or the global voice
  /// name. Empty string means "no voice selected — let language pick".
  String resolveTtsVoiceFor(String sourceId, String bookId) {
    final override = state.perBookTtsVoice[bookKey(sourceId, bookId)];
    return override ?? state.ttsVoiceName ?? '';
  }

  /// Effective rate for a book: per-book override or the global rate.
  double resolveTtsRateFor(String sourceId, String bookId) {
    final override = state.perBookTtsRate[bookKey(sourceId, bookId)];
    return override ?? state.ttsRate;
  }
}

@immutable
class NovelPrefs {
  const NovelPrefs({
    required this.fontSize,
    required this.lineHeight,
    required this.horizontalMargin,
    required this.fontFamily,
    required this.backgroundMode,
    required this.useVolumeButtons,
    this.perBookBackgroundMode = const <String, String>{},
    this.perBookFontFamily = const <String, String>{},
    this.autoScrollEnabledBooks = const <String>{},
    this.autoScrollSpeed = NovelPrefsCubit.defaultAutoScrollSpeed,
    this.showFloatingAutoScroll =
        NovelPrefsCubit.defaultShowFloatingAutoScroll,
    this.ttsRate = NovelPrefsCubit.defaultTtsRate,
    this.ttsLanguage = NovelPrefsCubit.defaultTtsLanguage,
    this.ttsVoiceName,
    this.ttsPitch = NovelPrefsCubit.defaultTtsPitch,
    this.ttsVolume = NovelPrefsCubit.defaultTtsVolume,
    this.ttsStopAtChapterEnd = NovelPrefsCubit.defaultTtsStopAtChapterEnd,
    this.ttsSkipMarkers = NovelPrefsCubit.defaultTtsSkipMarkers,
    this.ttsParagraphPauseMs = NovelPrefsCubit.defaultTtsParagraphPauseMs,
    this.ttsPronunciations = const <String, String>{},
    this.perBookTtsVoice = const <String, String>{},
    this.perBookTtsRate = const <String, double>{},
  });

  final double fontSize;
  final double lineHeight;
  final double horizontalMargin;
  final String fontFamily;
  final ReadingBgMode backgroundMode;
  final bool useVolumeButtons;

  /// Per-book background override map. Key = `sourceId::bookId`,
  /// value = [ReadingBgMode.name]. Resolved by
  /// [NovelPrefsCubit.resolveBackgroundFor].
  final Map<String, String> perBookBackgroundMode;

  /// Per-book font override map. Key = `sourceId::bookId`, value =
  /// font label (must be in [NovelPrefsCubit.familyOptions]).
  final Map<String, String> perBookFontFamily;

  /// Books (keyed `sourceId::bookId`) the user has explicitly opted
  /// into auto-scroll on. Absent = off.
  final Set<String> autoScrollEnabledBooks;

  /// Continuous 0..1 auto-scroll speed. Mapped to px/sec at runtime
  /// (novels are slower than manga panels — see the reader).
  final double autoScrollSpeed;

  /// Whether the draggable floating control shows in the reader when
  /// auto-scroll is enabled.
  final bool showFloatingAutoScroll;

  /// Text-to-Speech voice rate (0..1). Applied via
  /// [NovelTtsService.setRate].
  final double ttsRate;

  /// BCP-47 language tag passed to `flutter_tts.setLanguage`.
  final String ttsLanguage;

  /// Engine-specific voice label. Null means "pick by language only".
  final String? ttsVoiceName;

  /// Pitch (0.5..2.0). 1.0 = neutral.
  final double ttsPitch;

  /// Volume (0..1).
  final double ttsVolume;

  /// When true, the reader's chapter-end callback does NOT auto-advance.
  final bool ttsStopAtChapterEnd;

  /// When true, marker glyphs / HTML-ish tags are stripped before speak.
  final bool ttsSkipMarkers;

  /// Pause between paragraphs in ms (0..2000).
  final int ttsParagraphPauseMs;

  /// Pronunciation rewrites. Keys are stored lowercase; the value is
  /// the phonetic replacement substituted before speak.
  final Map<String, String> ttsPronunciations;

  /// Per-book voice override. Key = `sourceId::bookId`, value = label.
  final Map<String, String> perBookTtsVoice;

  /// Per-book rate override. Key = `sourceId::bookId`, value = 0..1.
  final Map<String, double> perBookTtsRate;

  NovelPrefs copyWith({
    double? fontSize,
    double? lineHeight,
    double? horizontalMargin,
    String? fontFamily,
    ReadingBgMode? backgroundMode,
    Map<String, String>? perBookBackgroundMode,
    Map<String, String>? perBookFontFamily,
    Set<String>? autoScrollEnabledBooks,
    double? autoScrollSpeed,
    bool? showFloatingAutoScroll,
    bool? useVolumeButtons,
    double? ttsRate,
    String? ttsLanguage,
    String? ttsVoiceName,
    // Sentinel for nullable voice — copyWith can't distinguish "skip"
    // from "set to null" with a single optional positional parameter.
    bool clearTtsVoiceName = false,
    double? ttsPitch,
    double? ttsVolume,
    bool? ttsStopAtChapterEnd,
    bool? ttsSkipMarkers,
    int? ttsParagraphPauseMs,
    Map<String, String>? ttsPronunciations,
    Map<String, String>? perBookTtsVoice,
    Map<String, double>? perBookTtsRate,
  }) =>
      NovelPrefs(
        fontSize: fontSize ?? this.fontSize,
        lineHeight: lineHeight ?? this.lineHeight,
        horizontalMargin: horizontalMargin ?? this.horizontalMargin,
        fontFamily: fontFamily ?? this.fontFamily,
        backgroundMode: backgroundMode ?? this.backgroundMode,
        perBookBackgroundMode:
            perBookBackgroundMode ?? this.perBookBackgroundMode,
        perBookFontFamily: perBookFontFamily ?? this.perBookFontFamily,
        autoScrollEnabledBooks:
            autoScrollEnabledBooks ?? this.autoScrollEnabledBooks,
        autoScrollSpeed: autoScrollSpeed ?? this.autoScrollSpeed,
        showFloatingAutoScroll:
            showFloatingAutoScroll ?? this.showFloatingAutoScroll,
        useVolumeButtons: useVolumeButtons ?? this.useVolumeButtons,
        ttsRate: ttsRate ?? this.ttsRate,
        ttsLanguage: ttsLanguage ?? this.ttsLanguage,
        ttsVoiceName:
            clearTtsVoiceName ? null : (ttsVoiceName ?? this.ttsVoiceName),
        ttsPitch: ttsPitch ?? this.ttsPitch,
        ttsVolume: ttsVolume ?? this.ttsVolume,
        ttsStopAtChapterEnd: ttsStopAtChapterEnd ?? this.ttsStopAtChapterEnd,
        ttsSkipMarkers: ttsSkipMarkers ?? this.ttsSkipMarkers,
        ttsParagraphPauseMs:
            ttsParagraphPauseMs ?? this.ttsParagraphPauseMs,
        ttsPronunciations: ttsPronunciations ?? this.ttsPronunciations,
        perBookTtsVoice: perBookTtsVoice ?? this.perBookTtsVoice,
        perBookTtsRate: perBookTtsRate ?? this.perBookTtsRate,
      );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! NovelPrefs) return false;
    if (other.fontSize != fontSize) return false;
    if (other.lineHeight != lineHeight) return false;
    if (other.horizontalMargin != horizontalMargin) return false;
    if (other.fontFamily != fontFamily) return false;
    if (other.backgroundMode != backgroundMode) return false;
    if (other.useVolumeButtons != useVolumeButtons) return false;
    if (other.perBookBackgroundMode.length !=
        perBookBackgroundMode.length) {
      return false;
    }
    for (final e in other.perBookBackgroundMode.entries) {
      if (perBookBackgroundMode[e.key] != e.value) return false;
    }
    if (other.perBookFontFamily.length != perBookFontFamily.length) {
      return false;
    }
    for (final e in other.perBookFontFamily.entries) {
      if (perBookFontFamily[e.key] != e.value) return false;
    }
    if (other.autoScrollSpeed != autoScrollSpeed) return false;
    if (other.showFloatingAutoScroll != showFloatingAutoScroll) return false;
    if (other.ttsRate != ttsRate) return false;
    if (other.ttsLanguage != ttsLanguage) return false;
    if (other.ttsVoiceName != ttsVoiceName) return false;
    if (other.ttsPitch != ttsPitch) return false;
    if (other.ttsVolume != ttsVolume) return false;
    if (other.ttsStopAtChapterEnd != ttsStopAtChapterEnd) return false;
    if (other.ttsSkipMarkers != ttsSkipMarkers) return false;
    if (other.ttsParagraphPauseMs != ttsParagraphPauseMs) return false;
    if (other.ttsPronunciations.length != ttsPronunciations.length) {
      return false;
    }
    for (final e in other.ttsPronunciations.entries) {
      if (ttsPronunciations[e.key] != e.value) return false;
    }
    if (other.perBookTtsVoice.length != perBookTtsVoice.length) return false;
    for (final e in other.perBookTtsVoice.entries) {
      if (perBookTtsVoice[e.key] != e.value) return false;
    }
    if (other.perBookTtsRate.length != perBookTtsRate.length) return false;
    for (final e in other.perBookTtsRate.entries) {
      if (perBookTtsRate[e.key] != e.value) return false;
    }
    if (other.autoScrollEnabledBooks.length !=
        autoScrollEnabledBooks.length) {
      return false;
    }
    for (final k in other.autoScrollEnabledBooks) {
      if (!autoScrollEnabledBooks.contains(k)) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        fontSize,
        lineHeight,
        horizontalMargin,
        fontFamily,
        backgroundMode,
        useVolumeButtons,
        // Map identity is fine here — every mutation builds a new Map
        // via copyWith, so hashing by length stays consistent with
        // `==` while staying cheap.
        perBookBackgroundMode.length,
        perBookFontFamily.length,
        autoScrollEnabledBooks.length,
        autoScrollSpeed,
        showFloatingAutoScroll,
        ttsRate,
        Object.hash(
          ttsLanguage,
          ttsVoiceName,
          ttsPitch,
          ttsVolume,
          ttsStopAtChapterEnd,
          ttsSkipMarkers,
          ttsParagraphPauseMs,
          ttsPronunciations.length,
          perBookTtsVoice.length,
          perBookTtsRate.length,
        ),
      );
}

/// Color/contrast helpers for [ReadingBgMode].
class ReadingBg {
  /// Background color for the reader Scaffold. Null means "use theme default".
  static Color? backgroundFor(ReadingBgMode mode, BuildContext context) {
    switch (mode) {
      case ReadingBgMode.white:
        return const Color(0xFFFAFAF7);
      case ReadingBgMode.sepia:
        return const Color(0xFFF4ECD8);
      case ReadingBgMode.black:
        return Colors.black;
      case ReadingBgMode.system:
        return Theme.of(context).scaffoldBackgroundColor;
    }
  }

  /// Body text color for the reader. Falls back to the theme on `system`.
  static Color textFor(ReadingBgMode mode, BuildContext context) {
    final theme = Theme.of(context);
    switch (mode) {
      case ReadingBgMode.white:
        return const Color(0xFF1A1A1A);
      case ReadingBgMode.sepia:
        return const Color(0xFF3A2E1F);
      case ReadingBgMode.black:
        return const Color(0xFFE5E5E5);
      case ReadingBgMode.system:
        return theme.textTheme.bodyLarge?.color ?? theme.colorScheme.onSurface;
    }
  }

  /// Background color for the small gap between pages in the manga vertical
  /// reader, plus the page-number footer.
  static Color mangaGapFor(ReadingBgMode mode, BuildContext context) {
    switch (mode) {
      case ReadingBgMode.white:
        return const Color(0xFFFAFAF7);
      case ReadingBgMode.sepia:
        return const Color(0xFFF4ECD8);
      case ReadingBgMode.black:
        return Colors.black;
      case ReadingBgMode.system:
        return Theme.of(context).scaffoldBackgroundColor;
    }
  }

  static String label(ReadingBgMode mode) {
    switch (mode) {
      case ReadingBgMode.system:
        return 'System';
      case ReadingBgMode.white:
        return 'White';
      case ReadingBgMode.sepia:
        return 'Sepia';
      case ReadingBgMode.black:
        return 'Black';
    }
  }
}
