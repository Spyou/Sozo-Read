import 'package:hive/hive.dart';

/// Tracks the user's pinned providerKeys for the source picker. Stored
/// in the shared `settings` Hive box as a `List<String>` so the order
/// survives across launches (user could care about pin ordering later).
///
/// Pinning is keyed by composite `providerKey` (repoUrl + sourceId), not
/// bare sourceId — that way pinning Mangakakalot-from-Bundled doesn't
/// also pin Mangakakalot-from-a-third-party-repo when the user installs
/// it later.
class PinnedSourcesPrefs {
  static const String _boxName = 'settings';
  static const String _key = 'sources.pinned_keys';

  Box get _box => Hive.box(_boxName);

  /// Stream of mutations: emitted after [toggle] / [setPinned]. Callers
  /// (e.g. the source picker) listen so they can re-render without an
  /// explicit refresh tap. Kept as a Hive watch so multiple listeners
  /// don't need extra plumbing.
  Stream<BoxEvent> watch() => _box.watch(key: _key);

  List<String> ordered() {
    final raw = _box.get(_key);
    if (raw is List) {
      return raw.whereType<String>().toList(growable: false);
    }
    return const [];
  }

  Set<String> all() => ordered().toSet();

  bool isPinned(String providerKey) => all().contains(providerKey);

  Future<void> toggle(String providerKey) async {
    final current = ordered().toList();
    if (current.contains(providerKey)) {
      current.remove(providerKey);
    } else {
      // Newest pins appear last in the list so iteration order matches
      // "pin date ascending". The UI sorts by name anyway, so this only
      // matters if we later expose a "by recently pinned" sort.
      current.add(providerKey);
    }
    await _box.put(_key, current);
  }

  Future<void> setPinned(String providerKey, bool value) async {
    final current = ordered().toList();
    final already = current.contains(providerKey);
    if (value && !already) {
      current.add(providerKey);
    } else if (!value && already) {
      current.remove(providerKey);
    } else {
      return;
    }
    await _box.put(_key, current);
  }
}
