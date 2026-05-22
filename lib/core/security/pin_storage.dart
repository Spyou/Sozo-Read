import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Salted SHA-256 PIN storage backed by `flutter_secure_storage` (Android
/// Keystore / iOS Keychain). The plaintext PIN never touches Hive or any
/// other on-disk box — we only persist the salt and the digest.
class PinStorage {
  PinStorage({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  // Secure-storage keys. Prefixed `lock.` to keep them disjoint from the
  // tracker tokens (`anilist_access_token`, `mal_access_token`).
  static const String _kHash = 'lock.pin_hash';
  static const String _kSalt = 'lock.pin_salt';

  /// True when a PIN has been previously set via [setPin].
  Future<bool> hasPin() async {
    final hash = await _storage.read(key: _kHash);
    final salt = await _storage.read(key: _kSalt);
    return hash != null &&
        hash.isNotEmpty &&
        salt != null &&
        salt.isNotEmpty;
  }

  /// Sets (or replaces) the stored PIN. Generates a fresh 16-byte random
  /// salt every call so a rotated PIN gets a fresh hash even if the user
  /// re-uses the same digits.
  Future<void> setPin(String pin) async {
    final salt = _generateSalt();
    final digest = _digest(pin, salt);
    await _storage.write(key: _kSalt, value: salt);
    await _storage.write(key: _kHash, value: digest);
  }

  /// Returns true when `pin` matches the stored digest. Returns false if
  /// no PIN has been set yet.
  Future<bool> verify(String pin) async {
    final salt = await _storage.read(key: _kSalt);
    final stored = await _storage.read(key: _kHash);
    if (salt == null || stored == null) return false;
    final computed = _digest(pin, salt);
    return _constantTimeEquals(computed, stored);
  }

  /// Removes both the salt and the hash. Idempotent.
  Future<void> clear() async {
    await _storage.delete(key: _kHash);
    await _storage.delete(key: _kSalt);
  }

  // 16 random bytes, base64-encoded so it round-trips through SecureStorage.
  String _generateSalt() {
    final rng = Random.secure();
    final bytes = Uint8List(16);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = rng.nextInt(256);
    }
    return base64Encode(bytes);
  }

  // SHA-256(salt || pin), hex-encoded.
  String _digest(String pin, String saltB64) {
    final saltBytes = base64Decode(saltB64);
    final pinBytes = utf8.encode(pin);
    final input = Uint8List(saltBytes.length + pinBytes.length)
      ..setRange(0, saltBytes.length, saltBytes)
      ..setRange(saltBytes.length, saltBytes.length + pinBytes.length, pinBytes);
    return sha256.convert(input).toString();
  }

  // Constant-time compare to dodge timing leaks on PIN verification.
  bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
