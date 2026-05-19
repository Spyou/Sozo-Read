import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../trackers/tracker.dart';
import '../trackers/tracker_entry.dart';
import '../trackers/tracker_match.dart';

/// Hive-backed orchestrator that owns every persisted local↔remote tracker
/// link and the small fan-out logic needed to keep authed services in sync
/// when the user reads a chapter or tweaks status / score from the UI.
///
/// Concrete [Tracker] implementations are injected — this class is the only
/// caller-facing API for tracker integration. The reader, detail screen and
/// settings page all talk through here so cross-cutting concerns
/// (parallel fan-out, error swallowing, fuzzy auto-match) live in one place.
class TrackerRepository {
  TrackerRepository({required this.trackers});

  /// All installed trackers, authed or not. Mirrors the registry passed in
  /// by DI; iteration order is preserved for stable UI ordering.
  final List<Tracker> trackers;

  static const String boxName = 'tracker_matches';

  /// Minimum token-set Jaccard similarity required to auto-save a match
  /// during [ensureMatched]. Below this, the user has to re-link manually.
  static const double autoMatchThreshold = 0.85;

  // ---------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------

  /// Opens the Hive box once. Static to match the bootstrap pattern used
  /// by the other repositories — called before [configureDependencies] so
  /// that the lazy singleton can read the box immediately.
  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await Hive.openBox<Map>(boxName);
    }
  }

  Box<Map> get _box => Hive.box<Map>(boxName);

  // ---------------------------------------------------------------------
  // Trackers
  // ---------------------------------------------------------------------

  /// Trackers the user has signed into. Re-evaluated on every call so a
  /// fresh login is visible without reconstructing the repository.
  List<Tracker> get authenticatedTrackers =>
      trackers.where((t) => t.isAuthenticated).toList();

  bool get hasAuthenticatedTracker =>
      trackers.any((t) => t.isAuthenticated);

  /// Lookup an installed tracker by its short id (e.g. `'anilist'`).
  /// Returns `null` if no installed tracker matches.
  Tracker? trackerById(String id) {
    for (final t in trackers) {
      if (t.id == id) return t;
    }
    return null;
  }

  // ---------------------------------------------------------------------
  // Match queries
  // ---------------------------------------------------------------------

  /// Every saved match for the given (sourceId, bookId), across all
  /// trackers. Order is unspecified.
  List<TrackerMatch> matchesFor(String sourceId, String bookId) {
    final prefix = '$sourceId::$bookId::';
    final out = <TrackerMatch>[];
    for (final raw in _box.keys) {
      final k = raw as String;
      if (!k.startsWith(prefix)) continue;
      final stored = _box.get(k);
      if (stored == null) continue;
      out.add(TrackerMatch.fromJson(Map<String, dynamic>.from(stored)));
    }
    return out;
  }

  /// The single match for (sourceId, bookId, trackerId), or `null` if the
  /// user hasn't linked this series on that tracker yet.
  TrackerMatch? matchForTracker(
    String sourceId,
    String bookId,
    String trackerId,
  ) {
    final raw = _box.get(TrackerMatch.composeKey(sourceId, bookId, trackerId));
    if (raw == null) return null;
    return TrackerMatch.fromJson(Map<String, dynamic>.from(raw));
  }

  // ---------------------------------------------------------------------
  // Auto-match
  // ---------------------------------------------------------------------

  /// For each authenticated tracker that doesn't yet have a saved match for
  /// this series, runs a fuzzy title search and persists the top result iff
  /// its similarity is `>= autoMatchThreshold`. Designed to be called from
  /// the detail screen on first open — already-matched trackers are no-ops.
  ///
  /// Trackers are queried in parallel. Per-tracker errors are caught and
  /// logged so one flaky service can't block the others.
  Future<void> ensureMatched({
    required String sourceId,
    required String bookId,
    required String localTitle,
  }) async {
    final futures = <Future<void>>[];
    for (final tracker in authenticatedTrackers) {
      if (matchForTracker(sourceId, bookId, tracker.id) != null) continue;
      futures.add(_matchOne(
        tracker: tracker,
        sourceId: sourceId,
        bookId: bookId,
        localTitle: localTitle,
      ));
    }
    if (futures.isEmpty) return;
    await Future.wait(futures);
  }

  Future<void> _matchOne({
    required Tracker tracker,
    required String sourceId,
    required String bookId,
    required String localTitle,
  }) async {
    try {
      final results = await tracker.searchByTitle(localTitle);
      if (results.isEmpty) return;

      TrackerEntry? best;
      double bestScore = -1;
      for (final r in results) {
        final s = _similarity(localTitle, r.title);
        if (s > bestScore) {
          bestScore = s;
          best = r;
        }
      }

      if (best == null) return;
      if (bestScore < autoMatchThreshold) return;

      final match = TrackerMatch(
        sourceId: sourceId,
        bookId: bookId,
        trackerId: tracker.id,
        remoteId: best.remoteId,
        matchedTitle: best.title,
        matchConfidence: bestScore,
        matchedAt: DateTime.now(),
      );
      await _box.put(match.key, match.toJson());
    } catch (e, st) {
      debugPrint(
        'TrackerRepository.ensureMatched[${tracker.id}] error: $e\n$st',
      );
    }
  }

  // ---------------------------------------------------------------------
  // Manual link / unlink
  // ---------------------------------------------------------------------

  /// Persist a manually-chosen [TrackerMatch] (e.g. from a future "re-link"
  /// dialog). Overwrites any existing match for the same composite key.
  Future<void> setMatch(TrackerMatch match) async {
    await _box.put(match.key, match.toJson());
  }

  /// Forget the saved match for (sourceId, bookId, trackerId). Does NOT
  /// touch the remote service — the remote entry stays on the user's list.
  Future<void> unlink({
    required String sourceId,
    required String bookId,
    required String trackerId,
  }) async {
    await _box.delete(TrackerMatch.composeKey(sourceId, bookId, trackerId));
  }

  // ---------------------------------------------------------------------
  // Progress fan-out (fire-and-forget)
  // ---------------------------------------------------------------------

  /// Called by the readers after a chapter is flagged as read. Pushes
  /// [chapterNumber] (1-indexed — i.e. the actual chapter number on the
  /// remote service: chapter 12 → progress 12) to every linked tracker
  /// in parallel.
  ///
  /// Note: do NOT pass a 0-indexed `chapterIndex` here. Manga chapter
  /// lists in this app are typically stored newest-first, so the caller
  /// must resolve the actual chapter number itself (e.g. from
  /// `Chapter.number` or by subtracting from `chapters.length`).
  ///
  /// Errors are swallowed via [debugPrint]. The returned future completes
  /// immediately after scheduling work — callers should NOT await it. The
  /// inner `Future.wait` runs to completion in the background.
  Future<void> pushProgress({
    required String sourceId,
    required String bookId,
    required int chapterNumber,
  }) async {
    if (chapterNumber <= 0) return;
    final matches = matchesFor(sourceId, bookId);
    if (matches.isEmpty) return;

    final ops = <Future<void>>[];
    for (final match in matches) {
      final tracker = trackerById(match.trackerId);
      if (tracker == null) continue;
      if (!tracker.isAuthenticated) continue;
      ops.add(_pushOne(tracker, match, chapterNumber));
    }
    if (ops.isEmpty) return;

    // Fire-and-forget: kick the fan-out and return without awaiting it so
    // the reader's "mark as read" UI never blocks on remote network calls.
    // ignore: discarded_futures
    Future.wait(ops).catchError((Object e, StackTrace st) {
      debugPrint('TrackerRepository.pushProgress error: $e');
      return <void>[];
    });
  }

  Future<void> _pushOne(
    Tracker tracker,
    TrackerMatch match,
    int progress,
  ) async {
    try {
      await tracker.updateEntry(
        remoteId: match.remoteId,
        progress: progress,
      );
    } catch (e, st) {
      debugPrint(
        'TrackerRepository.pushProgress[${tracker.id}] error: $e\n$st',
      );
    }
  }

  // ---------------------------------------------------------------------
  // Manual status / score writes (UI-awaited)
  // ---------------------------------------------------------------------

  /// Push a status change for [match] to the remote service. Awaited by
  /// the UI — surfaces errors to the caller so the pill can show feedback.
  Future<void> setStatus(TrackerMatch match, TrackerStatus status) async {
    final tracker = trackerById(match.trackerId);
    if (tracker == null) return;
    await tracker.updateEntry(
      remoteId: match.remoteId,
      status: status,
    );
  }

  /// Push a score change for [match] to the remote service. Awaited by
  /// the UI.
  Future<void> setScore(TrackerMatch match, double score) async {
    final tracker = trackerById(match.trackerId);
    if (tracker == null) return;
    await tracker.updateEntry(
      remoteId: match.remoteId,
      score: score,
    );
  }

  /// Fetch the live remote state for [match] (status, progress, score) so
  /// the detail screen pill can render the latest values. Returns `null`
  /// when the tracker isn't installed, isn't authed, or the remote service
  /// returns nothing.
  Future<TrackerEntry?> fetchRemoteEntry(TrackerMatch match) async {
    final tracker = trackerById(match.trackerId);
    if (tracker == null) return null;
    if (!tracker.isAuthenticated) return null;
    return tracker.fetchEntry(match.remoteId);
  }

  // ---------------------------------------------------------------------
  // Title similarity (token-set Jaccard + substring floor)
  // ---------------------------------------------------------------------

  /// Token-set Jaccard similarity between [a] and [b], in `[0.0, 1.0]`.
  ///
  /// Both inputs are normalized (lowercased, punctuation stripped,
  /// whitespace collapsed) and split into a token set. The score is
  /// `|intersection| / |union|`. As a special case, if one normalized
  /// string is a substring of the other the score is bumped to at least
  /// `0.7` so titles like `"One Piece"` vs `"One Piece: Episode A"` still
  /// surface as a plausible match.
  double _similarity(String a, String b) {
    final na = _normalize(a);
    final nb = _normalize(b);
    if (na.isEmpty || nb.isEmpty) return 0.0;
    if (na == nb) return 1.0;

    final ta = na.split(' ').where((t) => t.isNotEmpty).toSet();
    final tb = nb.split(' ').where((t) => t.isNotEmpty).toSet();
    if (ta.isEmpty || tb.isEmpty) return 0.0;

    final intersection = ta.intersection(tb).length;
    final union = ta.union(tb).length;
    final jaccard = union == 0 ? 0.0 : intersection / union;

    final substring = na.contains(nb) || nb.contains(na);
    if (substring && jaccard < 0.7) return 0.7;
    return jaccard;
  }

  /// Lowercase, replace anything that isn't `[a-z0-9]` with a space, then
  /// collapse runs of whitespace. Keeps digits so titles like `"86"` or
  /// `"7 Seeds"` don't collapse to empty.
  String _normalize(String s) {
    final lower = s.toLowerCase();
    final buf = StringBuffer();
    for (final code in lower.codeUnits) {
      final isLower = code >= 0x61 && code <= 0x7a; // a-z
      final isDigit = code >= 0x30 && code <= 0x39; // 0-9
      if (isLower || isDigit) {
        buf.writeCharCode(code);
      } else {
        buf.write(' ');
      }
    }
    // Collapse whitespace.
    return buf.toString().split(RegExp(r'\s+')).where((t) => t.isNotEmpty).join(' ');
  }
}
