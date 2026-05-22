import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../di/injection.dart';
import '../../state/incognito_cubit.dart';
import '../tracker.dart';
import '../tracker_entry.dart';
import 'mal_api.dart';
import 'mal_auth.dart';

/// MyAnimeList implementation of the [Tracker] interface.
///
/// Owns the PKCE auth + REST client; the [Tracker] surface is a thin
/// facade over those. [init] is called once during DI bootstrap so the
/// auth state is synchronously available for the first frame the UI
/// renders.
class MalTracker implements Tracker {
  MalTracker({required this.api, required this.auth});

  final MalApi api;
  final MalAuth auth;

  String? _cachedUserName;
  bool _hasToken = false;

  final ValueNotifier<int> _authChanges = ValueNotifier<int>(0);

  @override
  ValueListenable<int> get authChanges => _authChanges;

  void _notifyAuthChanged() {
    _authChanges.value = _authChanges.value + 1;
  }

  /// Reads cached tokens and resolves the viewer name so subsequent
  /// `isAuthenticated` / `currentUserName` reads are cheap and sync.
  Future<void> init() async {
    final token = await auth.readAccessToken();
    _hasToken = token != null && token.isNotEmpty;
    if (!_hasToken) {
      _cachedUserName = null;
      _notifyAuthChanged();
      return;
    }
    final viewer = await api.fetchViewer();
    if (viewer == null) {
      // Either the access token is dead and refresh failed, or MAL is
      // unreachable. Treat as logged out — the next login attempt will
      // recreate fresh tokens.
      _hasToken = false;
      _cachedUserName = null;
      _notifyAuthChanged();
      return;
    }
    _cachedUserName = viewer.name;
    _notifyAuthChanged();
  }

  @override
  String get id => 'mal';

  @override
  String get displayName => 'MyAnimeList';

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
    _notifyAuthChanged();
    final viewer = await api.fetchViewer();
    _cachedUserName = viewer?.name;
    _notifyAuthChanged();
    return true;
  }

  @override
  Future<void> logout() async {
    await auth.clearTokens();
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
  }) async {
    // Incognito: drop the push entirely (no progress, status, or score
    // updates leak to the remote tracker for this session).
    if (sl<IncognitoCubit>().state) return;
    await api.saveMediaListEntry(
      mediaId: remoteId,
      progress: progress,
      status: status,
      score: score,
    );
  }

  @override
  Future<TrackerEntry?> fetchEntry(int remoteId) =>
      api.fetchMediaListEntry(remoteId);

  @override
  Future<List<TrackerEntry>> fetchUserList() => api.fetchUserMangaList();
}
