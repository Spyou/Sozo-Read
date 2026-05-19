import 'tracker_entry.dart';

/// Abstract tracker interface — one implementation per remote service
/// (AniList, MAL, Kitsu…). [TrackerRepository] orchestrates one or many
/// concrete trackers via this surface.
///
/// Implementations are free to cache results internally (e.g. the current
/// user's library) but [TrackerRepository] does NOT assume any caching
/// here — every method is expected to hit the network unless documented
/// otherwise.
abstract class Tracker {
  /// Short stable identifier used in Hive keys and route paths. Lowercase,
  /// no spaces. Examples: `'anilist'`, `'mal'`.
  String get id;

  /// User-facing name shown in the trackers settings list. e.g. `'AniList'`.
  String get displayName;

  /// Whether the user has a valid token cached for this tracker. Should
  /// be cheap (synchronous after a one-time eager init in the constructor).
  bool get isAuthenticated;

  /// Returns the AUTHENTICATED user's display name once logged in, or
  /// `null` if not. Cheap — implementations should cache after first call.
  String? get currentUserName;

  /// Kicks off the OAuth flow by opening the system browser. The actual
  /// token is received via the deep-link callback path and routed back to
  /// [completeLoginFromCallback].
  ///
  /// Returns the URL the browser was directed to (useful for tests).
  Future<String> startLogin();

  /// Called from the app router when the OS hands back a `sozoread://`
  /// callback URI for this tracker's redirect path. Implementations parse
  /// the URI, exchange or capture the token, and persist it to secure
  /// storage.
  ///
  /// Returns `true` if a token was captured successfully.
  Future<bool> completeLoginFromCallback(Uri uri);

  /// Drops the token from secure storage and resets in-memory auth state.
  Future<void> logout();

  /// Search the remote service by title. Used by the auto-match logic in
  /// [TrackerRepository] to pick the closest remote entry for a local
  /// series. Returns at most ~20 results, ranked by the remote service's
  /// own relevance.
  Future<List<TrackerEntry>> searchByTitle(String title);

  /// Push an update to the authenticated user's list for the given remote
  /// series. Any null field is left unchanged on the remote side.
  Future<void> updateEntry({
    required int remoteId,
    int? progress,
    TrackerStatus? status,
    double? score,
  });

  /// Returns the current state of [remoteId] on the user's list, or
  /// `null` if the series isn't on their list yet.
  Future<TrackerEntry?> fetchEntry(int remoteId);

  /// Returns the user's entire manga list for import flows.
  Future<List<TrackerEntry>> fetchUserList();
}
