import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';

/// Thin wrapper around `local_auth` so the rest of the codebase doesn't have
/// to know about [LocalAuthentication] / [AuthenticationOptions] specifics.
/// PIN remains the fallback when biometric is unavailable or rejected.
class BiometricService {
  BiometricService({LocalAuthentication? auth})
      : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  /// True when the device has biometric hardware AND the user has enrolled
  /// at least one credential (fingerprint / face). False otherwise so the
  /// settings UI can grey out the biometric option.
  Future<bool> available() async {
    try {
      final supported = await _auth.isDeviceSupported();
      if (!supported) return false;
      final canCheck = await _auth.canCheckBiometrics;
      if (!canCheck) return false;
      final enrolled = await _auth.getAvailableBiometrics();
      return enrolled.isNotEmpty;
    } catch (e) {
      if (kDebugMode) debugPrint('[biometric] available() failed: $e');
      return false;
    }
  }

  /// Prompts the user to authenticate. Returns true on success. Returns
  /// false when the user cancels, fails, or biometric isn't usable. Callers
  /// should fall back to the PIN flow on a false result.
  Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: true,
          useErrorDialogs: true,
        ),
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[biometric] authenticate failed: $e');
      return false;
    }
  }
}
