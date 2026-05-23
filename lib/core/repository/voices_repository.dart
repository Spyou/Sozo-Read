import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../services/sherpa_tts_engine.dart';

/// Hive-backed catalog of installed neural voices. Each row maps a
/// voice id (`en_US-amy-medium`) to its resolved on-disk paths +
/// install metadata.
///
/// Storage shape under the box, keyed by voice id:
///
/// ```json
/// {
///   "installedAt": "2026-05-21T12:34:56.000Z",
///   "sizeBytes": 65000000,
///   "paths": {
///     "modelOnnx": "/.../neural_voices/en_US-amy-medium/en_US-amy-medium.onnx",
///     "tokens": "/.../neural_voices/en_US-amy-medium/tokens.txt",
///     "espeakDataDir": "/.../neural_voices/en_US-amy-medium/espeak-ng-data"
///   }
/// }
/// ```
///
/// The repo only stores metadata — it never copies / deletes the
/// actual files itself except in [remove], which is convenient
/// because the downloader writes the files but the repo owns the
/// "is this installed?" answer.
class VoicesRepository {
  static const String boxName = 'neural_voices';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await Hive.openBox<Map>(boxName);
    }
  }

  Box<Map> get _box => Hive.box<Map>(boxName);

  bool isInstalled(String id) => _box.containsKey(id);

  /// Resolves the stored on-disk paths for [id] into a
  /// [SherpaVoicePaths] the TTS engine can load. Returns null when
  /// the voice isn't installed or the stored row is unreadable.
  SherpaVoicePaths? pathFor(String id) {
    final raw = _box.get(id);
    if (raw == null) return null;
    try {
      final paths = Map<String, dynamic>.from(
        Map<String, dynamic>.from(raw)['paths'] as Map,
      );
      final model = paths['modelOnnx'] as String?;
      final tokens = paths['tokens'] as String?;
      final dataDir = paths['espeakDataDir'] as String?;
      if (model == null || tokens == null || dataDir == null) return null;
      return SherpaVoicePaths(
        model: model,
        tokens: tokens,
        dataDir: dataDir,
      );
    } catch (e) {
      debugPrint('[voices] pathFor("$id") decode failed: $e');
      return null;
    }
  }

  /// Sum of every installed voice's recorded sizeBytes. The downloader
  /// records the on-disk footprint at install time so subsequent
  /// totals don't need to walk the filesystem.
  int totalSizeBytes() {
    var total = 0;
    for (final raw in _box.values) {
      try {
        final size = Map<String, dynamic>.from(raw)['sizeBytes'];
        if (size is int) total += size;
        if (size is num) total += size.toInt();
      } catch (_) {
        // Skip corrupt rows rather than throw.
      }
    }
    return total;
  }

  List<String> installedIds() => _box.keys.cast<String>().toList();

  Future<void> markInstalled(
    String id,
    SherpaVoicePaths paths,
    int sizeBytes,
  ) async {
    await _box.put(id, <String, dynamic>{
      'installedAt': DateTime.now().toIso8601String(),
      'sizeBytes': sizeBytes,
      'paths': <String, dynamic>{
        'modelOnnx': paths.model,
        'tokens': paths.tokens,
        'espeakDataDir': paths.dataDir,
      },
    });
  }

  /// Removes the metadata row AND deletes the on-disk voice
  /// directory. The directory is derived from the stored model path —
  /// we delete its parent so the espeak data + tokens disappear too.
  Future<void> remove(String id) async {
    final paths = pathFor(id);
    if (paths != null) {
      try {
        final modelFile = File(paths.model);
        final dir = modelFile.parent;
        if (dir.existsSync()) {
          await dir.delete(recursive: true);
        }
      } catch (e) {
        debugPrint('[voices] remove("$id") fs cleanup failed: $e');
      }
    }
    await _box.delete(id);
  }

  /// Wipes every installed voice (metadata + on-disk files). Used by
  /// the storage-reset flow in settings.
  Future<void> clear() async {
    final ids = installedIds();
    for (final id in ids) {
      await remove(id);
    }
  }
}
