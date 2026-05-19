import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// MyAnimeList OAuth 2.0 client (PKCE flow).
///
/// Register an OAuth client at https://myanimelist.net/apiconfig with
/// callback URL `sozoread://oauth/mal`, then set `MAL_CLIENT_ID` in
/// `.env`. MAL only supports the `plain` PKCE code-challenge method, so
/// `code_challenge` is just the verifier itself.
String? get malClientId => dotenv.maybeGet('MAL_CLIENT_ID')?.trim();

const String malRedirectUri = 'sozoread://oauth/mal';
const String _authorizeUrl = 'https://myanimelist.net/v1/oauth2/authorize';
const String _tokenUrl = 'https://myanimelist.net/v1/oauth2/token';

const String _kAccessToken = 'mal_access_token';
const String _kRefreshToken = 'mal_refresh_token';
// Stored as an ISO-8601 UTC string so a parse/serialize round-trip is
// stable across timezone changes.
const String _kExpiresAt = 'mal_expires_at';
// PKCE verifier kept around between startLogin (browser opens) and
// completeLoginFromCallback (deep link delivers `?code=…`). Persisted to
// secure storage rather than memory so an OS kill between the two
// stages doesn't break the flow.
const String _kPendingVerifier = 'mal_pending_verifier';

class MalClientIdMissing implements Exception {
  const MalClientIdMissing();
  @override
  String toString() =>
      'MalClientIdMissing: register a client at '
      'https://myanimelist.net/apiconfig and set MAL_CLIENT_ID in .env';
}

class MalAuthException implements Exception {
  MalAuthException(this.message);
  final String message;
  @override
  String toString() => 'MalAuthException: $message';
}

/// Handles the PKCE OAuth flow, token storage, and the silent
/// refresh-token round-trip used before every API call.
class MalAuth {
  MalAuth({required this.dio, FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final Dio dio;
  final FlutterSecureStorage _storage;

  // ------------------------------------------------------------------
  // Token storage
  // ------------------------------------------------------------------

  Future<String?> readAccessToken() => _storage.read(key: _kAccessToken);
  Future<String?> readRefreshToken() => _storage.read(key: _kRefreshToken);

  Future<DateTime?> readExpiresAt() async {
    final raw = await _storage.read(key: _kExpiresAt);
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
    required int expiresInSeconds,
  }) async {
    final expiresAt = DateTime.now()
        .toUtc()
        .add(Duration(seconds: expiresInSeconds));
    await _storage.write(key: _kAccessToken, value: accessToken);
    await _storage.write(key: _kRefreshToken, value: refreshToken);
    await _storage.write(key: _kExpiresAt, value: expiresAt.toIso8601String());
  }

  Future<void> clearTokens() async {
    await _storage.delete(key: _kAccessToken);
    await _storage.delete(key: _kRefreshToken);
    await _storage.delete(key: _kExpiresAt);
    await _storage.delete(key: _kPendingVerifier);
  }

  // ------------------------------------------------------------------
  // PKCE flow
  // ------------------------------------------------------------------

  /// Generates a 96-char PKCE code verifier (alphabet RFC 7636 § 4.1).
  /// 96 sits comfortably in the 43..128 char window MAL accepts.
  String _generateCodeVerifier() {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final rand = Random.secure();
    return List<String>.generate(96, (_) => chars[rand.nextInt(chars.length)])
        .join();
  }

  /// Builds the MAL authorize URL and stashes the generated PKCE
  /// verifier so [exchangeCode] can find it when the callback fires.
  ///
  /// Throws [MalClientIdMissing] if `MAL_CLIENT_ID` isn't configured.
  Future<String> buildAuthorizeUrl() async {
    final id = malClientId;
    if (id == null || id.isEmpty) throw const MalClientIdMissing();
    final verifier = _generateCodeVerifier();
    await _storage.write(key: _kPendingVerifier, value: verifier);
    return Uri.parse(_authorizeUrl).replace(queryParameters: {
      'response_type': 'code',
      'client_id': id,
      'code_challenge': verifier,
      'code_challenge_method': 'plain',
      'redirect_uri': malRedirectUri,
    }).toString();
  }

  /// Parses the deep-link callback (`sozoread://oauth/mal?code=…`) and
  /// exchanges the authorization code for an access + refresh token.
  /// Returns `true` on success.
  Future<bool> handleCallback(Uri uri) async {
    if (uri.scheme != 'sozoread' ||
        uri.host != 'oauth' ||
        !uri.path.endsWith('/mal')) {
      return false;
    }
    final code = uri.queryParameters['code'];
    if (code == null || code.isEmpty) return false;
    final verifier = await _storage.read(key: _kPendingVerifier);
    if (verifier == null || verifier.isEmpty) {
      // No pending verifier — either we never started a flow or the
      // storage was wiped between [buildAuthorizeUrl] and the callback.
      return false;
    }
    try {
      await _exchangeCode(code: code, verifier: verifier);
      await _storage.delete(key: _kPendingVerifier);
      return true;
    } catch (e) {
      debugPrint('MalAuth.handleCallback: exchange failed: $e');
      return false;
    }
  }

  Future<void> _exchangeCode({
    required String code,
    required String verifier,
  }) async {
    final id = malClientId;
    if (id == null || id.isEmpty) throw const MalClientIdMissing();
    final response = await dio.post<Map<String, dynamic>>(
      _tokenUrl,
      data: {
        'client_id': id,
        'code': code,
        'code_verifier': verifier,
        'grant_type': 'authorization_code',
        'redirect_uri': malRedirectUri,
      },
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        responseType: ResponseType.json,
      ),
    );
    final body = response.data;
    if (body == null) throw MalAuthException('Empty token response');
    final access = body['access_token'] as String?;
    final refresh = body['refresh_token'] as String?;
    final expires = body['expires_in'] as int?;
    if (access == null || refresh == null || expires == null) {
      throw MalAuthException('Token response missing fields: $body');
    }
    await saveTokens(
      accessToken: access,
      refreshToken: refresh,
      expiresInSeconds: expires,
    );
  }

  // ------------------------------------------------------------------
  // Silent refresh — invoked transparently by the API client before
  // every authenticated request when the access token is about to expire.
  // ------------------------------------------------------------------

  bool _isRefreshing = false;

  /// Returns a valid access token, refreshing first if needed. Returns
  /// `null` if the user isn't logged in or the refresh fails terminally
  /// (in which case the caller should treat them as logged out).
  Future<String?> ensureValidAccessToken() async {
    final access = await readAccessToken();
    if (access == null || access.isEmpty) return null;
    final expiresAt = await readExpiresAt();
    // Refresh proactively when the token is within 5 minutes of expiry
    // so we never serve a request with a stale token.
    final cutoff = DateTime.now().toUtc().add(const Duration(minutes: 5));
    if (expiresAt != null && expiresAt.isAfter(cutoff)) {
      return access;
    }
    if (_isRefreshing) {
      // Another in-flight refresh is already running; wait for it via a
      // short polling loop. Token endpoints are fast (~hundreds of ms).
      for (int i = 0; i < 50; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (!_isRefreshing) break;
      }
      return readAccessToken();
    }
    _isRefreshing = true;
    try {
      final refresh = await readRefreshToken();
      if (refresh == null || refresh.isEmpty) {
        await clearTokens();
        return null;
      }
      await _refreshUsing(refresh);
      return readAccessToken();
    } catch (e) {
      debugPrint('MalAuth.ensureValidAccessToken: $e');
      await clearTokens();
      return null;
    } finally {
      _isRefreshing = false;
    }
  }

  Future<void> _refreshUsing(String refreshToken) async {
    final id = malClientId;
    if (id == null || id.isEmpty) throw const MalClientIdMissing();
    final response = await dio.post<Map<String, dynamic>>(
      _tokenUrl,
      data: {
        'client_id': id,
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
      },
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        responseType: ResponseType.json,
      ),
    );
    final body = response.data;
    if (body == null) throw MalAuthException('Empty refresh response');
    final access = body['access_token'] as String?;
    final newRefresh = body['refresh_token'] as String? ?? refreshToken;
    final expires = body['expires_in'] as int?;
    if (access == null || expires == null) {
      throw MalAuthException('Refresh response missing fields: $body');
    }
    await saveTokens(
      accessToken: access,
      refreshToken: newRefresh,
      expiresInSeconds: expires,
    );
  }
}
