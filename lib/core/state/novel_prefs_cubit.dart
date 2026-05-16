import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive/hive.dart';

/// Global novel-reader typography preferences. Persisted in the shared
/// Hive `settings` box.
class NovelPrefsCubit extends Cubit<NovelPrefs> {
  NovelPrefsCubit() : super(_loadInitial());

  static const String _boxName = 'settings';
  static const String _kFontSize = 'novel.fontSize';
  static const String _kLineHeight = 'novel.lineHeight';
  static const String _kMargin = 'novel.horizontalMargin';
  static const String _kFontFamily = 'novel.fontFamily';

  static const double defaultFontSize = 16;
  static const double defaultLineHeight = 1.65;
  static const double defaultMargin = 20;
  static const String defaultFontFamily = 'System';

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
}

@immutable
class NovelPrefs {
  const NovelPrefs({
    required this.fontSize,
    required this.lineHeight,
    required this.horizontalMargin,
    required this.fontFamily,
  });

  final double fontSize;
  final double lineHeight;
  final double horizontalMargin;
  final String fontFamily;

  NovelPrefs copyWith({
    double? fontSize,
    double? lineHeight,
    double? horizontalMargin,
    String? fontFamily,
  }) =>
      NovelPrefs(
        fontSize: fontSize ?? this.fontSize,
        lineHeight: lineHeight ?? this.lineHeight,
        horizontalMargin: horizontalMargin ?? this.horizontalMargin,
        fontFamily: fontFamily ?? this.fontFamily,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NovelPrefs &&
          other.fontSize == fontSize &&
          other.lineHeight == lineHeight &&
          other.horizontalMargin == horizontalMargin &&
          other.fontFamily == fontFamily;

  @override
  int get hashCode =>
      Object.hash(fontSize, lineHeight, horizontalMargin, fontFamily);
}
