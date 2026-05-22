import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive/hive.dart';

import 'biometric_service.dart';
import 'pin_storage.dart';
import 'secure_window_channel.dart';

/// Lock mode the user picks in `/settings/security`.
enum LockMode {
  /// No App Lock; UI boots straight to the router.
  off,

  /// PIN required on cold start and after [LockTimeout] in background.
  pin,

  /// Biometric prompt with PIN fallback.
  biometric,
}

/// How long the app may stay in the background before it re-locks.
enum LockTimeout {
  /// Re-lock the moment the app loses focus.
  immediate,

  /// Grace period for quick app switches.
  oneMinute,

  /// Default — covers a typical context switch without nagging.
  fiveMinutes,

  /// "Lock on cold start only" — backgrounding never triggers a lock.
  never,
}

/// Immutable view of the lock subsystem. `phase` is the gate (Locked /
/// Unlocked / Unconfigured); the remaining fields are user settings the
/// `/settings/security` screen edits.
@immutable
class AppLockState {
  const AppLockState({
    required this.phase,
    required this.mode,
    required this.timeout,
    required this.flagSecure,
  });

  final AppLockPhase phase;
  final LockMode mode;
  final LockTimeout timeout;
  final bool flagSecure;

  bool get isLocked => phase == AppLockPhase.locked;
  bool get isUnlocked => phase == AppLockPhase.unlocked;
  bool get isUnconfigured => phase == AppLockPhase.unconfigured;

  AppLockState copyWith({
    AppLockPhase? phase,
    LockMode? mode,
    LockTimeout? timeout,
    bool? flagSecure,
  }) {
    return AppLockState(
      phase: phase ?? this.phase,
      mode: mode ?? this.mode,
      timeout: timeout ?? this.timeout,
      flagSecure: flagSecure ?? this.flagSecure,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppLockState &&
          other.phase == phase &&
          other.mode == mode &&
          other.timeout == timeout &&
          other.flagSecure == flagSecure;

  @override
  int get hashCode => Object.hash(phase, mode, timeout, flagSecure);
}

enum AppLockPhase { unlocked, locked, unconfigured }

/// Drives the App Lock gate. Bootstrap calls [init] BEFORE `runApp` so the
/// initial state is computed synchronously from Hive — that way the lock
/// screen paints in the very first frame, never the home screen.
class AppLockCubit extends Cubit<AppLockState> {
  AppLockCubit._({
    required AppLockState initial,
    required this.pinStorage,
    required this.biometric,
    required this.secureWindow,
  }) : super(initial);

  final PinStorage pinStorage;
  final BiometricService biometric;
  final SecureWindowChannel secureWindow;

  // Hive box + keys. Same `settings` box every other prefs cubit uses.
  static const String _boxName = 'settings';
  static const String _kMode = 'lock.mode';
  static const String _kTimeout = 'lock.timeout';
  static const String _kFlagSecure = 'lock.flag_secure';

  static Box get _box => Hive.box(_boxName);

  /// Tracks when the app last went to background. Compared against the
  /// configured timeout on resume to decide whether to re-lock.
  DateTime? _backgroundedAt;

  /// Synchronous factory. Called from `AppBootstrap.initialize` AFTER the
  /// `settings` box is open. Returns a cubit whose initial state already
  /// reflects whether a lock should be shown — no async resolve in the UI.
  static Future<AppLockCubit> init({
    PinStorage? pinStorage,
    BiometricService? biometric,
    SecureWindowChannel? secureWindow,
  }) async {
    final pin = pinStorage ?? PinStorage();
    final bio = biometric ?? BiometricService();
    final win = secureWindow ?? SecureWindowChannel();

    final modeIdx = _box.get(_kMode) as int?;
    final timeoutIdx = _box.get(_kTimeout) as int?;
    final flagSecure = (_box.get(_kFlagSecure) as bool?) ?? false;

    final mode = (modeIdx != null &&
            modeIdx >= 0 &&
            modeIdx < LockMode.values.length)
        ? LockMode.values[modeIdx]
        : LockMode.off;
    final timeout = (timeoutIdx != null &&
            timeoutIdx >= 0 &&
            timeoutIdx < LockTimeout.values.length)
        ? LockTimeout.values[timeoutIdx]
        : LockTimeout.fiveMinutes;

    // Mode says "on" but the user removed the PIN through another path
    // (e.g. cleared secure storage); treat as unconfigured so the lock
    // screen prompts to (re)create one before gating the UI.
    final hasPin = await pin.hasPin();
    final AppLockPhase phase;
    if (mode == LockMode.off) {
      phase = AppLockPhase.unlocked;
    } else if (!hasPin) {
      phase = AppLockPhase.unconfigured;
    } else {
      phase = AppLockPhase.locked;
    }

    final cubit = AppLockCubit._(
      initial: AppLockState(
        phase: phase,
        mode: mode,
        timeout: timeout,
        flagSecure: flagSecure,
      ),
      pinStorage: pin,
      biometric: bio,
      secureWindow: win,
    );

    // Apply FLAG_SECURE during bootstrap so the very first task-switcher
    // snapshot the OS may capture is already blanked.
    await win.setFlagSecure(flagSecure);
    return cubit;
  }

  /// Sets a brand-new PIN (or replaces the existing one) and, if the mode
  /// is currently `off`, flips it to PIN so the lock becomes effective.
  Future<void> setPin(String pin) async {
    await pinStorage.setPin(pin);
    if (state.mode == LockMode.off) {
      await setMode(LockMode.pin);
    } else if (state.isUnconfigured) {
      // Existing mode was on but no PIN — now configured, leave locked.
      emit(state.copyWith(phase: AppLockPhase.locked));
    }
  }

  /// Removes the PIN and reverts the mode to off. The UI immediately
  /// unlocks because the gate is no longer required.
  Future<void> removePin() async {
    await pinStorage.clear();
    await _box.put(_kMode, LockMode.off.index);
    emit(state.copyWith(mode: LockMode.off, phase: AppLockPhase.unlocked));
  }

  /// Switches between off / PIN / biometric. Switching ON without a PIN
  /// leaves the cubit in the `unconfigured` phase so the lock screen
  /// nudges the user to set one.
  Future<void> setMode(LockMode mode) async {
    await _box.put(_kMode, mode.index);
    if (mode == LockMode.off) {
      emit(state.copyWith(mode: mode, phase: AppLockPhase.unlocked));
      return;
    }
    final hasPin = await pinStorage.hasPin();
    emit(state.copyWith(
      mode: mode,
      phase: hasPin ? AppLockPhase.locked : AppLockPhase.unconfigured,
    ));
  }

  /// Updates the inactivity timeout. Takes effect on the NEXT background
  /// transition; an in-flight grace period is not retroactively shortened.
  Future<void> setTimeout(LockTimeout timeout) async {
    await _box.put(_kTimeout, timeout.index);
    emit(state.copyWith(timeout: timeout));
  }

  /// Toggles FLAG_SECURE. Persists + immediately drives the native channel
  /// so the task-switcher preview updates before the user even leaves the
  /// settings screen.
  Future<void> setFlagSecure(bool enabled) async {
    await _box.put(_kFlagSecure, enabled);
    await secureWindow.setFlagSecure(enabled);
    emit(state.copyWith(flagSecure: enabled));
  }

  /// Verify a PIN entered on the lock screen. On success, unlocks.
  Future<bool> unlockWithPin(String pin) async {
    final ok = await pinStorage.verify(pin);
    if (ok) {
      _backgroundedAt = null;
      emit(state.copyWith(phase: AppLockPhase.unlocked));
    }
    return ok;
  }

  /// Prompts for biometric. On success, unlocks. Falls back to PIN when
  /// the platform call returns false.
  Future<bool> unlockWithBiometric(String reason) async {
    final ok = await biometric.authenticate(reason);
    if (ok) {
      _backgroundedAt = null;
      emit(state.copyWith(phase: AppLockPhase.unlocked));
    }
    return ok;
  }

  /// Wired up from `_SozoReadAppState.didChangeAppLifecycleState`. Tracks
  /// when the app backgrounds, and on resume re-locks if more than the
  /// configured timeout has elapsed.
  void handleLifecycle(AppLifecycleState lifecycle) {
    if (state.mode == LockMode.off) return;
    if (lifecycle == AppLifecycleState.paused ||
        lifecycle == AppLifecycleState.hidden) {
      _backgroundedAt ??= DateTime.now();
      return;
    }
    if (lifecycle == AppLifecycleState.resumed) {
      if (state.isLocked || state.isUnconfigured) {
        _backgroundedAt = null;
        return;
      }
      final since = _backgroundedAt;
      _backgroundedAt = null;
      if (since == null) return;
      if (_shouldRelock(DateTime.now().difference(since))) {
        emit(state.copyWith(phase: AppLockPhase.locked));
      }
    }
  }

  bool _shouldRelock(Duration elapsed) {
    switch (state.timeout) {
      case LockTimeout.immediate:
        return true;
      case LockTimeout.oneMinute:
        return elapsed >= const Duration(minutes: 1);
      case LockTimeout.fiveMinutes:
        return elapsed >= const Duration(minutes: 5);
      case LockTimeout.never:
        return false;
    }
  }

  /// Pretty label for the picker rows in `/settings/security`.
  static String modeLabel(LockMode m) {
    switch (m) {
      case LockMode.off:
        return 'Off';
      case LockMode.pin:
        return 'PIN';
      case LockMode.biometric:
        return 'Biometric';
    }
  }

  static String timeoutLabel(LockTimeout t) {
    switch (t) {
      case LockTimeout.immediate:
        return 'Immediately';
      case LockTimeout.oneMinute:
        return 'After 1 minute';
      case LockTimeout.fiveMinutes:
        return 'After 5 minutes';
      case LockTimeout.never:
        return 'Never';
    }
  }
}
