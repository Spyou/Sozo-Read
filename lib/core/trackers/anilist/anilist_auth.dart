import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// AniList OAuth 2.0 Implicit Grant client.
///
/// Register an OAuth client at https://anilist.co/settings/developer with
/// callback URL `sozoread://oauth/anilist`, then set `ANILIST_CLIENT_ID`
/// in `.env`. The implicit-grant flow puts the access token in the URL
/// **fragment** (after `#`) of the redirect, not the query string — see
/// [AniListAuth.handleCallback].
String? get anilistClientId => dotenv.maybeGet('ANILIST_CLIENT_ID')?.trim();

/// Custom-scheme redirect URI registered with the OS for AniList callbacks.
const String anilistRedirectUri = 'sozoread://oauth/anilist';

/// Thrown by [AniListAuth.buildAuthorizeUrl] when the developer hasn't
/// configured `ANILIST_CLIENT_ID` in `.env`. Surfaced to the user as a
/// snackbar instead of opening a broken authorize URL.
class AniListClientIdMissing implements Exception {
  const AniListClientIdMissing();
  @override
  String toString() =>
      'AniListClientIdMissing: register a client at '
      'https://anilist.co/settings/developer and set ANILIST_CLIENT_ID in .env';
}

/// Secure-storage key under which the AniList access token is cached.
const String _tokenKey = 'anilist_access_token';

/// Thin wrapper around [FlutterSecureStorage] for the AniList token plus a
/// helper to build the authorize URL and to parse the OAuth callback.
class AniListAuth {
  AniListAuth({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  /// Returns the cached AniList access token or `null` if the user hasn't
  /// completed the OAuth flow yet (or has logged out).
  Future<String?> readToken() => _storage.read(key: _tokenKey);

  /// Persists [token] to secure storage. Overwrites any existing value.
  Future<void> saveToken(String token) =>
      _storage.write(key: _tokenKey, value: token);

  /// Drops the cached access token, effectively logging the user out.
  Future<void> clearToken() => _storage.delete(key: _tokenKey);

  /// Builds the AniList authorize URL for the implicit-grant flow. The
  /// caller is expected to open this URL in the system browser; AniList
  /// will then redirect to [anilistRedirectUri] with the token in the URL
  /// fragment.
  ///
  /// Throws [AniListClientIdMissing] when `ANILIST_CLIENT_ID` is unset in
  /// `.env` — calling code surfaces that as a user-friendly snackbar.
  Future<String> buildAuthorizeUrl() async {
    final id = anilistClientId;
    if (id == null || id.isEmpty) {
      throw const AniListClientIdMissing();
    }
    return 'https://anilist.co/api/v2/oauth/authorize'
        '?client_id=$id'
        '&response_type=token';
  }

  /// Handles the OAuth callback URI delivered by the OS deep-link plumbing.
  ///
  /// AniList's implicit grant places the access token in the URL **fragment**
  /// (e.g. `sozoread://oauth/anilist#access_token=XYZ&token_type=Bearer&...`)
  /// rather than the query string, so we parse [Uri.fragment] manually.
  ///
  /// Returns `true` when an access token was successfully parsed and saved,
  /// `false` if the URI isn't ours, has no fragment, or is missing the token.
  Future<bool> handleCallback(Uri uri) async {
    // Verify the URI matches our registered redirect.
    if (uri.scheme != 'sozoread' ||
        uri.host != 'oauth' ||
        !uri.path.endsWith('/anilist')) {
      return false;
    }

    final fragment = uri.fragment;
    if (fragment.isEmpty) return false;

    // Fragments use the same `key=value&key=value` shape as a query string.
    final params = Uri.splitQueryString(fragment);
    final token = params['access_token'];
    if (token == null || token.isEmpty) return false;

    await saveToken(token);
    return true;
  }
}
