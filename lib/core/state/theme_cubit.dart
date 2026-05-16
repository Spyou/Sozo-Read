import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive/hive.dart';

import '../theme/app_colors.dart';

/// Holds the user's theme preferences. Persisted to the existing Hive
/// `settings` box (keys: `theme.mode`, `theme.accent`).
class ThemeCubit extends Cubit<ThemeSettings> {
  ThemeCubit() : super(_loadInitial());

  static const String _boxName = 'settings';
  static const String _kMode = 'theme.mode';
  static const String _kAccent = 'theme.accent';

  static Box get _box => Hive.box(_boxName);

  /// Curated accent palette. First entry is the default red.
  static const List<Color> accentPalette = [
    Color(0xFFE50914), // red (default)
    Color(0xFFFF6B35), // orange
    Color(0xFFFFC107), // amber
    Color(0xFF4CAF50), // green
    Color(0xFF00BCD4), // teal
    Color(0xFF2196F3), // blue
    Color(0xFF9C27B0), // purple
    Color(0xFFE91E63), // pink
  ];

  static ThemeSettings _loadInitial() {
    final modeIdx = _box.get(_kMode) as int?;
    final accentValue = _box.get(_kAccent) as int?;
    final mode = (modeIdx != null && modeIdx >= 0 && modeIdx < ThemeMode.values.length)
        ? ThemeMode.values[modeIdx]
        : ThemeMode.dark;
    final accent = accentValue != null ? Color(accentValue) : AppColors.primary;
    return ThemeSettings(mode: mode, accent: accent);
  }

  void setMode(ThemeMode mode) {
    _box.put(_kMode, mode.index);
    emit(state.copyWith(mode: mode));
  }

  void setAccent(Color color) {
    // toARGB32() lacks for older Color API; use .value if available.
    // Color.value is deprecated in newer Flutter; toARGB32() is the replacement.
    final v = color.toARGB32();
    _box.put(_kAccent, v);
    emit(state.copyWith(accent: color));
  }
}

@immutable
class ThemeSettings {
  const ThemeSettings({required this.mode, required this.accent});
  final ThemeMode mode;
  final Color accent;

  ThemeSettings copyWith({ThemeMode? mode, Color? accent}) =>
      ThemeSettings(mode: mode ?? this.mode, accent: accent ?? this.accent);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ThemeSettings && other.mode == mode && other.accent == accent;

  @override
  int get hashCode => Object.hash(mode, accent);
}
