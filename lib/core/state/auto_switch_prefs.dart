import 'package:hive/hive.dart';

/// Tiny Hive-backed bool stored in the shared `settings` box. Gates the
/// detail-bloc cross-source fallback. Default is OFF — false positives
/// are an explicit opt-in concern.
class AutoSwitchPrefs {
  static const String _boxName = 'settings';
  static const String _key = 'auto_switch.on_failure_enabled';

  Box get _box => Hive.box(_boxName);

  bool enabled() {
    try {
      return _box.get(_key) as bool? ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> setEnabled(bool value) async {
    await _box.put(_key, value);
  }
}
