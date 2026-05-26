import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

/// Status reported by the CI runner for a single provider. These mirror
/// the buckets used by `scripts/check-providers.mjs` in the
/// `sozoread-providers` repo; the resolution from these to the app's
/// `ProviderHealthStatus` enum is done in [resolveHealth].
///
/// `blockedCi` is intentionally distinct from the broken buckets — it
/// means the GitHub Actions runner got Cloudflare-walled, which has no
/// bearing on whether the source works for actual users on phones.
enum RemoteProviderStatus {
  ok,
  slow,
  degraded,
  brokenParse,
  brokenHttp,
  timeout,
  blockedCi,
  unknown,
}

RemoteProviderStatus _parseStatus(String? raw) {
  switch (raw) {
    case 'ok':
      return RemoteProviderStatus.ok;
    case 'slow':
      return RemoteProviderStatus.slow;
    case 'degraded':
      return RemoteProviderStatus.degraded;
    case 'broken-parse':
      return RemoteProviderStatus.brokenParse;
    case 'broken-http':
      return RemoteProviderStatus.brokenHttp;
    case 'timeout':
      return RemoteProviderStatus.timeout;
    case 'blocked-ci':
      return RemoteProviderStatus.blockedCi;
    default:
      return RemoteProviderStatus.unknown;
  }
}

@immutable
class RemoteHealthEntry {
  const RemoteHealthEntry({
    required this.sourceId,
    required this.status,
    required this.latencyMs,
    required this.lastOkAt,
    required this.lastCheckedAt,
    required this.consecutiveFailures,
    required this.error,
  });

  final String sourceId;
  final RemoteProviderStatus status;
  final int? latencyMs;
  final DateTime? lastOkAt;
  final DateTime? lastCheckedAt;
  final int consecutiveFailures;
  final String? error;

  /// True when the entry is considered "broken" for app-side use. Kept
  /// separate from the enum so [blockedCi] (CI got walled, the source
  /// may still work for users) doesn't poison the badge.
  bool get isProblem {
    switch (status) {
      case RemoteProviderStatus.brokenParse:
      case RemoteProviderStatus.brokenHttp:
      case RemoteProviderStatus.timeout:
      case RemoteProviderStatus.degraded:
        return true;
      case RemoteProviderStatus.ok:
      case RemoteProviderStatus.slow:
      case RemoteProviderStatus.blockedCi:
      case RemoteProviderStatus.unknown:
        return false;
    }
  }

  /// Short human label for the status pill subtitle.
  String get shortLabel {
    switch (status) {
      case RemoteProviderStatus.ok:
        return 'Healthy';
      case RemoteProviderStatus.slow:
        return 'Slow';
      case RemoteProviderStatus.degraded:
        return 'Degraded';
      case RemoteProviderStatus.brokenParse:
        return 'Broken (parse)';
      case RemoteProviderStatus.brokenHttp:
        return 'Broken (HTTP)';
      case RemoteProviderStatus.timeout:
        return 'Timeout';
      case RemoteProviderStatus.blockedCi:
        return 'Blocked in CI';
      case RemoteProviderStatus.unknown:
        return 'Unknown';
    }
  }

  Map<String, dynamic> toJson() => {
        'sourceId': sourceId,
        'status': status.name,
        'latencyMs': latencyMs,
        'lastOkAt': lastOkAt?.toIso8601String(),
        'lastCheckedAt': lastCheckedAt?.toIso8601String(),
        'consecutiveFailures': consecutiveFailures,
        'error': error,
      };
}

/// Pulls the CI-published `status.json` from the providers repo and
/// caches it in Hive with stale-while-revalidate semantics.
///
/// Schema fetched (one entry per source in `sources`):
/// ```json
/// {
///   "generatedAt": "2026-05-26T03:00:00Z",
///   "runner": "github-actions",
///   "sources": {
///     "mangakakalot": {
///       "status": "ok",
///       "latencyMs": 820,
///       "lastOkAt": "...",
///       "lastCheckedAt": "...",
///       "consecutiveFailures": 0
///     }
///   }
/// }
/// ```
///
/// The service ONLY consumes this file — it never writes it. Writing is
/// the workflow's job.
class RemoteHealthService {
  RemoteHealthService({
    required Dio dio,
    required String url,
    String boxName = 'remote_health_cache',
  })  : _dio = dio,
        _url = url,
        _boxName = boxName;

  /// Refresh attempts happen at most every [refreshInterval]; cached
  /// data outside that window is still served, but a background refresh
  /// is kicked off. A separate, harder cutoff lets us flag truly stale
  /// data to the UI as "not verified recently".
  static const Duration refreshInterval = Duration(hours: 1);
  static const Duration staleAfter = Duration(hours: 24);

  final Dio _dio;
  final String _url;
  final String _boxName;

  static const String _kEntries = 'entries';
  static const String _kFetchedAt = 'fetchedAt';
  static const String _kGeneratedAt = 'generatedAt';

  static Future<void> init({String boxName = 'remote_health_cache'}) async {
    if (!Hive.isBoxOpen(boxName)) {
      await Hive.openBox(boxName);
    }
  }

  Box get _box => Hive.box(_boxName);

  /// All cached entries keyed by sourceId. Pure local read; safe to call
  /// from any thread that has Hive open.
  Map<String, RemoteHealthEntry> cached() {
    final raw = _box.get(_kEntries);
    if (raw is! Map) return const {};
    final out = <String, RemoteHealthEntry>{};
    for (final mapEntry in raw.entries) {
      final id = mapEntry.key;
      final value = mapEntry.value;
      if (id is! String || value is! Map) continue;
      try {
        out[id] = RemoteHealthEntry(
          sourceId: id,
          status: _parseStatus(value['status'] as String?),
          latencyMs: value['latencyMs'] as int?,
          lastOkAt: _parseDate(value['lastOkAt']),
          lastCheckedAt: _parseDate(value['lastCheckedAt']),
          consecutiveFailures: value['consecutiveFailures'] is int
              ? value['consecutiveFailures'] as int
              : 0,
          error: value['error'] as String?,
        );
      } catch (e) {
        debugPrint('[remote-health] skipping malformed cache entry $id: $e');
      }
    }
    return out;
  }

  DateTime? cachedAt() {
    final raw = _box.get(_kFetchedAt);
    if (raw is int) return DateTime.fromMillisecondsSinceEpoch(raw);
    return null;
  }

  DateTime? generatedAt() {
    final raw = _box.get(_kGeneratedAt);
    if (raw is String) return _parseDate(raw);
    return null;
  }

  /// True when there's no cache or the cache is older than [staleAfter].
  /// Distinct from "needs background refresh", which uses
  /// [refreshInterval] — the UI shows a "not verified recently" hint
  /// only when this is true.
  bool isStale() {
    final at = generatedAt() ?? cachedAt();
    if (at == null) return true;
    return DateTime.now().difference(at) >= staleAfter;
  }

  bool _needsRefresh() {
    final at = cachedAt();
    if (at == null) return true;
    return DateTime.now().difference(at) >= refreshInterval;
  }

  /// Read cache + opportunistically refresh in the background. The
  /// returned future resolves with the freshest map available — fresh
  /// network if we fetched, otherwise cached. Errors are swallowed; the
  /// caller falls back to whatever the cache already has.
  Future<Map<String, RemoteHealthEntry>> getOrRefresh() async {
    final c = cached();
    if (!_needsRefresh()) {
      return c;
    }
    try {
      return await _fetchAndPersist();
    } catch (e) {
      debugPrint('[remote-health] background refresh failed: $e — using cache');
      return c;
    }
  }

  /// Force a network fetch and overwrite the cache on success. Used by
  /// the user-facing "Refresh health" action.
  Future<Map<String, RemoteHealthEntry>> forceRefresh() => _fetchAndPersist();

  Future<Map<String, RemoteHealthEntry>> _fetchAndPersist() async {
    debugPrint('[remote-health] GET $_url');
    final resp = await _dio.get<String>(
      _url,
      options: Options(
        responseType: ResponseType.plain,
        validateStatus: (s) => s != null && s >= 200 && s < 300,
        // raw.githubusercontent.com sits behind Fastly with a ~5min
        // edge cache. We push status.json every 6h via CI; the cache
        // bypass lets the app see fresh data on the first request
        // after a workflow run.
        headers: {'Cache-Control': 'no-cache'},
      ),
    );
    final body = resp.data;
    if (body == null || body.isEmpty) {
      throw const RemoteHealthException('Empty status.json');
    }
    final parsed = jsonDecode(body);
    if (parsed is! Map) {
      throw RemoteHealthException(
        'status.json is not an object (got ${parsed.runtimeType})',
      );
    }
    final sourcesRaw = parsed['sources'];
    if (sourcesRaw is! Map) {
      throw const RemoteHealthException('status.json has no sources{} object');
    }
    final out = <String, RemoteHealthEntry>{};
    for (final entry in sourcesRaw.entries) {
      final id = entry.key;
      final value = entry.value;
      if (id is! String || value is! Map) continue;
      out[id] = RemoteHealthEntry(
        sourceId: id,
        status: _parseStatus(value['status'] as String?),
        latencyMs: value['latencyMs'] is int ? value['latencyMs'] as int : null,
        lastOkAt: _parseDate(value['lastOkAt']),
        lastCheckedAt: _parseDate(value['lastCheckedAt']),
        consecutiveFailures: value['consecutiveFailures'] is int
            ? value['consecutiveFailures'] as int
            : 0,
        error: value['error'] as String?,
      );
    }
    // Persist as plain JSON-shaped maps; Hive's `dynamic` adapter
    // handles primitives + maps without registration.
    await _box.put(
      _kEntries,
      out.map(
        (k, v) => MapEntry(k, {
          'status': v.status.name,
          'latencyMs': v.latencyMs,
          'lastOkAt': v.lastOkAt?.toIso8601String(),
          'lastCheckedAt': v.lastCheckedAt?.toIso8601String(),
          'consecutiveFailures': v.consecutiveFailures,
          'error': v.error,
        }),
      ),
    );
    await _box.put(_kFetchedAt, DateTime.now().millisecondsSinceEpoch);
    final generated = parsed['generatedAt'];
    if (generated is String) {
      await _box.put(_kGeneratedAt, generated);
    }
    debugPrint('[remote-health] parsed ${out.length} entries');
    return out;
  }
}

DateTime? _parseDate(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  try {
    return DateTime.parse(raw);
  } catch (_) {
    return null;
  }
}

class RemoteHealthException implements Exception {
  const RemoteHealthException(this.message);
  final String message;
  @override
  String toString() => 'RemoteHealthException: $message';
}
