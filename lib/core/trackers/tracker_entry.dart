/// Where the user is on a remote tracker for a single series.
///
/// Mirrors AniList/MAL's status taxonomy. We pick a small intersection so
/// the same enum can model any service — services that don't support
/// `rereading` (MAL doesn't natively) map it to [reading] at push time.
enum TrackerStatus {
  reading,
  planToRead,
  completed,
  onHold,
  dropped,
  rereading;

  /// User-facing label for UI surfaces.
  String get label {
    switch (this) {
      case TrackerStatus.reading:
        return 'Reading';
      case TrackerStatus.planToRead:
        return 'Plan to read';
      case TrackerStatus.completed:
        return 'Completed';
      case TrackerStatus.onHold:
        return 'On hold';
      case TrackerStatus.dropped:
        return 'Dropped';
      case TrackerStatus.rereading:
        return 'Rereading';
    }
  }
}

/// Snapshot of a single series' state on a remote tracker (AniList, MAL,…).
///
/// Used both as the result of `searchByTitle` (then [status] / [progress]
/// reflect the AUTHENTICATED user's existing state, or defaults) and as
/// the payload of `fetchUserList`.
class TrackerEntry {
  const TrackerEntry({
    required this.trackerId,
    required this.remoteId,
    required this.title,
    this.coverUrl,
    this.status = TrackerStatus.planToRead,
    this.progress = 0,
    this.totalChapters = 0,
    this.score,
    this.updatedAt,
  });

  /// Short tracker identifier — e.g. `'anilist'`, `'mal'`.
  final String trackerId;

  /// The remote service's ID for this series.
  final int remoteId;

  /// Canonical title as returned by the remote service (preferred over the
  /// local source's title for display, since it's likely the English name).
  final String title;

  final String? coverUrl;

  /// User's reading status on the remote service. Defaults to
  /// [TrackerStatus.planToRead] when the entry isn't on the user's list yet.
  final TrackerStatus status;

  /// Chapters the user has read on the remote service.
  final int progress;

  /// Total chapters in the series. `0` when unknown / still ongoing.
  final int totalChapters;

  /// User's 0–10 score. `null` when unscored.
  final double? score;

  final DateTime? updatedAt;

  TrackerEntry copyWith({
    TrackerStatus? status,
    int? progress,
    double? score,
    DateTime? updatedAt,
  }) =>
      TrackerEntry(
        trackerId: trackerId,
        remoteId: remoteId,
        title: title,
        coverUrl: coverUrl,
        status: status ?? this.status,
        progress: progress ?? this.progress,
        totalChapters: totalChapters,
        score: score ?? this.score,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}
