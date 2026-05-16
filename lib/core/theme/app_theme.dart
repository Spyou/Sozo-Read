import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_colors.dart';

class AppTheme {
  AppTheme._();

  // ---- Light palette ----------------------------------------------------
  // Designed to mirror the AMOLED look but inverted: near-white surfaces
  // with dark text. Accent is injected at build time.
  static const Color _lightBackground = Color(0xFFFAFAFA);
  static const Color _lightSurface = Color(0xFFFFFFFF);
  static const Color _lightCard = Color(0xFFF0F0F0);
  static const Color _lightCardElevated = Color(0xFFE6E6E6);
  static const Color _lightTextPrimary = Color(0xFF1A1A1A);
  static const Color _lightTextSecondary = Color(0xFF555555);
  static const Color _lightTextTertiary = Color(0xFF8A8A8A);
  static const Color _lightDivider = Color(0xFFE0E0E0);

  /// Backwards-compatible dark theme with the default red accent.
  static ThemeData get dark => buildDark(AppColors.primary);

  static ThemeData buildDark(Color accent) {
    final colorScheme = ColorScheme.dark(
      brightness: Brightness.dark,
      primary: accent,
      onPrimary: AppColors.textPrimary,
      secondary: accent,
      onSecondary: AppColors.textPrimary,
      surface: AppColors.surface,
      onSurface: AppColors.textPrimary,
      error: AppColors.error,
      onError: AppColors.textPrimary,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: AppColors.background,
      canvasColor: AppColors.background,
      dividerColor: AppColors.divider,
      splashFactory: InkSparkle.splashFactory,
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
          statusBarBrightness: Brightness.dark,
        ),
        titleTextStyle: TextStyle(
          color: AppColors.textPrimary,
          fontSize: 20,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
        ),
      ),
      cardTheme: CardThemeData(
        color: AppColors.card,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        clipBehavior: Clip.antiAlias,
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: AppColors.background,
        selectedItemColor: accent,
        unselectedItemColor: AppColors.textTertiary,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
        showUnselectedLabels: true,
      ),
      textTheme: const TextTheme(
        displayLarge: TextStyle(color: AppColors.textPrimary, fontSize: 32, fontWeight: FontWeight.w800, letterSpacing: -0.5),
        displayMedium: TextStyle(color: AppColors.textPrimary, fontSize: 28, fontWeight: FontWeight.w700, letterSpacing: -0.3),
        headlineLarge: TextStyle(color: AppColors.textPrimary, fontSize: 24, fontWeight: FontWeight.w700),
        headlineMedium: TextStyle(color: AppColors.textPrimary, fontSize: 20, fontWeight: FontWeight.w700),
        headlineSmall: TextStyle(color: AppColors.textPrimary, fontSize: 18, fontWeight: FontWeight.w600),
        titleLarge: TextStyle(color: AppColors.textPrimary, fontSize: 16, fontWeight: FontWeight.w600),
        titleMedium: TextStyle(color: AppColors.textPrimary, fontSize: 14, fontWeight: FontWeight.w600),
        bodyLarge: TextStyle(color: AppColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w400, height: 1.4),
        bodyMedium: TextStyle(color: AppColors.textPrimary, fontSize: 14, fontWeight: FontWeight.w400, height: 1.4),
        bodySmall: TextStyle(color: AppColors.textSecondary, fontSize: 12, fontWeight: FontWeight.w400, height: 1.4),
        labelLarge: TextStyle(color: AppColors.textPrimary, fontSize: 14, fontWeight: FontWeight.w600),
        labelMedium: TextStyle(color: AppColors.textSecondary, fontSize: 12, fontWeight: FontWeight.w500),
        labelSmall: TextStyle(color: AppColors.textTertiary, fontSize: 11, fontWeight: FontWeight.w500),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.card,
        hintStyle: const TextStyle(color: AppColors.textTertiary, fontSize: 14),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: accent, width: 1.2),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: AppColors.textPrimary,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          elevation: 0,
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: AppColors.card,
        selectedColor: accent,
        labelStyle: const TextStyle(color: AppColors.textPrimary, fontSize: 12, fontWeight: FontWeight.w500),
        side: BorderSide.none,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      dividerTheme: const DividerThemeData(color: AppColors.divider, thickness: 0.5, space: 1),
      iconTheme: const IconThemeData(color: AppColors.textPrimary),
    );
  }

  static ThemeData get light => buildLight(AppColors.primary);

  static ThemeData buildLight(Color accent) {
    final colorScheme = ColorScheme.light(
      brightness: Brightness.light,
      primary: accent,
      onPrimary: Colors.white,
      secondary: accent,
      onSecondary: Colors.white,
      surface: _lightSurface,
      onSurface: _lightTextPrimary,
      error: AppColors.error,
      onError: Colors.white,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: _lightBackground,
      canvasColor: _lightBackground,
      dividerColor: _lightDivider,
      splashFactory: InkSparkle.splashFactory,
      appBarTheme: AppBarTheme(
        backgroundColor: _lightBackground,
        foregroundColor: _lightTextPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        systemOverlayStyle: const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.dark,
          statusBarBrightness: Brightness.light,
        ),
        titleTextStyle: const TextStyle(
          color: _lightTextPrimary,
          fontSize: 20,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
        ),
      ),
      cardTheme: CardThemeData(
        color: _lightCard,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        clipBehavior: Clip.antiAlias,
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: _lightBackground,
        selectedItemColor: accent,
        unselectedItemColor: _lightTextTertiary,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
        showUnselectedLabels: true,
      ),
      textTheme: const TextTheme(
        displayLarge: TextStyle(color: _lightTextPrimary, fontSize: 32, fontWeight: FontWeight.w800, letterSpacing: -0.5),
        displayMedium: TextStyle(color: _lightTextPrimary, fontSize: 28, fontWeight: FontWeight.w700, letterSpacing: -0.3),
        headlineLarge: TextStyle(color: _lightTextPrimary, fontSize: 24, fontWeight: FontWeight.w700),
        headlineMedium: TextStyle(color: _lightTextPrimary, fontSize: 20, fontWeight: FontWeight.w700),
        headlineSmall: TextStyle(color: _lightTextPrimary, fontSize: 18, fontWeight: FontWeight.w600),
        titleLarge: TextStyle(color: _lightTextPrimary, fontSize: 16, fontWeight: FontWeight.w600),
        titleMedium: TextStyle(color: _lightTextPrimary, fontSize: 14, fontWeight: FontWeight.w600),
        bodyLarge: TextStyle(color: _lightTextPrimary, fontSize: 15, fontWeight: FontWeight.w400, height: 1.4),
        bodyMedium: TextStyle(color: _lightTextPrimary, fontSize: 14, fontWeight: FontWeight.w400, height: 1.4),
        bodySmall: TextStyle(color: _lightTextSecondary, fontSize: 12, fontWeight: FontWeight.w400, height: 1.4),
        labelLarge: TextStyle(color: _lightTextPrimary, fontSize: 14, fontWeight: FontWeight.w600),
        labelMedium: TextStyle(color: _lightTextSecondary, fontSize: 12, fontWeight: FontWeight.w500),
        labelSmall: TextStyle(color: _lightTextTertiary, fontSize: 11, fontWeight: FontWeight.w500),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: _lightCard,
        hintStyle: const TextStyle(color: _lightTextTertiary, fontSize: 14),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: accent, width: 1.2),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          elevation: 0,
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: _lightCard,
        selectedColor: accent,
        labelStyle: const TextStyle(color: _lightTextPrimary, fontSize: 12, fontWeight: FontWeight.w500),
        side: BorderSide.none,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      dividerTheme: const DividerThemeData(color: _lightDivider, thickness: 0.5, space: 1),
      iconTheme: const IconThemeData(color: _lightTextPrimary),
      // Make _lightCardElevated reachable so analyzer doesn't warn unused.
      // (Used here as a generic surfaceContainerHighest hint.)
      extensions: const [],
    ).copyWith(
      colorScheme: colorScheme.copyWith(surfaceContainerHighest: _lightCardElevated),
    );
  }
}
