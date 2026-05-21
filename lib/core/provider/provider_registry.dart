import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:hive/hive.dart';

import '../error/exceptions.dart';
import 'provider_downloader.dart';
import 'provider_manager.dart';

class ProviderRegistryEntry {
  final String name;
  final String url;
  final String version;
  final bool enabled;

  ProviderRegistryEntry({
    required this.name,
    required this.url,
    this.version = '1.0.0',
    this.enabled = true,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'url': url,
        'version': version,
        'enabled': enabled,
      };

  factory ProviderRegistryEntry.fromJson(Map<String, dynamic> j) => ProviderRegistryEntry(
        name: j['name'] as String,
        url: j['url'] as String,
        version: j['version'] as String? ?? '1.0.0',
        enabled: j['enabled'] as bool? ?? true,
      );

  ProviderRegistryEntry copyWith({bool? enabled, String? version, String? url}) =>
      ProviderRegistryEntry(
        name: name,
        url: url ?? this.url,
        version: version ?? this.version,
        enabled: enabled ?? this.enabled,
      );
}

class ProviderRegistry {
  static const String boxName = 'provider_registry';

  ProviderRegistry({
    required ProviderDownloader downloader,
    required ProviderManager manager,
  })  : _downloader = downloader,
        _manager = manager;

  final ProviderDownloader _downloader;
  final ProviderManager _manager;

  Box<Map> get _box => Hive.box<Map>(boxName);

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await Hive.openBox<Map>(boxName);
    }
  }

  String get _registryBase {
    final v = dotenv.maybeGet('PROVIDER_REGISTRY_BASE');
    return v ?? 'https://raw.githubusercontent.com/YOUR_USER/sozoread-providers/main/';
  }

  /// Built-in (default) providers shipped with the app. The user can also add custom URLs.
  List<ProviderRegistryEntry> get builtIns => [
        ProviderRegistryEntry(name: 'mangadex', url: '${_registryBase}mangadex.js'),
        ProviderRegistryEntry(name: 'mangakakalot', url: '${_registryBase}mangakakalot.js'),
      ];

  List<ProviderRegistryEntry> getInstalled() {
    final keys = _box.keys.cast<String>().toList()..sort();
    return keys
        .map((k) => ProviderRegistryEntry.fromJson(Map<String, dynamic>.from(_box.get(k)!)))
        .toList();
  }

  /// First-run seeding.
  Future<void> seedDefaults() async {
    if (_box.isNotEmpty) return;
    for (final entry in builtIns) {
      await _box.put(entry.name, entry.toJson());
    }
  }

  Future<ProviderRegistryEntry> install({required String name, required String url}) async {
    final entry = ProviderRegistryEntry(name: name, url: url);
    await _box.put(name, entry.toJson());
    await loadIntoRuntime(name);
    return entry;
  }

  /// Loads a provider directly from in-memory JS source (e.g. an asset bundle).
  /// Useful for local development before the GitHub registry is set up.
  Future<void> installFromBundled(String name, String jsSource) async {
    final existing = _box.get(name);
    if (existing == null) {
      await _box.put(
        name,
        ProviderRegistryEntry(name: name, url: 'bundled://$name').toJson(),
      );
    }
    await _manager.load(sourceId: name, jsSource: jsSource);
  }

  Future<void> uninstall(String name) async {
    _manager.remove(name);
    await _downloader.remove(name);
    await _box.delete(name);
  }

  Future<void> setEnabled(String name, bool enabled) async {
    final cur = _box.get(name);
    if (cur == null) return;
    final entry = ProviderRegistryEntry.fromJson(Map<String, dynamic>.from(cur)).copyWith(enabled: enabled);
    await _box.put(name, entry.toJson());
    if (!enabled) _manager.remove(name);
  }

  /// Downloads (if needed) and loads a provider into the runtime.
  ///
  /// Bundled providers — those that were registered via
  /// [installFromBundled] (URL prefix `bundled://`) — are reloaded from
  /// the asset bundle instead of HTTP. Otherwise an Update for a
  /// bundled source would try to GET `bundled://weebcentral` and fail.
  Future<void> loadIntoRuntime(String name, {bool force = false}) async {
    final raw = _box.get(name);
    if (raw == null) throw ProviderException('Provider not installed: $name');
    final entry = ProviderRegistryEntry.fromJson(Map<String, dynamic>.from(raw));
    if (!entry.enabled) return;
    if (entry.url.startsWith('bundled://')) {
      try {
        final js = await rootBundle.loadString('providers/$name.js');
        await _manager.load(sourceId: entry.name, jsSource: js);
        return;
      } catch (e) {
        throw ProviderException('Bundled provider $name missing from assets: $e');
      }
    }
    final cached = await _downloader.fetch(name: entry.name, url: entry.url, force: force);
    await _manager.load(sourceId: entry.name, jsSource: cached.jsCode);
  }

  /// Loads every enabled installed provider. Best-effort: failures are swallowed
  /// per-provider so one broken JS file doesn't sink the app.
  Future<List<String>> loadAll({bool force = false}) async {
    final loaded = <String>[];
    for (final entry in getInstalled()) {
      if (!entry.enabled) continue;
      try {
        await loadIntoRuntime(entry.name, force: force);
        loaded.add(entry.name);
      } catch (e) {
        // ignore: avoid_print
        print('[ProviderRegistry] failed to load ${entry.name}: $e');
      }
    }
    return loaded;
  }
}
