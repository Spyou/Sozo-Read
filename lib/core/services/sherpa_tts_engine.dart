import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

/// Resolved on-disk paths for a single Piper voice. Built by
/// [NovelTtsService] from the active `ttsNeuralVoiceId` pref and the
/// future `VoicesRepository.pathFor(voiceId)` lookup.
class SherpaVoicePaths {
  const SherpaVoicePaths({
    required this.model,
    required this.tokens,
    required this.dataDir,
  });

  /// Path to the Piper `.onnx` model file.
  final String model;

  /// Path to the model's `tokens.txt` (phoneme table).
  final String tokens;

  /// Directory containing the `espeak-ng-data` tree. Piper voices ship
  /// it inside the voice archive.
  final String dataDir;
}

/// Neural / on-device TTS engine backed by sherpa-onnx.
///
/// Loads a Piper-format voice (`model.onnx` + `tokens.txt` +
/// `espeak-ng-data/`) at construction, then on every `speak(text)`:
///
///   1. Calls `_tts.generate(text, speed: ...)` on a background isolate.
///      (k2-fsa runs the ONNX session synchronously, but each
///      paragraph is bounded so blocking the platform thread for ~1s
///      is acceptable — flutter_tts has the same characteristic.)
///   2. Writes the returned PCM samples to a temp WAV file.
///   3. Plays the WAV via `audioplayers` and awaits completion.
///
/// Pitch is not supported by Piper VITS voices — only Coqui-style
/// models expose a pitch knob. We treat `setPitch` as a no-op on this
/// engine and document the gap in the settings UI.
class SherpaTtsEngine {
  SherpaTtsEngine({required this.voicePaths});

  final SherpaVoicePaths voicePaths;

  sherpa_onnx.OfflineTts? _tts;
  final AudioPlayer _player = AudioPlayer();
  // Maps the service's 0..1 rate slider onto sherpa's `speed` knob.
  // sherpa accepts roughly 0.5..1.7 for natural-sounding speech; we
  // centre our default rate (0.5) at 1.1x (slightly above neutral)
  // because Piper voices read a touch slow at 1.0x.
  double _speed = 1.1;
  double _volume = 1.0;
  // Counter to invalidate in-flight speak() awaits when stop() is
  // called mid-playback. Mirrors `NovelTtsService._runToken`.
  int _runToken = 0;
  // Temp files are written into the OS temp dir and rotated per
  // paragraph. Keeping the path so we can delete it on dispose.
  String? _lastTempWav;
  // Initialised lazily on the first call to ensure native bindings
  // are loaded — `sherpa_onnx.initBindings()` is safe to call
  // repeatedly so we cache the boolean result for short-circuiting.
  static bool _bindingsReady = false;

  Future<void> warmup() async {
    if (!_bindingsReady) {
      try {
        sherpa_onnx.initBindings();
        _bindingsReady = true;
      } catch (e) {
        // Native library not present in this build flavour (e.g. test
        // runner). Throw so the service can fall back to system.
        throw StateError('sherpa-onnx native bindings unavailable: $e');
      }
    }
    if (!File(voicePaths.model).existsSync() ||
        !File(voicePaths.tokens).existsSync()) {
      throw StateError(
        'sherpa-onnx voice files missing at ${voicePaths.model}',
      );
    }
    final cfg = sherpa_onnx.OfflineTtsConfig(
      model: sherpa_onnx.OfflineTtsModelConfig(
        vits: sherpa_onnx.OfflineTtsVitsModelConfig(
          model: voicePaths.model,
          tokens: voicePaths.tokens,
          dataDir: voicePaths.dataDir,
        ),
        numThreads: 2,
        debug: false,
        provider: 'cpu',
      ),
    );
    _tts = sherpa_onnx.OfflineTts(cfg);
  }

  Future<void> setRate(double rate) async {
    // Service contract is 0..1. Map onto sherpa's natural range so
    // the slider behaves intuitively: 0 -> 0.5x (very slow), 1 -> 1.7x.
    _speed = (rate.clamp(0.0, 1.0) * 1.2) + 0.5;
  }

  Future<void> setPitch(double pitch) async {
    // Not supported on Piper / VITS. Silently accepted so the
    // service's pref-seeding code doesn't choke. Documented in the
    // service header.
  }

  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);
    try {
      await _player.setVolume(_volume);
    } catch (_) {/* best-effort */}
  }

  Future<void> setLanguage(String code) async {
    // No-op — Piper voices are single-language and the active voice
    // already encodes which language it speaks.
  }

  Future<void> setVoice(Map<String, String> voice) async {
    // No-op — voice selection is handled at the `voicePaths` level,
    // not via the engine API. The service keeps `setVoice` for
    // compatibility with the system engine.
  }

  Future<void> speak(String text) async {
    final tts = _tts;
    if (tts == null) return;
    if (text.trim().isEmpty) return;
    final myToken = ++_runToken;
    sherpa_onnx.GeneratedAudio audio;
    try {
      audio = tts.generate(text: text, sid: 0, speed: _speed);
    } catch (e) {
      debugPrint('[tts][neural] generate failed: $e');
      return;
    }
    if (myToken != _runToken) return;
    if (audio.samples.isEmpty || audio.sampleRate == 0) return;
    final wavPath = await _writeTempWav(audio);
    if (wavPath == null) return;
    if (myToken != _runToken) return;
    _lastTempWav = wavPath;
    final completer = Completer<void>();
    // Bridge audioplayers' callback-style completion to a future the
    // service can await alongside its own _runToken guards.
    late StreamSubscription<void> sub;
    sub = _player.onPlayerComplete.listen((_) {
      if (!completer.isCompleted) completer.complete();
      // ignore: discarded_futures
      sub.cancel();
    });
    try {
      await _player.setVolume(_volume);
      await _player.play(DeviceFileSource(wavPath));
    } catch (e) {
      debugPrint('[tts][neural] play failed: $e');
      await sub.cancel();
      return;
    }
    try {
      await completer.future;
    } catch (_) {/* swallow */} finally {
      await sub.cancel();
    }
  }

  Future<void> stop() async {
    _runToken++;
    try {
      await _player.stop();
    } catch (_) {}
  }

  Future<void> dispose() async {
    _runToken++;
    try {
      await _player.dispose();
    } catch (_) {}
    try {
      _tts?.free();
    } catch (_) {}
    _tts = null;
    final last = _lastTempWav;
    if (last != null) {
      try {
        final f = File(last);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
  }

  Future<String?> _writeTempWav(sherpa_onnx.GeneratedAudio audio) async {
    try {
      final dir = await getTemporaryDirectory();
      // Use the run-token in the filename so concurrent paragraphs
      // (shouldn't happen with our serial loop, but defensive) don't
      // overwrite each other's bytes mid-playback.
      final path = '${dir.path}/sozo_neural_tts_$_runToken.wav';
      final ok = sherpa_onnx.writeWave(
        filename: path,
        samples: audio.samples,
        sampleRate: audio.sampleRate,
      );
      if (!ok) return null;
      return path;
    } catch (e) {
      debugPrint('[tts][neural] writeWave failed: $e');
      return null;
    }
  }
}
