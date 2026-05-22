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
}
