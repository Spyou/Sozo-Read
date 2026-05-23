import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Thin wrapper around the platform-side APK installer.
///
/// On Android the host activity registers a `MethodChannel('sozo/apk_installer')`
/// that exposes `installApk(path)`. The native side wraps the file in a
/// `FileProvider` URI and fires `ACTION_VIEW` with the package-archive mime
/// type — Android then shows its standard installer prompt.
///
/// IMPORTANT: Google Play policy forbids in-app self-update of the APK. When
/// shipping a Play build, feature-flag the entire update flow off. This
/// channel is only safe for the GitHub-distributed APK.
class ApkInstaller {
  const ApkInstaller();

  static const MethodChannel _channel = MethodChannel('sozo/apk_installer');

  /// Hands [path] to the OS installer. The user still has to tap "Install"
  /// in the system prompt; this just opens that prompt.
  Future<void> installApk(String path) async {
    await _channel.invokeMethod<void>('installApk', {'path': path});
  }

  /// Returns the device's preferred native ABI (`arm64-v8a`,
  /// `armeabi-v7a`, `x86_64`, etc.). Used by the auto-updater to pick
  /// the right APK asset when a release ships multiple per-ABI files.
  /// Returns null on iOS / desktop where the concept doesn't apply.
  Future<String?> primaryAbi() async {
    try {
      return await _channel.invokeMethod<String>('primaryAbi');
    } catch (e) {
      debugPrint('[updater] primaryAbi failed: $e');
      return null;
    }
  }
}
