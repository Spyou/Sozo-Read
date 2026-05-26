import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../models/directory_entry.dart';

/// Fetches and caches the public Sozo Read directory.
///
/// The directory is a single JSON file Spyou maintains at
/// `DIRECTORY_URL` (overridable via .env, defaults to the
/// `sozoread-directory` repo's raw index). Schema:
///
/// ```json
/// {
///   "version": 1,
///   "entries": [
///     { "name": "...", "repoUrl": "...", "author": "...", ... }
///   ]
/// }
/// ```
///
/// Caching: 24h TTL persisted in a Hive box. App reads from cache
/// instantly on every Discover tab open; a background refresh fires
/// when the cache is stale. Cache survives offline so the user always
/// sees the last-known directory.
class DirectoryService {
  DirectoryService({
    required Dio dio,
    required String url,
    String boxName = 'directory_cache',
  })  : _dio = dio,
        _url = url,
        _boxName = boxName;

  static const Duration maxAge = Duration(hours: 24);

  final Dio _dio;
  final String _url;
  final String _boxName;

  static const String _kEntries = 'entries';
  static const String _kFetchedAt = 'fetchedAt';

  static Future<void> init({String boxName = 'directory_cache'}) async {
    if (!Hive.isBoxOpen(boxName)) {
      await Hive.openBox(boxName);
    }
  }

  Box get _box => Hive.box(_boxName);

  /// Returns the cached list immediately, OR null if there's never been
  /// a successful fetch. Pure local read; useful for first paint while
  /// the network refresh is in flight.
  List<DirectoryEntry>? cached() {
    final raw = _box.get(_kEntries);
    if (raw is! List) return null;
    final out = <DirectoryEntry>[];
    for (final item in raw) {
      if (item is Map) {
        try {
          out.add(DirectoryEntry.fromJson(
            Map<String, dynamic>.from(item),
          ));
        } catch (e) {
          debugPrint('[directory] skipping malformed entry: $e');
        }
      }
    }
    return out;
  }

  DateTime? cachedAt() {
    final raw = _box.get(_kFetchedAt);
    if (raw is int) return DateTime.fromMillisecondsSinceEpoch(raw);
    return null;
  }

  /// True when the cached copy is older than [maxAge] (or absent).
  bool isStale() {
    final t = cachedAt();
    if (t == null) return true;
    return DateTime.now().difference(t) >= maxAge;
  }

  /// Fetch the directory. Returns the freshly-pulled list on success.
  /// On any failure (network down, malformed JSON), falls back to the
  /// cached list if one exists; throws only when both fail.
  Future<List<DirectoryEntry>> refresh({bool force = false}) async {
    if (!force) {
      final c = cached();
      if (c != null && !isStale()) {
        debugPrint('[directory] serving cached (${c.length} entries)');
        return c;
      }
    }
    debugPrint('[directory] GET $_url');
    try {
      final resp = await _dio.get<String>(
        _url,
        options: Options(
          responseType: ResponseType.plain,
          // Treat any 2xx as success; we map non-2xx to a "use cache"
          // path below.
          validateStatus: (s) => s != null && s >= 200 && s < 300,
          // Tell Fastly/CDN to skip its edge cache so a freshly-edited
          // directory shows up even right after we push. The CDN holds
          // raw.githubusercontent.com responses for ~5 min otherwise.
          headers: {'Cache-Control': 'no-cache'},
        ),
      );
      debugPrint(
        '[directory] HTTP ${resp.statusCode}, '
        'bytes=${resp.data?.length ?? 0}',
      );
      final body = resp.data;
      if (body == null || body.isEmpty) {
        return _fallbackOrThrow('Empty directory response');
      }
      final parsed = jsonDecode(body);
      if (parsed is! Map) {
        return _fallbackOrThrow(
          'Directory is not an object (got ${parsed.runtimeType})',
        );
      }
      final entriesRaw = parsed['entries'];
      if (entriesRaw is! List) {
        return _fallbackOrThrow('Directory has no entries[] array');
      }
      final entries = <DirectoryEntry>[];
      for (final item in entriesRaw) {
        if (item is Map) {
          try {
            final e =
                DirectoryEntry.fromJson(Map<String, dynamic>.from(item));
            // Skip entries missing the only field we actually need to
            // do anything with.
            if (e.repoUrl.isEmpty || e.name.isEmpty) continue;
            entries.add(e);
          } catch (err) {
            debugPrint('[directory] dropping malformed entry: $err');
          }
        }
      }
      debugPrint(
        '[directory] parsed ${entries.length} entries from '
        '${entriesRaw.length} raw',
      );
      await _box.put(
        _kEntries,
        entries.map((e) => e.toJson()).toList(),
      );
      await _box.put(
        _kFetchedAt,
        DateTime.now().millisecondsSinceEpoch,
      );
      return entries;
    } catch (e) {
      return _fallbackOrThrow('Fetch failed: $e');
    }
  }

  List<DirectoryEntry> _fallbackOrThrow(String reason) {
    final c = cached();
    if (c != null) {
      debugPrint('[directory] $reason — serving cached copy');
      return c;
    }
    throw DirectoryException(reason);
  }
}

class DirectoryException implements Exception {
  DirectoryException(this.message);
  final String message;

  @override
  String toString() => 'DirectoryException: $message';
}
