import 'package:flutter/material.dart';

/// Deterministic color + initials for the default avatar.
///
/// Same seed (usually the user's email) always picks the same color, so a
/// user keeps the same avatar tint across devices and sessions even before
/// they upload a profile picture. Matches the pattern used by Gmail, Slack,
/// GitHub, etc.
class AvatarPalette {
  AvatarPalette._();

  // 14 distinct hues. Picked to remain readable in a dark UI when used with
  // an alpha-0.18 fill + alpha-0.5 border and bright text in the same color.
  static const List<Color> _palette = [
    Color(0xFFEF5350), // red
    Color(0xFFEC407A), // pink
    Color(0xFFAB47BC), // purple
    Color(0xFF7E57C2), // deep purple
    Color(0xFF5C6BC0), // indigo
    Color(0xFF42A5F5), // blue
    Color(0xFF26C6DA), // cyan
    Color(0xFF26A69A), // teal
    Color(0xFF66BB6A), // green
    Color(0xFF9CCC65), // light green
    Color(0xFFFFCA28), // amber
    Color(0xFFFFA726), // orange
    Color(0xFFFF7043), // deep orange
    Color(0xFF8D6E63), // brown
  ];

  /// Hashes [seed] and returns one of the [_palette] colors. Empty seed
  /// falls back to the first color (still deterministic — never throws).
  static Color colorFor(String? seed) {
    final s = (seed ?? '').toLowerCase();
    if (s.isEmpty) return _palette.first;
    // Simple FNV-1a-ish rolling hash — stable across platforms / Dart
    // versions, unlike `String.hashCode` which we should NOT use for a
    // value that must be reproducible across devices.
    int hash = 2166136261;
    for (final r in s.runes) {
      hash ^= r;
      hash = (hash * 16777619) & 0x7FFFFFFF;
    }
    return _palette[hash % _palette.length];
  }

  /// Returns 1–2 uppercase letters for the avatar fallback.
  ///
  /// Prefers the display name's word initials ("Jane Doe" → "JD"). Falls
  /// back to the email's local-part initials, then "?" if nothing is set.
  static String initialsFor({String? name, String? email}) {
    final source = (name?.trim().isNotEmpty ?? false)
        ? name!.trim()
        : (email ?? '').split('@').first.trim();
    if (source.isEmpty) return '?';
    final parts = source.split(RegExp(r'[\s._-]+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts[1].substring(0, 1)).toUpperCase();
  }
}
