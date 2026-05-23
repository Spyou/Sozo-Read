import 'dart:async';
import 'dart:io' show Platform;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../di/injection.dart';
import '../repository/voices_repository.dart';
import '../state/novel_prefs_cubit.dart';
import 'sherpa_tts_engine.dart';

/// Internal speech-engine contract. Two implementations exist —
/// `_FlutterTtsEngine` (the original OS-native path) and
/// `_SherpaTtsEngine` (neural / on-device via sherpa-onnx). The
/// service swaps between them based on [TtsEngine].
abstract class _TtsEngine {
  Future<void> warmup();
  Future<void> setRate(double rate);
  Future<void> setPitch(double pitch);
  Future<void> setVolume(double volume);
  Future<void> setLanguage(String code);
  Future<void> setVoice(Map<String, String> voice);
  Future<void> speak(String text);
  Future<void> stop();
  Future<void> dispose();
}

/// Text-to-Speech handler for the novel reader. Splits the chapter
/// body into paragraphs and walks them sequentially, exposing OS media
/// controls (lock-screen play/pause) via [BaseAudioHandler].
///
/// Lifecycle:
///   * `loadChapter(...)` prepares the queue (paragraphs + MediaItem)
///     but does NOT start speech — callers explicitly invoke `play()`.
///   * `play()` walks the paragraphs with awaitSpeakCompletion so
///     `seekToParagraph` can interrupt cleanly.
///   * `onChapterEnd` fires once after the last paragraph completes —
///     the reader screen uses this to auto-advance and reload.
///
/// Two engines are supported via the internal [_TtsEngine] interface:
///   * `TtsEngine.system` — flutter_tts wrapping the platform engine.
///   * `TtsEngine.neural` — sherpa-onnx running a downloaded Piper voice
///     on-device. Selected at `loadChapter` time from the prefs cubit;
///     swapping is cheap (a few hundred ms to dispose + rebuild).
class NovelTtsService extends BaseAudioHandler {
  NovelTtsService({NovelPrefsCubit? prefs}) : _prefs = prefs {
    // Start on the system engine — it has no model file to load and
    // is always available, so the first frame of the reader can call
    // play() before the user has touched anything.
    _engine = _FlutterTtsEngine();
    _activeEngineKind = TtsEngine.system;
    _readyFuture = _engine.warmup();
  }

  /// Late-injected prefs lookup. Held by reference so we always read
  /// the latest cubit state at `loadChapter` time without subscribing
  /// (subscribing would race with the audio_service handler init).
  NovelPrefsCubit? _prefs;

  /// Injection-time setter used by the DI graph + bootstrap to wire
  /// the prefs cubit lazily — avoids a circular dep between the
  /// `NovelTtsService` singleton and the cubit's own init.
  // ignore: use_setters_to_change_properties
  void attachPrefs(NovelPrefsCubit prefs) {
    _prefs = prefs;
  }

  late _TtsEngine _engine;
  late TtsEngine _activeEngineKind;
  List<String> _paragraphs = const [];
  int _index = 0;
  bool _playing = false;
  // Chapter-title intro. Read once at the top of `play()` for a freshly-
  // loaded chapter so the listener hears "Chapter 5: The Awakening"
  // before paragraph 0 — without this, auto-advance + manual chapter
  // navigation are silent on the boundary. Skipped when the user is
  // resuming mid-chapter (startParagraph > 0).
  String? _intro;
  bool _introSpoken = false;

  /// Snapshot of the current play state for sync callers (UI branching
  /// on "is TTS currently playing"). The stream-based `playbackState`
  /// remains the source of truth for reactive subscribers.
  bool get isPlaying => _playing;
  // Guards re-entrancy from the speech loop while pause/stop/seek are
  // racing the awaitSpeakCompletion future.
  int _runToken = 0;
  VoidCallback? _onChapterEnd;
  // Mirrored on the service for two reasons: (1) we re-apply them
  // every time the engine is swapped, and (2) callers read the
  // current language back via [currentLanguage].
  double _rate = 0.5;
  double _pitch = 1.0;
  double _volume = 1.0;
  String _currentLanguage = 'en-US';
  Map<String, String>? _pendingVoice;
  Map<String, String> _pronunciations = const <String, String>{};
  bool _skipMarkers = true;
  int _paragraphPauseMs = 300;
  bool _stopAtChapterEnd = false;
  final StreamController<int> _paragraphIndexController =
      StreamController<int>.broadcast();
  // Configuration is async (platform method-channel hops). play() and
  // loadChapter() await this so they don't race ahead of language /
  // rate setup — without it, the very first speak() on Android can
  // silently no-op because no voice has been selected yet.
  late Future<void> _readyFuture;

  /// Emits the current paragraph index every time the speech loop
  /// advances. Use this instead of polling [paragraphIndex] from UI.
  Stream<int> get paragraphIndexStream => _paragraphIndexController.stream;

  /// Last language tag handed to the active engine.
  String get currentLanguage => _currentLanguage;

  /// Currently-active engine kind. Useful for UI badges + telemetry.
  TtsEngine get activeEngine => _activeEngineKind;

  /// Returns the current paragraph index (0-based).
  int get paragraphIndex => _index;

  /// Returns the total paragraph count for the loaded chapter.
  int get paragraphCount => _paragraphs.length;

  /// Prepare the queue for a new chapter. The previous chapter (if
  /// any) is stopped and discarded. Caller must invoke `play()` to
  /// begin speech.
  Future<void> loadChapter({
    required String bookTitle,
    required String chapterTitle,
    required String text,
    required VoidCallback onChapterEnd,
    int startParagraph = 0,
  }) async {
    // Pick the right engine for the current user pref BEFORE we touch
    // the queue, so the warmup happens off the play() critical path.
    await _ensureEngineForPref();
    // Make sure the engine has finished configuring (language, rate,
    // audio category) before we hand it any text.
    await _readyFuture;
    await _engine.stop();
    _playing = false;
    _runToken++;
    _onChapterEnd = onChapterEnd;
    // Split on blank lines — the same heuristic novel providers use to
    // separate paragraphs in the body text. Empty entries are dropped
    // so trailing whitespace doesn't produce dead air at the end.
    _paragraphs = text
        .split(RegExp(r'\n\s*\n+'))
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList(growable: false);
    // Clamp the requested start index into the new paragraph range —
    // callers pass the reader's current scroll position so playback
    // begins from the visible paragraph instead of always from zero.
    if (_paragraphs.isEmpty) {
      _index = 0;
    } else {
      _index = startParagraph.clamp(0, _paragraphs.length - 1);
    }
    final introText = chapterTitle.trim();
    _intro = introText.isEmpty ? null : introText;
    // Suppress the intro when the user is resuming mid-chapter — they
    // don't want to hear the title again every time they unpause.
    _introSpoken = _index > 0;
    mediaItem.add(MediaItem(
      id: '$bookTitle::$chapterTitle',
      album: bookTitle,
      title: chapterTitle,
      playable: true,
    ));
    if (!_paragraphIndexController.isClosed) {
      _paragraphIndexController.add(_index);
    }
    _emitState(playing: false);
  }

  /// Update speech rate (0.0..1.0; native engines map this internally).
  ///
  /// Both flutter_tts and sherpa-onnx only apply rate changes on the
  /// NEXT `speak()` call — never to an utterance already in flight. So
  /// when [restartIfPlaying] is true (the live-drag case from the
  /// reader's speed slider), we cancel the current paragraph and
  /// re-enter `play()` at the same index so the new rate is audible
  /// within a beat instead of "after this paragraph finishes."
  Future<void> setRate(double rate, {bool restartIfPlaying = false}) async {
    _rate = rate.clamp(0.0, 1.0);
    try {
      await _engine.setRate(_rate);
    } catch (e) {
      debugPrint('[tts] setRate failed: $e');
      return;
    }
    if (!restartIfPlaying || !_playing) return;
    // Interrupt the current utterance and resume from the same
    // paragraph index — bumping _runToken lets the in-flight play loop
    // bail on its next checkpoint, and the intro guard stays set so
    // the chapter title doesn't replay mid-chapter.
    final resumeAt = _index;
    final wasIntroSpoken = _introSpoken;
    _runToken++;
    _playing = false;
    try {
      await _engine.stop();
    } catch (e) {
      debugPrint('[tts] stop-for-rate failed: $e');
    }
    _index = resumeAt;
    _introSpoken = wasIntroSpoken;
    // ignore: discarded_futures
    play();
  }

  @override
  Future<void> play() async {
    await _readyFuture;
    if (_paragraphs.isEmpty) return;
    if (_playing) return;
    _playing = true;
    final myToken = ++_runToken;
    _emitState(playing: true);
    if (!_paragraphIndexController.isClosed) {
      _paragraphIndexController.add(_index);
    }
    // Speak the chapter title once per fresh chapter — fires before the
    // first paragraph so auto-advance and manual nav have an audible
    // boundary ("Chapter 5: The Awakening" then body).
    final intro = _intro;
    if (intro != null && !_introSpoken) {
      _introSpoken = true;
      try {
        await _engine.speak(intro);
      } catch (e) {
        debugPrint('[tts] intro speak failed: $e');
      }
      if (!_playing || myToken != _runToken) return;
      // Brief beat after the title so it doesn't run into paragraph 0.
      if (_paragraphPauseMs > 0) {
        final slices = (_paragraphPauseMs / 50).ceil();
        for (var i = 0; i < slices; i++) {
          if (!_playing || myToken != _runToken) return;
          final remaining = _paragraphPauseMs - (i * 50);
          await Future<void>.delayed(
            Duration(milliseconds: remaining < 50 ? remaining : 50),
          );
        }
        if (!_playing || myToken != _runToken) return;
      }
    }
    while (_playing && _index < _paragraphs.length && myToken == _runToken) {
      final para = _applyAllRewrites(_paragraphs[_index]);
      try {
        await _engine.speak(para);
      } catch (e) {
        debugPrint('[tts] speak failed at $_index: $e');
        break;
      }
      // The user paused / seeked / stopped during the await — bail
      // before advancing so the next play() resumes correctly.
      if (!_playing || myToken != _runToken) return;
      // Inter-paragraph beat. Polled in small slices so a pause /
      // stop / seek mid-pause stops promptly rather than waiting out
      // a full 2-second sleep.
      if (_paragraphPauseMs > 0) {
        final slices = (_paragraphPauseMs / 50).ceil();
        for (var i = 0; i < slices; i++) {
          if (!_playing || myToken != _runToken) return;
          final remaining = _paragraphPauseMs - (i * 50);
          await Future<void>.delayed(
            Duration(milliseconds: remaining < 50 ? remaining : 50),
          );
        }
        if (!_playing || myToken != _runToken) return;
      }
      _index++;
      if (!_paragraphIndexController.isClosed) {
        _paragraphIndexController.add(_index);
      }
    }
    if (myToken != _runToken) return;
    _playing = false;
    if (_index >= _paragraphs.length) {
      _emitState(playing: false);
      if (!_stopAtChapterEnd) {
        final cb = _onChapterEnd;
        if (cb != null) cb();
      }
    } else {
      _emitState(playing: false);
    }
  }

  @override
  Future<void> pause() async {
    if (!_playing) return;
    _playing = false;
    _runToken++;
    try {
      await _engine.stop();
    } catch (_) {}
    _emitState(playing: false);
  }

  @override
  Future<void> stop() async {
    _playing = false;
    _runToken++;
    try {
      await _engine.stop();
    } catch (_) {}
    _index = 0;
    _emitState(playing: false);
    await super.stop();
    if (!_paragraphIndexController.isClosed) {
      await _paragraphIndexController.close();
    }
  }

  /// Hard reset for the reader UI: stops speech, clears the queue, and
  /// emits `mediaItem.add(null)` so the mini-player pill / OS media
  /// notification both hide. Distinct from [stop] because we keep the
  /// paragraph-index controller open — the user may start TTS again
  /// in the same session and we need that stream alive.
  Future<void> dismiss() async {
    _playing = false;
    _runToken++;
    try {
      await _engine.stop();
    } catch (_) {}
    _paragraphs = const [];
    _index = 0;
    _intro = null;
    _introSpoken = false;
    _onChapterEnd = null;
    mediaItem.add(null);
    _emitState(playing: false);
    if (!_paragraphIndexController.isClosed) {
      _paragraphIndexController.add(-1);
    }
  }

  /// Seek forward/backward by [delta] paragraphs and resume speech if
  /// playback was active. Clamps to the chapter bounds.
  Future<void> seekToParagraph(int delta) async {
    if (_paragraphs.isEmpty) return;
    final wasPlaying = _playing;
    _playing = false;
    _runToken++;
    try {
      await _engine.stop();
    } catch (_) {}
    final next = (_index + delta).clamp(0, _paragraphs.length - 1);
    _index = next;
    if (wasPlaying) {
      // ignore: discarded_futures
      play();
    } else {
      _emitState(playing: false);
    }
  }

  /// Wraps the active engine's language list. The system engine
  /// returns the OS's installed languages; the neural engine returns
  /// the singleton language of its loaded voice. Returns an empty
  /// list on failure.
  Future<List<dynamic>> availableLanguages() async {
    final e = _engine;
    if (e is _FlutterTtsEngine) {
      try {
        final raw = await e._tts.getLanguages;
        if (raw is List) return raw;
        return const [];
      } catch (err) {
        debugPrint('[tts] getLanguages failed: $err');
        return const [];
      }
    }
    return const [];
  }

  /// Wraps the active engine's voice list. Neural engines expose a
  /// single embedded voice — callers asking for voices on neural get
  /// an empty list (the voice catalog lives in `VoicesRepository`).
  Future<List<Map<String, String>>> availableVoices() async {
    final e = _engine;
    if (e is _FlutterTtsEngine) {
      try {
        final raw = await e._tts.getVoices;
        if (raw is! List) return const [];
        final out = <Map<String, String>>[];
        for (final item in raw) {
          if (item is Map) {
            final name = item['name'];
            final locale = item['locale'];
            if (name == null || locale == null) continue;
            out.add({'name': name.toString(), 'locale': locale.toString()});
          }
        }
        return out;
      } catch (err) {
        debugPrint('[tts] getVoices failed: $err');
        return const [];
      }
    }
    return const [];
  }

  Future<void> setLanguage(String code) async {
    if (code.isEmpty) return;
    _currentLanguage = code;
    try {
      await _engine.setLanguage(code);
    } catch (e) {
      debugPrint('[tts] setLanguage failed: $e');
    }
  }

  Future<void> setVoice(Map<String, String> voice) async {
    if (voice.isEmpty) return;
    _pendingVoice = voice;
    try {
      await _engine.setVoice(voice);
    } catch (e) {
      debugPrint('[tts] setVoice failed: $e');
    }
  }

  Future<void> setPitch(double pitch) async {
    _pitch = pitch.clamp(0.5, 2.0);
    try {
      await _engine.setPitch(_pitch);
    } catch (e) {
      debugPrint('[tts] setPitch failed: $e');
    }
  }

  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);
    try {
      await _engine.setVolume(_volume);
    } catch (e) {
      debugPrint('[tts] setVolume failed: $e');
    }
  }

  /// Wraps `flutter_tts.synthesizeToFile`. Returns the resulting file
  /// path on success (Android passes back the absolute path; iOS may
  /// return a status string) or null on failure. Only the system
  /// engine implements this — neural always returns null because its
  /// natural unit is in-memory PCM, not a managed file path.
  Future<String?> synthesizeToFile(String text, String filePath) async {
    final e = _engine;
    if (e is _FlutterTtsEngine) {
      try {
        final result = await e._tts.synthesizeToFile(text, filePath);
        return result?.toString();
      } catch (err) {
        debugPrint('[tts] synthesizeToFile failed: $err');
        return null;
      }
    }
    return null;
  }

  /// Pronunciation overrides. Keys are normalised to lowercase here so
  /// `_applyAllRewrites` can do a single `Map[]` lookup per token.
  void setPronunciations(Map<String, String> map) {
    _pronunciations = <String, String>{
      for (final e in map.entries) e.key.toLowerCase(): e.value,
    };
  }

  void setSkipMarkers(bool v) {
    _skipMarkers = v;
  }

  void setParagraphPauseMs(int ms) {
    _paragraphPauseMs = ms.clamp(0, 2000);
  }

  void setStopAtChapterEnd(bool v) {
    _stopAtChapterEnd = v;
  }

  /// Cleans + rewrites a paragraph before it's handed to `speak()`.
  ///
  /// Order matters: marker glyphs (`***`, `<i>`, `[note: ...]`) are
  /// dropped first so they don't accidentally become pronunciation
  /// match-points, then word-level pronunciation rewrites run. We use
  /// `\b` boundaries so "Kael" doesn't accidentally rewrite inside
  /// "Kaeling".
  String _applyAllRewrites(String paragraph) {
    var out = paragraph;
    if (_skipMarkers) {
      // HTML-ish tags first — `<i>foo</i>` should collapse to `foo`,
      // not be eaten entirely.
      out = out.replaceAll(RegExp(r'<[^>]+>'), '');
      // Bracketed editor / scene notes: `[note: ...]`, `[a/n: ...]`.
      out = out.replaceAll(RegExp(r'\[[^\]]*\]'), '');
      // Common scene-break glyphs.
      out = out.replaceAll(RegExp(r'\*{2,}'), '');
      out = out.replaceAll(RegExp(r'-{3,}'), '');
      out = out.replaceAll(RegExp(r'—{2,}'), '');
      out = out.replaceAll(RegExp(r'~{2,}'), '');
      // Single asterisks used for emphasis.
      out = out.replaceAll('*', '');
      out = out.trim();
    }
    if (_pronunciations.isNotEmpty) {
      // Word-by-word so we honour `\b` boundaries without compiling a
      // separate RegExp per entry on every paragraph. Whitespace and
      // punctuation get re-attached unchanged.
      out = out.splitMapJoin(
        RegExp(r'[A-Za-z][A-Za-z’]*'),
        onMatch: (m) {
          final word = m[0]!;
          final replacement = _pronunciations[word.toLowerCase()];
          return replacement ?? word;
        },
        onNonMatch: (s) => s,
      );
    }
    return out;
  }

  /// Push a [PlaybackState] update so the OS notification and the
  /// in-app sheet reflect the current state.
  void _emitState({required bool playing}) {
    playbackState.add(PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.stop,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.play,
        MediaAction.pause,
        MediaAction.stop,
        MediaAction.skipToNext,
        MediaAction.skipToPrevious,
      },
      androidCompactActionIndices: const [0, 1, 3],
      processingState: AudioProcessingState.ready,
      playing: playing,
      updatePosition: Duration.zero,
    ));
  }

  @override
  Future<void> skipToNext() => seekToParagraph(1);

  @override
  Future<void> skipToPrevious() => seekToParagraph(-1);

  /// Force a neural-engine warmup with the currently-selected voice
  /// (if any). Called from `AppBootstrap` after the prefs cubit + the
  /// audio_service handler are both wired up so the user's first
  /// `play()` doesn't pay the cold-start model-load latency.
  Future<void> warmupNeural() async {
    final prefs = _prefs;
    if (prefs == null) return;
    if (prefs.state.ttsEngine != TtsEngine.neural) return;
    await _ensureEngineForPref();
    await _readyFuture;
  }

  /// Resolves the engine pref + voice paths, then ensures `_engine`
  /// matches. Cheap when the engine is already correct.
  Future<void> _ensureEngineForPref() async {
    final prefs = _prefs;
    final desired = prefs?.state.ttsEngine ?? TtsEngine.system;
    final voiceId = prefs?.state.ttsNeuralVoiceId;

    // Neural requested but no voice picked — fall back to system and
    // surface a single debug warning so settings UI can guide users.
    if (desired == TtsEngine.neural && (voiceId == null || voiceId.isEmpty)) {
      debugPrint(
        '[tts] neural engine requested but no voice selected — falling back to system',
      );
      await _swapEngine(TtsEngine.system);
      return;
    }

    if (desired == TtsEngine.neural) {
      final paths = await _resolveNeuralVoicePaths(voiceId!);
      if (paths == null) {
        debugPrint(
          '[tts] neural voice "$voiceId" not found on disk — falling back to system',
        );
        await _swapEngine(TtsEngine.system);
        return;
      }
      await _swapEngine(
        TtsEngine.neural,
        voicePaths: paths,
      );
      return;
    }
    await _swapEngine(TtsEngine.system);
  }

  Future<void> _swapEngine(
    TtsEngine kind, {
    SherpaVoicePaths? voicePaths,
  }) async {
    if (kind == _activeEngineKind) {
      // The user may have picked a different neural voice without
      // changing the engine kind — rebuild in that case.
      if (kind == TtsEngine.neural &&
          voicePaths != null &&
          _engine is _SherpaTtsEngineAdapter) {
        final current = (_engine as _SherpaTtsEngineAdapter).voicePaths;
        if (current.model == voicePaths.model &&
            current.tokens == voicePaths.tokens &&
            current.dataDir == voicePaths.dataDir) {
          return;
        }
      } else {
        return;
      }
    }
    try {
      await _engine.dispose();
    } catch (_) {}
    if (kind == TtsEngine.neural && voicePaths != null) {
      _engine = _SherpaTtsEngineAdapter(voicePaths: voicePaths);
    } else {
      _engine = _FlutterTtsEngine();
    }
    _activeEngineKind = kind;
    // Push the cached config into the new engine before any speak()
    // hits it — these calls are cheap no-ops if the values match the
    // engine defaults.
    _readyFuture = () async {
      await _engine.warmup();
      try {
        await _engine.setRate(_rate);
      } catch (_) {}
      try {
        await _engine.setPitch(_pitch);
      } catch (_) {}
      try {
        await _engine.setVolume(_volume);
      } catch (_) {}
      try {
        await _engine.setLanguage(_currentLanguage);
      } catch (_) {}
      final v = _pendingVoice;
      if (v != null && v.isNotEmpty) {
        try {
          await _engine.setVoice(v);
        } catch (_) {}
      }
    }();
  }

  /// Looks up where the user's downloaded voice lives via the
  /// installed-voices catalog. Returns null when the id isn't
  /// installed; the caller falls back to the system engine.
  Future<SherpaVoicePaths?> _resolveNeuralVoicePaths(String voiceId) async {
    try {
      return sl<VoicesRepository>().pathFor(voiceId);
    } catch (e) {
      debugPrint('[tts] resolve neural voice paths failed: $e');
      return null;
    }
  }
}

/// Original OS-native engine, refactored behind the engine interface.
class _FlutterTtsEngine implements _TtsEngine {
  final FlutterTts _tts = FlutterTts();

  @override
  Future<void> warmup() async {
    // iOS playback category enables audio output even when the silent
    // switch is on, plus Bluetooth + mixing with other apps (background
    // music apps stay playing at reduced volume).
    if (Platform.isIOS) {
      try {
        await _tts.setIosAudioCategory(
          IosTextToSpeechAudioCategory.playback,
          [
            IosTextToSpeechAudioCategoryOptions.allowBluetooth,
            IosTextToSpeechAudioCategoryOptions.allowBluetoothA2DP,
            IosTextToSpeechAudioCategoryOptions.mixWithOthers,
          ],
          IosTextToSpeechAudioMode.spokenAudio,
        );
      } catch (e) {
        debugPrint('[tts] iOS audio category failed: $e');
      }
    }
    await _tts.awaitSpeakCompletion(true);
    // Setting a language is REQUIRED on Android — without it, speak()
    // silently no-ops because no voice has been selected. Try the
    // device default first; fall back to en-US which Android Speech
    // Services always ships.
    try {
      await _tts.setLanguage('en-US');
    } catch (e) {
      debugPrint('[tts] setLanguage failed: $e');
    }
    if (Platform.isAndroid) {
      // Some Xiaomi / Vivo OEMs ship without a working TTS engine. If
      // the device is missing one, speak() returns 0 (queued) but no
      // sound plays. Surface that early so the UI can show an error.
      try {
        final engines = await _tts.getEngines;
        if (engines is List && engines.isEmpty) {
          debugPrint('[tts] no TTS engine installed on this device');
        }
      } catch (_) {/* getEngines is best-effort */}
    }
  }

  @override
  Future<void> setRate(double rate) => _tts.setSpeechRate(rate);

  @override
  Future<void> setPitch(double pitch) => _tts.setPitch(pitch);

  @override
  Future<void> setVolume(double volume) => _tts.setVolume(volume);

  @override
  Future<void> setLanguage(String code) => _tts.setLanguage(code);

  @override
  Future<void> setVoice(Map<String, String> voice) => _tts.setVoice(voice);

  @override
  Future<void> speak(String text) async {
    await _tts.speak(text);
  }

  @override
  Future<void> stop() async {
    await _tts.stop();
  }

  @override
  Future<void> dispose() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }
}

/// Adapter that bridges the public [SherpaTtsEngine] (defined in its
/// own file so the platform-specific code stays out of this header)
/// onto the private [_TtsEngine] interface the service speaks.
class _SherpaTtsEngineAdapter implements _TtsEngine {
  _SherpaTtsEngineAdapter({required this.voicePaths})
      : _inner = SherpaTtsEngine(voicePaths: voicePaths);

  final SherpaVoicePaths voicePaths;
  final SherpaTtsEngine _inner;

  @override
  Future<void> warmup() => _inner.warmup();

  @override
  Future<void> setRate(double rate) => _inner.setRate(rate);

  @override
  Future<void> setPitch(double pitch) => _inner.setPitch(pitch);

  @override
  Future<void> setVolume(double volume) => _inner.setVolume(volume);

  @override
  Future<void> setLanguage(String code) => _inner.setLanguage(code);

  @override
  Future<void> setVoice(Map<String, String> voice) => _inner.setVoice(voice);

  @override
  Future<void> speak(String text) => _inner.speak(text);

  @override
  Future<void> stop() => _inner.stop();

  @override
  Future<void> dispose() => _inner.dispose();
}
