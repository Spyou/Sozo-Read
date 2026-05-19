import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../tracker.dart';
import '../tracker_entry.dart';
import 'anilist_api.dart';
import 'anilist_auth.dart';

/// AniList implementation of the [Tracker] interface.
///
/// Owns the auth + API client; the [Tracker] surface is a thin facade over
/// those. [init] should be called once at startup (from DI wiring) so
/// [isAuthenticated] is cheap and synchronous.
class AniListTracker implements Tracker {
  AniListTracker({required this.api, required this.auth});

  final AniListApi api;
  final AniListAuth auth;

  /// Cached so [currentUserName] is cheap and synchronous. Set by [init]
  /// and by [completeLoginFromCallback]; cleared by [logout].
  String? _cachedUserName;

  /// Mirror of "is there a token in secure storage right now". Populated
  /// during [init] so [isAuthenticated] can stay synchronous as required
  /// by the [Tracker] contract.
  bool _hasToken = false;

  /// Bumped on every auth-state transition so UI surfaces can listen and
  /// rebuild without polling. See [Tracker.authChanges].
  final ValueNotifier<int> _authChanges = ValueNotifier<int>(0);

  @override
  ValueListenable<int> get authChanges => _authChanges;

  void _notifyAuthChanged() {
    _authChanges.value = _authChanges.value + 1;
  }

  /// One-shot startup hook: reads the cached token (if any) and tries to
  /// resolve it into a viewer so [currentUserName] is populated for the
  /// first frame the UI renders. Safe to call multiple times — it just
  /// refreshes the cached state.
  Future<void> init() async {
    final token = await auth.readToken();
    _hasToken = token != null && token.isNotEmpty;
    if (!_hasToken) {
      _cachedUserName = null;
      _notifyAuthChanged();
      return;
    }
    final viewer = await api.fetchViewer();
    if (viewer == null) {
      // Token is stale or rejected — treat as logged out.
      _hasToken = false;
      _cachedUserName = null;
      _notifyAuthChanged();
      return;
    }
    _cachedUserName = viewer.name;
    _notifyAuthChanged();
  }

  @override
  String get id => 'anilist';

  @override
  String get displayName => 'AniList';

  @override
  bool get isAuthenticated => _cachedUserName != null || _hasToken;

  @override
  String? get currentUserName => _cachedUserName;

  @override
  Future<String> startLogin() async {
    final url = await auth.buildAuthorizeUrl();
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    return url;
  }

  @override
  Future<bool> completeLoginFromCallback(Uri uri) async {
    final ok = await auth.handleCallback(uri);
    if (!ok) return false;
    _hasToken = true;
    // Notify immediately so any waiting UI ("Completing sign-in…") can
    // transition out of the in-progress state right away — without
    // waiting for the viewer fetch round-trip.
    _notifyAuthChanged();
    // Refresh the viewer so the username is available immediately.
    final viewer = await api.fetchViewer();
    _cachedUserName = viewer?.name;
    _notifyAuthChanged();
    return true;
  }

  @override
  Future<void> logout() async {
    await auth.clearToken();
    _hasToken = false;
    _cachedUserName = null;
    _notifyAuthChanged();
  }

  @override
  Future<List<TrackerEntry>> searchByTitle(String title) =>
      api.searchManga(title);

  @override
  Future<void> updateEntry({
    required int remoteId,
    int? progress,
    TrackerStatus? status,
    double? score,
  }) =>
      api.saveMediaListEntry(
        mediaId: remoteId,
        progress: progress,
        status: status,
        score: score,
      );

  @override
  Future<TrackerEntry?> fetchEntry(int remoteId) =>
      api.fetchMediaListEntry(remoteId);

  @override
  Future<List<TrackerEntry>> fetchUserList() => api.fetchUserMangaList();
}
