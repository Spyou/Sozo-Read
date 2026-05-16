import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive/hive.dart';

import '../repository/provider_repository.dart';

/// Single global cubit holding the user's currently-active source id.
/// Persisted in Hive so the choice survives across app launches.
class ActiveSourceCubit extends Cubit<String?> {
  ActiveSourceCubit({required ProviderRepository repository})
      : _repo = repository,
        super(_box.get('active') as String?);

  static const String _boxName = 'settings';
  static Box get _box => Hive.box(_boxName);

  static Future<void> init() async {
    if (!Hive.isBoxOpen(_boxName)) {
      await Hive.openBox(_boxName);
    }
  }

  final ProviderRepository _repo;

  /// Best-effort first-run pick: choose the first loaded provider if no
  /// saved choice exists.
  void initializeIfNeeded() {
    if (state != null) return;
    final ids = _repo.providers.map((p) => p.sourceId).toList();
    if (ids.isNotEmpty) setActive(ids.first);
  }

  void setActive(String sourceId) {
    _box.put('active', sourceId);
    emit(sourceId);
  }

  void clear() {
    _box.delete('active');
    emit(null);
  }
}
