import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive/hive.dart';

import '../provider/provider_registry.dart';
import '../repository/provider_repository.dart';

/// Single global cubit holding the user's currently-active provider.
///
/// State is the composite `providerKey` (`'$repoUrl::$sourceId'`) so the
/// app can disambiguate between two repos that ship the same sourceId.
/// Consumers that only need the bare sourceId (the JS runtime, route
/// params, library lookups) call [activeSourceId] / [ProviderRegistry.sourceIdOf].
///
/// Persisted in Hive so the choice survives across app launches.
class ActiveSourceCubit extends Cubit<String?> {
  ActiveSourceCubit({required ProviderRepository repository})
      : _repo = repository,
        super(_box.get('active') as String?) {
    _migrateIfNeeded();
  }

  static const String _boxName = 'settings';
  static Box get _box => Hive.box(_boxName);

  static Future<void> init() async {
    if (!Hive.isBoxOpen(_boxName)) {
      await Hive.openBox(_boxName);
    }
  }

  final ProviderRepository _repo;

  /// SourceId portion of the active providerKey. Null when no source
  /// is selected. Returns the bare value for legacy pre-migration
  /// state that didn't store a repo prefix.
  String? get activeSourceId =>
      state == null ? null : ProviderRegistry.sourceIdOf(state!);

  /// Rewrites a legacy bare-sourceId persisted value to a composite
  /// `(repoUrl, sourceId)` key. Idempotent — values already containing
  /// `kProviderKeySep` are left alone.
  void _migrateIfNeeded() {
    final cur = state;
    if (cur == null || cur.contains(kProviderKeySep)) return;
    // Pick the first installed provider whose sourceId matches.
    final entries = _repo.providers
        .where((p) => p.sourceId == cur)
        .toList(growable: false);
    String repoUrl = entries.isNotEmpty ? entries.first.originRepoUrl : '';
    if (repoUrl.isEmpty) repoUrl = kBuiltinRepoUrl;
    final composite = ProviderRegistry.providerKey(repoUrl, cur);
    _box.put('active', composite);
    emit(composite);
  }

  /// Best-effort first-run pick: choose the first loaded provider if no
  /// saved choice exists.
  void initializeIfNeeded() {
    if (state != null) return;
    final providers = _repo.providers;
    if (providers.isEmpty) return;
    final p = providers.first;
    final key = ProviderRegistry.providerKey(
      p.originRepoUrl.isEmpty ? kBuiltinRepoUrl : p.originRepoUrl,
      p.sourceId,
    );
    setActive(key);
  }

  /// Sets the active provider. [value] is the composite providerKey;
  /// callers that only have a bare sourceId can pass it directly — it
  /// is normalized to a composite key before persistence.
  void setActive(String value) {
    final normalized = value.contains(kProviderKeySep)
        ? value
        : ProviderRegistry.providerKey(kBuiltinRepoUrl, value);
    _box.put('active', normalized);
    emit(normalized);
  }

  void clear() {
    _box.delete('active');
    emit(null);
  }
}
