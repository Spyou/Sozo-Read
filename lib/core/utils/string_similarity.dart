import 'dart:math' as math;

/// Classic two-row Levenshtein DP. Returns the edit distance between
/// [a] and [b]. Case-sensitive; callers should lowercase upstream if
/// they want case-insensitive comparisons.
int levenshtein(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  // Two-row variant — O(min(a, b)) memory.
  var prev = List<int>.generate(b.length + 1, (i) => i);
  var curr = List<int>.filled(b.length + 1, 0);
  for (var i = 1; i <= a.length; i++) {
    curr[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      curr[j] = math.min(
        math.min(curr[j - 1] + 1, prev[j] + 1),
        prev[j - 1] + cost,
      );
    }
    final tmp = prev;
    prev = curr;
    curr = tmp;
  }
  return prev[b.length];
}

/// Jaccard similarity over the token sets of [a] and [b]. Lowercases
/// both inputs, splits on `\W+`, and drops tokens shorter than 2 chars.
/// Returns 0..1.
double tokenSetJaccard(String a, String b) {
  final ta = _tokenize(a);
  final tb = _tokenize(b);
  if (ta.isEmpty && tb.isEmpty) return 1.0;
  if (ta.isEmpty || tb.isEmpty) return 0.0;
  final inter = ta.intersection(tb).length;
  final union = ta.union(tb).length;
  if (union == 0) return 0.0;
  return inter / union;
}

Set<String> _tokenize(String s) {
  final lowered = s.toLowerCase();
  final parts = lowered.split(RegExp(r'\W+'));
  return parts.where((t) => t.length >= 2).toSet();
}

/// Blended similarity in 0..1: 60% token-set Jaccard, 40% normalized
/// Levenshtein. Higher is more similar. Robust to small typos and
/// reorderings; the Jaccard half handles "Title: Subtitle" vs
/// "Title - Subtitle"-style noise.
double similarity(String a, String b) {
  if (a.isEmpty && b.isEmpty) return 1.0;
  final jac = tokenSetJaccard(a, b);
  final maxLen = math.max(a.length, b.length);
  final lev = maxLen == 0 ? 0.0 : levenshtein(a, b) / maxLen;
  return 0.6 * jac + 0.4 * (1 - lev);
}
