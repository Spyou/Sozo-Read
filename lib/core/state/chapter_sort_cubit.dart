import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive/hive.dart';

/// Global preference for whether the chapter list is shown ascending
/// (Chapter 1 at the top) or descending (latest at the top).
///
/// Persisted to the same shared `settings` Hive box used by the other
/// global prefs cubits — so the choice survives app restarts and the
/// user only ever has to set it once.
class ChapterSortCubit extends Cubit<bool> {
  ChapterSortCubit() : super(_loadInitial());

  static const String _boxName = 'settings';
  static const String _kAscending = 'chapter_sort_ascending';

  /// Default sort order for new users. Ascending = "start from Chapter 1"
  /// which matches what most readers expect when opening a new series.
  static const bool defaultAscending = true;

  static bool _loadInitial() {
    final box = Hive.box(_boxName);
    return (box.get(_kAscending) as bool?) ?? defaultAscending;
  }

  /// Flips between ascending and descending.
  void toggle() => setAscending(!state);

  void setAscending(bool ascending) {
    if (ascending == state) return;
    Hive.box(_boxName).put(_kAscending, ascending);
    emit(ascending);
  }
}
