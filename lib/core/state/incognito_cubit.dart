import 'package:flutter_bloc/flutter_bloc.dart';

/// Session-only Incognito toggle.
///
/// When `true` the rest of the app skips writes that would persist
/// reading history (read chapters, library progress, tracker pushes) and
/// uses an aggressively-evicting image cache so covers/pages don't
/// linger on disk after the session.
///
/// IMPORTANT: state is intentionally NOT persisted. Closing the app
/// resets it to off. There is no Hive box, no SharedPreferences write,
/// no copy from any prior session — purely in-memory by design.
class IncognitoCubit extends Cubit<bool> {
  IncognitoCubit() : super(false);

  /// Flips the current state. Convenience for tap handlers.
  void toggle() => emit(!state);

  /// Explicit setter. Useful for tests and programmatic toggles.
  void set(bool v) => emit(v);
}
