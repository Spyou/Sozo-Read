import '../state/novel_prefs_cubit.dart';

/// Resolves the visible title for a book given the user's chosen
/// [TitleDisplayMode]. Centralized so every screen renders titles
/// consistently and a future mode swap is one edit instead of fifty.
///
/// Fallback rules:
///   * [TitleDisplayMode.original] → always [title]
///   * [TitleDisplayMode.english]  → [englishTitle] if non-empty, else
///                                   [title]
///   * [TitleDisplayMode.both]     → "english · title" when both exist,
///                                   else whichever is available. Used
///                                   only where the caller can fit two
///                                   lines; otherwise [primaryTitle]
///                                   + [subtitleTitle] is the cleaner
///                                   pair.
///
/// Callers that render in tight space (grid cards, search rows, etc.)
/// should use [primaryTitle] and [subtitleTitle] separately rather
/// than [displayTitle] so the layout can choose to stack or ellipsise.
String displayTitle({
  required String title,
  String? englishTitle,
  required TitleDisplayMode mode,
}) {
  final en = englishTitle?.trim();
  switch (mode) {
    case TitleDisplayMode.original:
      return title;
    case TitleDisplayMode.english:
      if (en != null && en.isNotEmpty) return en;
      return title;
    case TitleDisplayMode.both:
      if (en != null && en.isNotEmpty && en != title) {
        return '$en\n$title';
      }
      return title;
  }
}

/// Primary line for stacked layouts. Same as [displayTitle] but never
/// joins both — `both` mode returns the english (top line) here, and
/// the caller uses [subtitleTitle] for the original below it.
String primaryTitle({
  required String title,
  String? englishTitle,
  required TitleDisplayMode mode,
}) {
  final en = englishTitle?.trim();
  switch (mode) {
    case TitleDisplayMode.original:
      return title;
    case TitleDisplayMode.english:
      if (en != null && en.isNotEmpty) return en;
      return title;
    case TitleDisplayMode.both:
      if (en != null && en.isNotEmpty) return en;
      return title;
  }
}

/// Secondary line for stacked layouts. Returns an empty string when
/// no second line is wanted (single-mode renderings, or `both` with
/// no english available). UI code should skip rendering when empty.
String subtitleTitle({
  required String title,
  String? englishTitle,
  required TitleDisplayMode mode,
}) {
  if (mode != TitleDisplayMode.both) return '';
  final en = englishTitle?.trim();
  if (en == null || en.isEmpty || en == title) return '';
  // Top line shows english, bottom line shows original.
  return title;
}
