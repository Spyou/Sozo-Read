import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// MethodChannel wrapper that toggles `WindowManager.LayoutParams.FLAG_SECURE`
/// on the Android host activity. When set, the OS blanks the app preview in
/// the task switcher and blocks screenshots / screen recording — a privacy
/// feature exposed in `/settings/security`.
///
/// iOS has no direct analogue; calls are no-ops outside Android.
class SecureWindowChannel {
  SecureWindowChannel();

  static const MethodChannel _channel = MethodChannel('sozo/secure_window');

  /// Apply / clear FLAG_SECURE on the host window. Safe to call on iOS or
  /// in tests — failures are swallowed and logged in debug mode.
  Future<void> setFlagSecure(bool enabled) async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<void>('setFlagSecure', <String, dynamic>{
        'enabled': enabled,
      });
    } catch (e) {
      if (kDebugMode) debugPrint('[secure_window] setFlagSecure failed: $e');
    }
  }

  static bool get _isAndroid =>
      defaultTargetPlatform == TargetPlatform.android;
}
