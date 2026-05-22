import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../models/github_release.dart';

/// Fetches and caches GitHub release notes for the Sozo Read app repo.
///
/// Cache layer: the same Hive `settings` box used by the prefs cubits
/// — one key for the cached JSON list, one for the GitHub `ETag` so we
/// can short-circuit unchanged responses, one for the cache timestamp.
/// Unauthenticated GitHub API is capped at 60 req/IP/hr; the 24h TTL
/// + ETag conditional GET keep us comfortably under that ceiling even
/// for a chatty user who opens Settings → About often.
///
/// The `pendingShow` flag is set by [AppBootstrap] when the persisted
/// `last_seen_version` doesn't match the runtime `PackageInfo.version`
/// — meaning the user just upgraded. `main.dart` reads it once after
/// the first frame and triggers the "What's new" bottom sheet, then
/// clears the flag.
class ChangelogService {
  ChangelogService({required Dio dio, required String boxName})
      : _dio = dio,
        _boxName = boxName;

  /// Hard-coded for the app's own repo. If we ever fork / rebrand, the
  /// constant moves to a .env entry but for now this is fine.
  static const String _owner = 'Spyou';
  static const String _repo = 'Sozo-Read';

  static const String _kCachedJson = 'changelog.cached_releases_json';
  static const String _kCachedEtag = 'changelog.cached_etag';
  static const String _kCachedAt = 'changelog.cached_at_ms';
  static const Duration _cacheTtl = Duration(hours: 24);

  final Dio _dio;
  final String _boxName;

  Box get _box => Hive.box(_boxName);

  /// True after a successful boot-time version-bump comparison until
  /// the UI has shown (and dismissed) the What's new sheet.
  bool pendingShow = false;

  /// Returns all releases, newest first. Honours the on-disk cache:
  /// returns it immediately when fresh, refreshes when stale.
  Future<List<GitHubRelease>> all({bool forceRefresh = false}) async {
    final cached = _readCached();
    final cachedAt = _readCachedAt();
    final fresh = cachedAt != null &&
        DateTime.now().difference(cachedAt) < _cacheTtl;
    if (cached.isNotEmpty && fresh && !forceRefresh) {
      return cached;
    }
    try {
      final res = await _dio.get<List<dynamic>>(
        'https://api.github.com/repos/$_owner/$_repo/releases',
        options: Options(
          responseType: ResponseType.json,
          headers: {
            if (_readEtag() != null) 'If-None-Match': _readEtag()!,
            'Accept': 'application/vnd.github+json',
          },
          // Treat 304 / 403 as success so we can fall back to cache.
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      if (res.statusCode == 304) {
        await _touchCachedAt();
        return cached;
      }
      if (res.statusCode == 403) {
        // Rate-limited. Don't refresh the timestamp so the next call
        // tries again rather than waiting another 24h.
        return cached;
      }
      if (res.statusCode != 200 || res.data == null) {
        return cached;
      }
      final list = res.data!
          .whereType<Map<String, dynamic>>()
          .map(GitHubRelease.fromJson)
          .toList();
      list.sort((a, b) => b.publishedAt.compareTo(a.publishedAt));
      await _writeCached(list, etag: res.headers.value('etag'));
      return list;
    } catch (e) {
      debugPrint('[changelog] fetch failed: $e');
      return cached;
    }
  }

  /// Latest non-prerelease (or the most recent prerelease if no stable
  /// release exists). Cheaper than `all()` when the caller just wants
  /// the "What's new" entry.
  Future<GitHubRelease?> latest({bool forceRefresh = false}) async {
    final releases = await all(forceRefresh: forceRefresh);
    if (releases.isEmpty) return null;
    return releases.firstWhere(
      (r) => !r.prerelease,
      orElse: () => releases.first,
    );
  }

  List<GitHubRelease> _readCached() {
    final raw = _box.get(_kCachedJson);
    if (raw is! String || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .whereType<Map<String, dynamic>>()
          .map(GitHubRelease.fromJson)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  String? _readEtag() {
    final raw = _box.get(_kCachedEtag);
    if (raw is String && raw.isNotEmpty) return raw;
    return null;
  }

  DateTime? _readCachedAt() {
    final raw = _box.get(_kCachedAt);
    if (raw is int) return DateTime.fromMillisecondsSinceEpoch(raw);
    return null;
  }

  Future<void> _writeCached(List<GitHubRelease> list, {String? etag}) async {
    await _box.put(
      _kCachedJson,
      jsonEncode(list.map((r) => r.toJson()).toList()),
    );
    if (etag != null && etag.isNotEmpty) {
      await _box.put(_kCachedEtag, etag);
    }
    await _touchCachedAt();
  }

  Future<void> _touchCachedAt() async {
    await _box.put(_kCachedAt, DateTime.now().millisecondsSinceEpoch);
  }
}
