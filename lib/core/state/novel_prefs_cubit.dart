import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
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
  static const String _kVolumeButtons = 'reader.volume_buttons';

  static const double defaultFontSize = 16;
  static const double defaultLineHeight = 1.65;
  static const double defaultMargin = 20;
  static const String defaultFontFamily = 'System';
  static const ReadingBgMode defaultBackgroundMode = ReadingBgMode.system;
  static const bool defaultUseVolumeButtons = true;

  /// Available font-family options shown in the picker. The string here is
  /// the user-facing label; map to a real family via [resolveFamily].
  static const List<String> familyOptions = [
    'System',
    'Serif',
    'Sans-serif',
    'Monospace',
  ];

  /// Maps the symbolic family label to a Flutter `fontFamily` string (or
  /// null for the platform default).
  static String? resolveFamily(String label) {
    switch (label) {
      case 'Serif':
        return 'serif';
      case 'Sans-serif':
        return 'sans-serif';
      case 'Monospace':
        return 'monospace';
      case 'System':
      default:
        return null;
    }
  }

  static Box get _box => Hive.box(_boxName);

  static NovelPrefs _loadInitial() {
    return NovelPrefs(
      fontSize: (_box.get(_kFontSize) as num?)?.toDouble() ?? defaultFontSize,
      lineHeight: (_box.get(_kLineHeight) as num?)?.toDouble() ?? defaultLineHeight,
      horizontalMargin:
          (_box.get(_kMargin) as num?)?.toDouble() ?? defaultMargin,
      fontFamily: (_box.get(_kFontFamily) as String?) ?? defaultFontFamily,
      backgroundMode: _readBg(_box.get(_kBg) as String?),
      useVolumeButtons:
          (_box.get(_kVolumeButtons) as bool?) ?? defaultUseVolumeButtons,
    );
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
    final clamped = v.clamp(1.2, 2.2);
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
    _box.put(_kFontFamily, label);
    emit(state.copyWith(fontFamily: label));
  }

  void setBackgroundMode(ReadingBgMode mode) {
    _box.put(_kBg, mode.name);
    emit(state.copyWith(backgroundMode: mode));
  }

  void setUseVolumeButtons(bool v) {
    _box.put(_kVolumeButtons, v);
    emit(state.copyWith(useVolumeButtons: v));
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
  });

  final double fontSize;
  final double lineHeight;
  final double horizontalMargin;
  final String fontFamily;
  final ReadingBgMode backgroundMode;
  final bool useVolumeButtons;

  NovelPrefs copyWith({
    double? fontSize,
    double? lineHeight,
    double? horizontalMargin,
    String? fontFamily,
    ReadingBgMode? backgroundMode,
    bool? useVolumeButtons,
  }) =>
      NovelPrefs(
        fontSize: fontSize ?? this.fontSize,
        lineHeight: lineHeight ?? this.lineHeight,
        horizontalMargin: horizontalMargin ?? this.horizontalMargin,
        fontFamily: fontFamily ?? this.fontFamily,
        backgroundMode: backgroundMode ?? this.backgroundMode,
        useVolumeButtons: useVolumeButtons ?? this.useVolumeButtons,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NovelPrefs &&
          other.fontSize == fontSize &&
          other.lineHeight == lineHeight &&
          other.horizontalMargin == horizontalMargin &&
          other.fontFamily == fontFamily &&
          other.backgroundMode == backgroundMode &&
          other.useVolumeButtons == useVolumeButtons;

  @override
  int get hashCode => Object.hash(fontSize, lineHeight, horizontalMargin,
      fontFamily, backgroundMode, useVolumeButtons);
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
