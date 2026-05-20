import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive/hive.dart';

/// Whether to show NSFW-tagged sources in the Repos tab. Defaults to
/// `false` (hidden) so a fresh install doesn't surface adult-tagged
/// providers without an explicit opt-in.
///
/// Stored in the shared `settings` Hive box alongside the other global
/// prefs cubits (manga, novel, theme, chapter sort).
class SourceFilterCubit extends Cubit<bool> {
  SourceFilterCubit() : super(_loadInitial());

  static const String _boxName = 'settings';
  static const String _kShowNsfw = 'sources.show_nsfw';

  static bool _loadInitial() {
    final box = Hive.box(_boxName);
    return (box.get(_kShowNsfw) as bool?) ?? false;
  }

  void setShowNsfw(bool v) {
    if (v == state) return;
    Hive.box(_boxName).put(_kShowNsfw, v);
    emit(v);
  }
}
