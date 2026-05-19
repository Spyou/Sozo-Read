/// Persistent link between a local series (sourceId + bookId) and its
/// remote tracker entry (AniList, MAL,…). Stored in the
/// `tracker_matches` Hive box so the auto-match is run once per series
/// per tracker, not on every detail-screen open.
class TrackerMatch {
  const TrackerMatch({
    required this.sourceId,
    required this.bookId,
    required this.trackerId,
    required this.remoteId,
    required this.matchedTitle,
    required this.matchConfidence,
    required this.matchedAt,
  });

  final String sourceId;
  final String bookId;

  /// `'anilist'`, `'mal'`,…
  final String trackerId;

  /// Remote service's series ID.
  final int remoteId;

  /// The remote title we matched against — useful for "Tracked as X" UI
  /// and for detecting drift if AniList ever renames an entry.
  final String matchedTitle;

  /// 0.0 – 1.0 similarity score between the local title and the remote
  /// match. Anything ≥ `0.9` is treated as auto-match-confident; lower
  /// scores still create a [TrackerMatch] but with a UI hint so the user
  /// can re-link if it was the wrong series.
  final double matchConfidence;

  final DateTime matchedAt;

  /// Composite Hive key: `<sourceId>::<bookId>::<trackerId>`. Each
  /// (sourceId, bookId) can be linked to multiple trackers independently.
  String get key => composeKey(sourceId, bookId, trackerId);

  static String composeKey(String sourceId, String bookId, String trackerId) =>
      '$sourceId::$bookId::$trackerId';

  Map<String, dynamic> toJson() => {
        'sourceId': sourceId,
        'bookId': bookId,
        'trackerId': trackerId,
        'remoteId': remoteId,
        'matchedTitle': matchedTitle,
        'matchConfidence': matchConfidence,
        'matchedAt': matchedAt.toIso8601String(),
      };

  factory TrackerMatch.fromJson(Map<String, dynamic> j) => TrackerMatch(
        sourceId: j['sourceId'] as String,
        bookId: j['bookId'] as String,
        trackerId: j['trackerId'] as String,
        remoteId: j['remoteId'] as int,
        matchedTitle: j['matchedTitle'] as String,
        matchConfidence: (j['matchConfidence'] as num).toDouble(),
        matchedAt: DateTime.parse(j['matchedAt'] as String),
      );
}
