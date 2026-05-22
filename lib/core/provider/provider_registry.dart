import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:hive/hive.dart';

import '../error/exceptions.dart';
import 'provider_downloader.dart';
import 'provider_manager.dart';
import 'provider_repo_registry.dart';

/// Separator inside a composite provider key. Same shape as the
/// per-book auto-scroll keys (`sourceId::bookId`).
const String kProviderKeySep = '::';

/// Synthetic origin used for built-in / bundled providers that don't
/// come from a tracked repo. Keeps the composite key non-empty so
/// migration code and lookups behave consistently.
const String kBundledRepoUrl = 'bundled://';
const String kBuiltinRepoUrl = 'builtin://';

class ProviderRegistryEntry {
  final String name;
  final String url;
  final String version;
  final bool enabled;

  /// The repo manifest URL the provider originally came from. Empty
  /// string for legacy entries that pre-date the composite-key refactor
  /// (those are rewritten by [ProviderRegistry._migrate]).
  final String originRepoUrl;

  /// Display name of the originating repo, snapshotted at install time
  /// so the source picker can label rows without re-resolving the repo
  /// manifest on every open. May be empty for legacy entries.
  final String displayName;

  ProviderRegistryEntry({
    required this.name,
    required this.url,
    this.version = '1.0.0',
    this.enabled = true,
    this.originRepoUrl = '',
    this.displayName = '',
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'url': url,
        'version': version,
        'enabled': enabled,
        if (originRepoUrl.isNotEmpty) 'originRepoUrl': originRepoUrl,
        if (displayName.isNotEmpty) 'displayName': displayName,
      };

  factory ProviderRegistryEntry.fromJson(Map<String, dynamic> j) =>
      ProviderRegistryEntry(
        name: j['name'] as String,
        url: j['url'] as String,
        version: j['version'] as String? ?? '1.0.0',
        enabled: j['enabled'] as bool? ?? true,
        originRepoUrl: (j['originRepoUrl'] as String?) ?? '',
        displayName: (j['displayName'] as String?) ?? '',
      );

  ProviderRegistryEntry copyWith({
    bool? enabled,
    String? version,
    String? url,
    String? originRepoUrl,
    String? displayName,
  }) =>
      ProviderRegistryEntry(
        name: name,
        url: url ?? this.url,
        version: version ?? this.version,
        enabled: enabled ?? this.enabled,
        originRepoUrl: originRepoUrl ?? this.originRepoUrl,
        displayName: displayName ?? this.displayName,
      );
}

class ProviderRegistry {
  static const String boxName = 'provider_registry';

  ProviderRegistry({
    required ProviderDownloader downloader,
    required ProviderManager manager,
    ProviderReposRegistry? repos,
  })  : _downloader = downloader,
        _manager = manager,
        _repos = repos;

  final ProviderDownloader _downloader;
  final ProviderManager _manager;
  // Optional — used during migration to look up a legacy entry's repo
  // by scanning every tracked repo's source list. Not required for
  // any runtime operation.
  final ProviderReposRegistry? _repos;

  Box<Map> get _box => Hive.box<Map>(boxName);

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await Hive.openBox<Map>(boxName);
    }
  }

  /// Composite key shape: `'$repoUrl::$sourceId'`. Empty repoUrl
  /// degrades to a leading `::sourceId` — still parseable, still
  /// unique per (repo, source).
  static String providerKey(String repoUrl, String sourceId) =>
      '$repoUrl$kProviderKeySep$sourceId';

  /// Returns the sourceId portion of [key]. Handles legacy bare ids
  /// (no separator) by returning them as-is.
  static String sourceIdOf(String key) {
    final i = key.lastIndexOf(kProviderKeySep);
    if (i < 0) return key;
    return key.substring(i + kProviderKeySep.length);
  }

  /// Returns the repoUrl portion of [key]. Legacy bare ids → empty.
  static String repoUrlOf(String key) {
    final i = key.lastIndexOf(kProviderKeySep);
    if (i < 0) return '';
    return key.substring(0, i);
  }

  String get _registryBase {
    final v = dotenv.maybeGet('PROVIDER_REGISTRY_BASE');
    return v ?? 'https://raw.githubusercontent.com/YOUR_USER/sozoread-providers/main/';
  }

  /// Built-in (default) providers shipped with the app. The user can also add custom URLs.
  List<ProviderRegistryEntry> get builtIns => [
        ProviderRegistryEntry(
          name: 'mangadex',
          url: '${_registryBase}mangadex.js',
          originRepoUrl: kBuiltinRepoUrl,
          displayName: 'Built-in',
        ),
        ProviderRegistryEntry(
          name: 'mangakakalot',
          url: '${_registryBase}mangakakalot.js',
          originRepoUrl: kBuiltinRepoUrl,
          displayName: 'Built-in',
        ),
      ];

  /// All installed entries, sorted by their composite key for stable
  /// ordering across launches.
  List<ProviderRegistryEntry> getInstalled() {
    final keys = _box.keys.cast<String>().toList()..sort();
    final out = <ProviderRegistryEntry>[];
    for (final k in keys) {
      final raw = _box.get(k);
      if (raw == null) continue;
      try {
        out.add(ProviderRegistryEntry.fromJson(Map<String, dynamic>.from(raw)));
      } catch (e) {
        debugPrint('[ProviderRegistry] skip corrupt entry $k: $e');
      }
    }
    return out;
  }

  /// Returns the composite key the entry is currently stored under, or
  /// null when no matching record exists.
  String? keyOf(ProviderRegistryEntry entry) {
    final composite = providerKey(entry.originRepoUrl, entry.name);
    if (_box.containsKey(composite)) return composite;
    // Legacy bare-name fallback (pre-migration cold start).
    if (_box.containsKey(entry.name)) return entry.name;
    return null;
  }

  /// Walks every entry in the box one time and rewrites bare-sourceId
  /// keys to composite `'$repoUrl::$sourceId'` keys. Idempotent —
  /// composite keys are left alone. Corrupt entries are dropped silently
  /// so a partially-written record doesn't sink the whole migration.
  ///
  /// Looks up the originating repo (if missing on the entry) by scanning
  /// every tracked repo's source list for a matching id. When no match
  /// is found we synthesize a bundled-or-builtin origin based on the
  /// entry's url scheme so the row still gets a usable composite key.
  Future<void> migrate() async {
    final box = _box;
    final rawKeys = box.keys.toList();
    if (rawKeys.isEmpty) return;
    final repos = _repos?.getAll() ?? const [];

    for (final raw in rawKeys) {
      final k = raw.toString();
      if (k.contains(kProviderKeySep)) continue; // already composite

      final value = box.get(raw);
      if (value == null) {
        await box.delete(raw);
        continue;
      }
      ProviderRegistryEntry entry;
      try {
        entry = ProviderRegistryEntry.fromJson(Map<String, dynamic>.from(value));
      } catch (e) {
        debugPrint('[ProviderRegistry.migrate] dropping corrupt $k: $e');
        await box.delete(raw);
        continue;
      }

      // Resolve the origin repo for this legacy entry. Tracked repos
      // win; otherwise we fall back to a synthetic origin so the new
      // key is well-formed.
      String repoUrl = entry.originRepoUrl;
      String displayName = entry.displayName;
      if (repoUrl.isEmpty) {
        for (final r in repos) {
          if (r.sources.any((s) => s.id == entry.name)) {
            repoUrl = r.url;
            displayName = r.displayName;
            break;
          }
        }
      }
      if (repoUrl.isEmpty) {
        repoUrl = entry.url.startsWith('bundled://')
            ? kBundledRepoUrl
            : kBuiltinRepoUrl;
        if (displayName.isEmpty) {
          displayName = repoUrl == kBundledRepoUrl ? 'Bundled' : 'Built-in';
        }
      }

      final newKey = providerKey(repoUrl, entry.name);
      final rewritten = entry.copyWith(
        originRepoUrl: repoUrl,
        displayName: displayName,
      );
      await box.put(newKey, rewritten.toJson());
      if (newKey != k) await box.delete(raw);
    }
  }

  /// Walks every installed entry whose `originRepoUrl` is the synthetic
  /// `bundled://` / `builtin://` and rewrites it to the real repo URL
  /// when EXACTLY ONE tracked repo claims the same `sourceId`. Idempotent.
  ///
  /// Safety: when two or more tracked repos publish the same `sourceId`,
  /// the bundled entry stays untouched — the multi-repo isolation we
  /// built in the composite-key refactor is preserved. Ambiguous matches
  /// are skipped, not guessed.
  ///
  /// Runtime side-effect: only the Hive entry is rewritten. The running
  /// `JsProvider` instance keeps its old `originRepoUrl` until the next
  /// cold start (or until the source picker reloads). The "Installed?"
  /// check in the Repos tab reads Hive directly, so the badge updates
  /// immediately even without a relaunch.
  Future<int> reassociateBundled() async {
    final repos = _repos?.getAll() ?? const [];
    if (repos.isEmpty) return 0;
    final box = _box;
    var rewrites = 0;
    final keysSnapshot = box.keys.map((k) => k.toString()).toList();
    for (final k in keysSnapshot) {
      final raw = box.get(k);
      if (raw == null) continue;
      ProviderRegistryEntry entry;
      try {
        entry = ProviderRegistryEntry.fromJson(
            Map<String, dynamic>.from(raw));
      } catch (_) {
        continue;
      }
      if (entry.originRepoUrl != kBundledRepoUrl &&
          entry.originRepoUrl != kBuiltinRepoUrl) {
        continue;
      }
      // Count distinct repos that publish this sourceId.
      final matches = <ProviderRepo>[];
      for (final r in repos) {
        if (r.sources.any((s) => s.id == entry.name)) {
          matches.add(r);
        }
      }
      if (matches.length != 1) continue;
      final repo = matches.single;
      final newKey = providerKey(repo.url, entry.name);
      if (newKey == k) continue; // already where we want it
      final rewritten = entry.copyWith(
        originRepoUrl: repo.url,
        displayName: repo.displayName,
      );
      await box.put(newKey, rewritten.toJson());
      await box.delete(k);
      rewrites += 1;
    }
    if (rewrites > 0) {
      debugPrint(
          '[ProviderRegistry.reassociateBundled] re-stamped $rewrites entries');
    }
    return rewrites;
  }

  /// First-run seeding.
  Future<void> seedDefaults() async {
    if (_box.isNotEmpty) return;
    for (final entry in builtIns) {
      await _box.put(providerKey(entry.originRepoUrl, entry.name), entry.toJson());
    }
  }

  /// Installs a provider. Composite key is `(repoUrl, name)` so two
  /// repos publishing the same `name` coexist.
  Future<ProviderRegistryEntry> install({
    required String name,
    required String url,
    String repoUrl = '',
    String displayName = '',
  }) async {
    final resolvedRepo = repoUrl.isEmpty ? kBuiltinRepoUrl : repoUrl;
    final entry = ProviderRegistryEntry(
      name: name,
      url: url,
      originRepoUrl: resolvedRepo,
      displayName: displayName,
    );
    final key = providerKey(resolvedRepo, name);
    await _box.put(key, entry.toJson());
    await _loadEntryIntoRuntime(entry);
    return entry;
  }

  /// Loads a provider directly from in-memory JS source (e.g. an asset bundle).
  /// Useful for local development before the GitHub registry is set up.
  Future<void> installFromBundled(String name, String jsSource) async {
    final key = providerKey(kBundledRepoUrl, name);
    final existing = _box.get(key);
    if (existing == null) {
      await _box.put(
        key,
        ProviderRegistryEntry(
          name: name,
          url: 'bundled://$name',
          originRepoUrl: kBundledRepoUrl,
          displayName: 'Bundled',
        ).toJson(),
      );
    }
    await _manager.load(
      sourceId: name,
      jsSource: jsSource,
      originRepoUrl: kBundledRepoUrl,
      displayName: 'Bundled',
    );
  }

  /// Uninstalls the entry matching ([repoUrl], [name]). If [repoUrl]
  /// is null, uninstalls the first entry whose sourceId == [name]
  /// (legacy single-repo callers).
  Future<void> uninstall(String name, {String? repoUrl}) async {
    final key = _resolveKey(name: name, repoUrl: repoUrl);
    if (key == null) return;
    final sourceId = sourceIdOf(key);
    // Only drop the runtime entry if no OTHER installed provider with
    // the same sourceId is still active (i.e. we're not removing the
    // backing record while a different repo's copy is loaded).
    final remaining = getInstalled()
        .where((e) => e.name == sourceId && providerKey(e.originRepoUrl, e.name) != key)
        .toList();
    if (remaining.isEmpty) {
      _manager.remove(sourceId);
      await _downloader.remove(sourceId);
    }
    await _box.delete(key);
  }

  Future<void> setEnabled(String name, bool enabled, {String? repoUrl}) async {
    final key = _resolveKey(name: name, repoUrl: repoUrl);
    if (key == null) return;
    final cur = _box.get(key);
    if (cur == null) return;
    final entry =
        ProviderRegistryEntry.fromJson(Map<String, dynamic>.from(cur))
            .copyWith(enabled: enabled);
    await _box.put(key, entry.toJson());
    if (!enabled) _manager.remove(entry.name);
  }

  /// Downloads (if needed) and loads a provider into the runtime.
  ///
  /// Runtime constraint: the underlying QuickJS host can only have
  /// ONE provider definition per [name] (sourceId) installed at a
  /// time — `globalThis.__providers[sourceId]` is a single slot.
  /// Loading a second registry entry with the same sourceId silently
  /// replaces the first. The source picker uses [setRuntimeActive] to
  /// make this swap explicit.
  Future<void> loadIntoRuntime(String name,
      {String? repoUrl, bool force = false}) async {
    final key = _resolveKey(name: name, repoUrl: repoUrl);
    if (key == null) {
      throw ProviderException('Provider not installed: $name');
    }
    final raw = _box.get(key);
    if (raw == null) throw ProviderException('Provider not installed: $name');
    final entry = ProviderRegistryEntry.fromJson(Map<String, dynamic>.from(raw));
    if (!entry.enabled) return;
    await _loadEntryIntoRuntime(entry, force: force);
  }

  /// Loads the entry that owns [providerKey] into the runtime, swapping
  /// out any other installed provider that shares its sourceId. Used by
  /// the source picker so the user can switch between two repos'
  /// versions of the same source.
  Future<void> setRuntimeActive(String key, {bool force = false}) async {
    final raw = _box.get(key);
    if (raw == null) throw ProviderException('Provider not installed: $key');
    final entry = ProviderRegistryEntry.fromJson(Map<String, dynamic>.from(raw));
    if (!entry.enabled) return;
    // Drop the existing runtime entry first so the swap is unambiguous.
    _manager.remove(entry.name);
    await _loadEntryIntoRuntime(entry, force: force);
  }

  Future<void> _loadEntryIntoRuntime(ProviderRegistryEntry entry,
      {bool force = false}) async {
    if (entry.url.startsWith('bundled://')) {
      try {
        final js = await rootBundle.loadString('providers/${entry.name}.js');
        await _manager.load(
          sourceId: entry.name,
          jsSource: js,
          originRepoUrl: entry.originRepoUrl,
          displayName: entry.displayName,
        );
        return;
      } catch (e) {
        throw ProviderException(
            'Bundled provider ${entry.name} missing from assets: $e');
      }
    }
    final cached = await _downloader.fetch(
      name: entry.name,
      url: entry.url,
      force: force,
    );
    await _manager.load(
      sourceId: entry.name,
      jsSource: cached.jsCode,
      originRepoUrl: entry.originRepoUrl,
      displayName: entry.displayName,
    );
  }

  /// Loads every enabled installed provider. Best-effort: failures are
  /// swallowed per-provider so one broken JS file doesn't sink the app.
  ///
  /// When two installed entries share a sourceId only the LAST one in
  /// iteration order ends up active in the runtime — see the doc on
  /// [loadIntoRuntime]. The user picks which one is live via the source
  /// selector after launch.
  Future<List<String>> loadAll({bool force = false}) async {
    final loaded = <String>[];
    for (final entry in getInstalled()) {
      if (!entry.enabled) continue;
      try {
        await _loadEntryIntoRuntime(entry, force: force);
        loaded.add(providerKey(entry.originRepoUrl, entry.name));
      } catch (e) {
        // ignore: avoid_print
        print('[ProviderRegistry] failed to load ${entry.name}: $e');
      }
    }
    return loaded;
  }

  /// Resolves the box key for ([name], [repoUrl]). When [repoUrl] is
  /// null we fall back to whichever installed entry has a matching
  /// sourceId — preserves the old single-arg API.
  String? _resolveKey({required String name, String? repoUrl}) {
    if (repoUrl != null) {
      final k = providerKey(repoUrl, name);
      if (_box.containsKey(k)) return k;
    }
    // Legacy bare-name match (pre-migration cold path).
    if (_box.containsKey(name)) return name;
    for (final raw in _box.keys) {
      final k = raw.toString();
      if (sourceIdOf(k) == name) return k;
    }
    return null;
  }
}
