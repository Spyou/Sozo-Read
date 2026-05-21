import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

/// A single source entry inside a provider repo manifest. Matches the
/// minimal v1 schema documented in sozoread-providers/README.md.
class RepoSource {
  RepoSource({
    required this.id,
    required this.name,
    required this.version,
    required this.type,
    required this.lang,
    required this.file,
    this.logo,
    this.nsfw = false,
  });

  /// Stable id used in URLs, library entries, sync rows. Lowercase,
  /// no spaces.
  final String id;
  final String name;
  final String version;

  /// `'manga'` or `'novel'`.
  final String type;
  final String lang;

  /// Relative path to the .js file (joined against the manifest's
  /// directory at install time).
  final String file;
  final String? logo;
  final bool nsfw;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'version': version,
        'type': type,
        'lang': lang,
        'file': file,
        if (logo != null) 'logo': logo,
        if (nsfw) 'nsfw': true,
      };

  factory RepoSource.fromJson(Map<String, dynamic> j) => RepoSource(
        id: (j['id'] as String).trim(),
        name: (j['name'] as String).trim(),
        version: (j['version'] as String?) ?? '1.0.0',
        type: (j['type'] as String?) ?? 'manga',
        lang: (j['lang'] as String?) ?? 'en',
        file: (j['file'] as String).trim(),
        logo: j['logo'] as String?,
        nsfw: (j['nsfw'] as bool?) ?? false,
      );
}

/// One tracked provider repo. Manifest is refreshed via [fetchAndCache]
/// on first-use and pull-to-refresh; otherwise the cached copy renders
/// instantly.
class ProviderRepo {
  ProviderRepo({
    required this.url,
    required this.name,
    required this.description,
    required this.sources,
    required this.lastSyncedAt,
    this.customName,
  });

  /// Manifest URL — `https://.../index.json` style.
  final String url;

  /// Display name straight from the manifest. Use [displayName] in UI
  /// — it falls back to this when no [customName] override is set.
  final String name;
  final String description;
  final List<RepoSource> sources;
  final DateTime lastSyncedAt;

  /// User-set local override for [name]. When non-null and non-empty,
  /// it wins everywhere the repo's name appears in the UI. Persisted
  /// alongside the cached manifest; survives `fetchAndCache` refreshes
  /// so manifest pulls don't clobber a user's rename.
  final String? customName;

  /// What to render in the UI. Override beats manifest name.
  String get displayName {
    final c = customName?.trim();
    if (c != null && c.isNotEmpty) return c;
    return name;
  }

  Map<String, dynamic> toJson() => {
        'url': url,
        'name': name,
        'description': description,
        'sources': sources.map((s) => s.toJson()).toList(),
        'lastSyncedAt': lastSyncedAt.toIso8601String(),
        if (customName != null) 'customName': customName,
      };

  factory ProviderRepo.fromJson(Map<String, dynamic> j) => ProviderRepo(
        url: j['url'] as String,
        name: (j['name'] as String?) ?? 'Unnamed repo',
        description: (j['description'] as String?) ?? '',
        sources: ((j['sources'] as List<dynamic>?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(RepoSource.fromJson)
            .toList(),
        lastSyncedAt: DateTime.tryParse(j['lastSyncedAt'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        customName: (j['customName'] as String?)?.trim().isNotEmpty == true
            ? (j['customName'] as String).trim()
            : null,
      );
}

class ProviderRepoException implements Exception {
  ProviderRepoException(this.message);
  final String message;
  @override
  String toString() => 'ProviderRepoException: $message';
}

/// Local registry of provider repos (Cloudstream-style discovery). The
/// app keeps a Hive list of repo URLs + their cached manifests; the
/// Sources screen renders one section per repo, and tapping Install
/// inside that section calls [ProviderRegistry.install] with the
/// resolved file URL.
///
/// Manifests are JSON files at the repo's root (typically `index.json`)
/// listing every source the repo offers. See `_template.json` in the
/// sozoread-providers repo template for the schema.
class ProviderReposRegistry {
  ProviderReposRegistry({required this.dio});

  final Dio dio;

  static const String boxName = 'provider_repos';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await Hive.openBox<Map>(boxName);
    }
  }

  Box<Map> get _box => Hive.box<Map>(boxName);

  List<ProviderRepo> getAll() {
    final out = <ProviderRepo>[];
    for (final raw in _box.values) {
      try {
        out.add(ProviderRepo.fromJson(Map<String, dynamic>.from(raw)));
      } catch (e) {
        debugPrint('ProviderReposRegistry.getAll: corrupt entry — $e');
      }
    }
    // Sort so the user's most-recently-synced repo floats to the top.
    out.sort((a, b) => b.lastSyncedAt.compareTo(a.lastSyncedAt));
    return out;
  }

  ProviderRepo? get(String url) {
    final raw = _box.get(url);
    if (raw == null) return null;
    try {
      return ProviderRepo.fromJson(Map<String, dynamic>.from(raw));
    } catch (_) {
      return null;
    }
  }

  bool has(String url) => _box.containsKey(url);

  /// Fetches the manifest at [url], parses it, persists it. Throws
  /// [ProviderRepoException] on HTTP / parse failure so the UI can show
  /// a meaningful error.
  ///
  /// [customName] is used only on first-time fetches — refreshes
  /// preserve the existing override (if any) so manifest pulls don't
  /// clobber a user's rename.
  Future<ProviderRepo> fetchAndCache(String url, {String? customName}) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) {
      throw ProviderRepoException('Repo URL is empty');
    }
    // Preserve any existing customName across refreshes; only the explicit
    // [customName] argument (passed at first-add or via setCustomName)
    // can change it.
    final existing = get(trimmed);
    final resolvedCustomName = customName?.trim().isNotEmpty == true
        ? customName!.trim()
        : existing?.customName;
    try {
      final response = await dio.get<String>(
        trimmed,
        options: Options(responseType: ResponseType.plain),
      );
      final body = response.data;
      if (body == null || body.isEmpty) {
        throw ProviderRepoException('Empty manifest response');
      }
      final json = jsonDecode(body) as Map<String, dynamic>;
      final repo = ProviderRepo(
        url: trimmed,
        name: (json['name'] as String?) ?? 'Unnamed repo',
        description: (json['description'] as String?) ?? '',
        sources: ((json['sources'] as List<dynamic>?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(RepoSource.fromJson)
            .toList(),
        customName: resolvedCustomName,
        lastSyncedAt: DateTime.now(),
      );
      await _box.put(trimmed, repo.toJson());
      return repo;
    } on DioException catch (e) {
      throw ProviderRepoException(
        'HTTP ${e.response?.statusCode ?? '?'}: ${e.message ?? e.toString()}',
      );
    } on FormatException catch (e) {
      throw ProviderRepoException('Manifest is not valid JSON: ${e.message}');
    }
  }

  /// Removes a repo from the registry. Already-installed sources from
  /// that repo are NOT uninstalled — they stay in the user's library
  /// until they manually remove them.
  Future<void> remove(String url) async {
    await _box.delete(url);
  }

  /// Sets (or clears) the user's display-name override for [url].
  /// Pass an empty/whitespace string to clear and revert to the
  /// manifest's own name.
  Future<void> setCustomName(String url, String? name) async {
    final existing = get(url);
    if (existing == null) return;
    final trimmed = name?.trim();
    final resolved =
        (trimmed != null && trimmed.isNotEmpty) ? trimmed : null;
    final updated = ProviderRepo(
      url: existing.url,
      name: existing.name,
      description: existing.description,
      sources: existing.sources,
      lastSyncedAt: existing.lastSyncedAt,
      customName: resolved,
    );
    await _box.put(url, updated.toJson());
  }

  /// Resolves a [RepoSource]'s relative `file` into a full URL by
  /// joining against the manifest's directory.
  ///
  /// e.g. manifest at `https://x/y/index.json` + file `comick.js`
  ///   → `https://x/y/comick.js`
  String resolveFileUrl(ProviderRepo repo, RepoSource source) {
    // Absolute URL → use as-is. Lets a repo point at sources hosted
    // elsewhere.
    if (source.file.startsWith('http://') ||
        source.file.startsWith('https://')) {
      return source.file;
    }
    final uri = Uri.parse(repo.url);
    final segs = List<String>.from(uri.pathSegments);
    if (segs.isNotEmpty) segs.removeLast(); // drop `index.json`
    final dir = segs.isEmpty ? '' : '${segs.join('/')}/';
    return uri.replace(path: '/$dir${source.file}').toString();
  }

  /// Silently re-fetches every tracked repo's manifest in parallel and
  /// stores the updated copies. Used at app launch so a source you
  /// added to / removed from your repo propagates to users on the
  /// next time they open the app — no manual refresh required.
  ///
  /// Fire-and-forget for the caller: errors are caught per-repo (so
  /// one dead repo doesn't sink the rest) and logged via debugPrint.
  /// Never throws.
  Future<void> refreshAllInBackground() async {
    final repos = getAll();
    if (repos.isEmpty) return;
    debugPrint(
      'ProviderReposRegistry.refreshAllInBackground: '
      'refreshing ${repos.length} repo(s)',
    );
    final ops = repos.map((r) async {
      try {
        await fetchAndCache(r.url);
      } catch (e) {
        debugPrint(
          'ProviderReposRegistry.refreshAllInBackground[${r.url}] $e',
        );
      }
    });
    await Future.wait(ops);
  }

  /// Seeds the registry with the app's default repo (Spyou's) at first
  /// launch. Idempotent — already-tracked URLs are left alone.
  ///
  /// Returns true when a new entry was added, false when it was
  /// already there.
  Future<bool> seedDefaultRepo(String url) async {
    if (url.trim().isEmpty) return false;
    if (has(url)) return false;
    try {
      await fetchAndCache(url);
      return true;
    } catch (e) {
      debugPrint('ProviderReposRegistry.seedDefaultRepo: $e');
      // Persist a stub entry so the URL shows up in the Repos tab
      // even when the first fetch failed (offline boot). The UI can
      // show a refresh action.
      await _box.put(url, {
        'url': url,
        'name': 'Default repo',
        'description':
            'Could not load — pull to refresh once connected.',
        'sources': const <dynamic>[],
        'lastSyncedAt': DateTime.fromMillisecondsSinceEpoch(0)
            .toIso8601String(),
      });
      return true;
    }
  }

  Stream<BoxEvent> watch() => _box.watch();
}
