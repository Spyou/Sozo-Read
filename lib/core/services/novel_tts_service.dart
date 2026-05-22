import 'dart:async';
import 'dart:io' show Platform;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

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
class NovelTtsService extends BaseAudioHandler {
  NovelTtsService() {
    _readyFuture = _configure();
  }

  final FlutterTts _tts = FlutterTts();
  List<String> _paragraphs = const [];
  int _index = 0;
  bool _playing = false;
  // Guards re-entrancy from the speech loop while pause/stop/seek are
  // racing the awaitSpeakCompletion future.
  int _runToken = 0;
  VoidCallback? _onChapterEnd;
  double _rate = 0.5;
  String _currentLanguage = 'en-US';
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
  late final Future<void> _readyFuture;

  /// Emits the current paragraph index every time the speech loop
  /// advances. Use this instead of polling [paragraphIndex] from UI.
  Stream<int> get paragraphIndexStream => _paragraphIndexController.stream;

  /// Last language tag handed to `flutter_tts.setLanguage`.
  String get currentLanguage => _currentLanguage;

  Future<void> _configure() async {
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
    await _tts.setSpeechRate(_rate);
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
    // Make sure the engine has finished configuring (language, rate,
    // audio category) before we hand it any text.
    await _readyFuture;
    await _tts.stop();
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
  Future<void> setRate(double rate) async {
    _rate = rate.clamp(0.0, 1.0);
    try {
      await _tts.setSpeechRate(_rate);
    } catch (e) {
      debugPrint('[tts] setSpeechRate failed: $e');
    }
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
    while (_playing && _index < _paragraphs.length && myToken == _runToken) {
      final para = _applyAllRewrites(_paragraphs[_index]);
      try {
        await _tts.speak(para);
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
      await _tts.stop();
    } catch (_) {}
    _emitState(playing: false);
  }

  @override
  Future<void> stop() async {
    _playing = false;
    _runToken++;
    try {
      await _tts.stop();
    } catch (_) {}
    _index = 0;
    _emitState(playing: false);
    await super.stop();
    if (!_paragraphIndexController.isClosed) {
      await _paragraphIndexController.close();
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
      await _tts.stop();
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

  /// Wraps `flutter_tts.getLanguages`. Returns the raw list (typically
  /// `List<String>` of BCP-47 tags) or an empty list on failure.
  Future<List<dynamic>> availableLanguages() async {
    try {
      final raw = await _tts.getLanguages;
      if (raw is List) return raw;
      return const [];
    } catch (e) {
      debugPrint('[tts] getLanguages failed: $e');
      return const [];
    }
  }

  /// Wraps `flutter_tts.getVoices`. The package returns `List<Object?>`
  /// where each entry is a `Map` like `{name: ..., locale: ...}`. We
  /// coerce to typed maps and drop malformed entries so callers can
  /// iterate safely.
  Future<List<Map<String, String>>> availableVoices() async {
    try {
      final raw = await _tts.getVoices;
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
    } catch (e) {
      debugPrint('[tts] getVoices failed: $e');
      return const [];
    }
  }

  Future<void> setLanguage(String code) async {
    if (code.isEmpty) return;
    _currentLanguage = code;
    try {
      await _tts.setLanguage(code);
    } catch (e) {
      debugPrint('[tts] setLanguage failed: $e');
    }
  }

  Future<void> setVoice(Map<String, String> voice) async {
    if (voice.isEmpty) return;
    try {
      await _tts.setVoice(voice);
    } catch (e) {
      debugPrint('[tts] setVoice failed: $e');
    }
  }

  Future<void> setPitch(double pitch) async {
    final clamped = pitch.clamp(0.5, 2.0);
    try {
      await _tts.setPitch(clamped);
    } catch (e) {
      debugPrint('[tts] setPitch failed: $e');
    }
  }

  Future<void> setVolume(double volume) async {
    final clamped = volume.clamp(0.0, 1.0);
    try {
      await _tts.setVolume(clamped);
    } catch (e) {
      debugPrint('[tts] setVolume failed: $e');
    }
  }

  /// Wraps `flutter_tts.synthesizeToFile`. Returns the resulting file
  /// path on success (Android passes back the absolute path; iOS may
  /// return a status string) or null on failure.
  Future<String?> synthesizeToFile(String text, String filePath) async {
    try {
      final result = await _tts.synthesizeToFile(text, filePath);
      return result?.toString();
    } catch (e) {
      debugPrint('[tts] synthesizeToFile failed: $e');
      return null;
    }
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
}
