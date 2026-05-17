import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive/hive.dart';

/// User preferences for local-notification delivery.
///
/// Stored in the shared `settings` Hive box (same box the theme and novel
/// prefs use). Defaults to ENABLED so a freshly installed app immediately
/// benefits from new-chapter alerts. When disabled, the background
/// chapter-check task should bail before hitting the network.
class NotificationsPrefsCubit extends Cubit<NotificationsPrefs> {
  NotificationsPrefsCubit() : super(_loadInitial());

  static const String _boxName = 'settings';
  static const String _kEnabled = 'notifications.newChapters.enabled';

  static Box get _box => Hive.box(_boxName);

  static NotificationsPrefs _loadInitial() {
    return NotificationsPrefs(
      newChaptersEnabled:
          (_box.get(_kEnabled) as bool?) ?? defaultNewChaptersEnabled,
    );
  }

  static const bool defaultNewChaptersEnabled = true;

  /// Reads the persisted value without instantiating a cubit. Used by the
  /// Workmanager dispatcher which runs in a headless isolate with no UI
  /// state.
  static bool readNewChaptersEnabled() {
    try {
      return (_box.get(_kEnabled) as bool?) ?? defaultNewChaptersEnabled;
    } catch (_) {
      return defaultNewChaptersEnabled;
    }
  }

  void setNewChaptersEnabled(bool value) {
    _box.put(_kEnabled, value);
    emit(state.copyWith(newChaptersEnabled: value));
  }
}

@immutable
class NotificationsPrefs {
  const NotificationsPrefs({required this.newChaptersEnabled});

  final bool newChaptersEnabled;

  NotificationsPrefs copyWith({bool? newChaptersEnabled}) =>
      NotificationsPrefs(
        newChaptersEnabled: newChaptersEnabled ?? this.newChaptersEnabled,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NotificationsPrefs &&
          other.newChaptersEnabled == newChaptersEnabled;

  @override
  int get hashCode => newChaptersEnabled.hashCode;
}
