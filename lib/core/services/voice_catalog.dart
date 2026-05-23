/// Quality tier of a neural voice. Drives sort order + UI labels —
/// `high` voices sound noticeably better but ship 2-3x larger model
/// files, so users on small phones may want to stick to `medium`.
enum VoiceQuality { low, medium, high }

/// Speaker gender as advertised by the upstream Piper voice card.
/// `unknown` is reserved for voices that don't disclose it (e.g. the
/// LibriTTS multi-speaker bundle, which contains many speakers).
enum VoiceGender { female, male, unknown }

/// A curated Piper voice that the in-app downloader can install.
///
/// Pure data — no IO. The catalog lives in [VoiceCatalog.all]; the
/// actual files land on disk via `VoiceDownloader` and the
/// installed-state lookup goes through `VoicesRepository`.
class NeuralVoice {
  const NeuralVoice({
    required this.id,
    required this.displayName,
    required this.language,
    required this.gender,
    required this.quality,
    required this.archiveUrl,
    required this.approxSizeBytes,
  });

  /// Stable ID matching the upstream sherpa-onnx release naming:
  /// `<lang>_<region>-<speaker>-<quality>`, e.g. `en_US-amy-medium`.
  /// Persisted in prefs as `ttsNeuralVoiceId`.
  final String id;

  /// Human-readable label shown in the voice picker.
  final String displayName;

  /// BCP-47 language tag, e.g. `en-US` / `en-GB`.
  final String language;

  final VoiceGender gender;
  final VoiceQuality quality;

  /// Direct download URL of the `.tar.bz2` voice bundle on the
  /// sherpa-onnx GitHub release.
  final String archiveUrl;

  /// Approximate uncompressed footprint on disk after extraction.
  /// Used by the voice-picker UI to warn users before they download
  /// the bigger high-quality voices.
  final int approxSizeBytes;
}

/// Curated set of Piper voices we ship in the catalog. All entries
/// resolve to a sherpa-onnx-models release tarball — adding a new
/// voice only requires another const entry here.
class VoiceCatalog {
  const VoiceCatalog._();

  static String _urlFor(String id) =>
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-$id.tar.bz2';

  /// All voices the app knows about. Order is intentional — medium
  /// quality first (good size-to-quality tradeoff) then high.
  static const List<NeuralVoice> all = <NeuralVoice>[
    NeuralVoice(
      id: 'en_US-amy-medium',
      displayName: 'Amy (American English, medium quality)',
      language: 'en-US',
      gender: VoiceGender.female,
      quality: VoiceQuality.medium,
      archiveUrl:
          'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-amy-medium.tar.bz2',
      approxSizeBytes: 63 * 1024 * 1024,
    ),
    NeuralVoice(
      id: 'en_US-lessac-medium',
      displayName: 'Lessac (American English, medium quality)',
      language: 'en-US',
      gender: VoiceGender.female,
      quality: VoiceQuality.medium,
      archiveUrl:
          'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-lessac-medium.tar.bz2',
      approxSizeBytes: 63 * 1024 * 1024,
    ),
    NeuralVoice(
      id: 'en_US-joe-medium',
      displayName: 'Joe (American English, medium quality)',
      language: 'en-US',
      gender: VoiceGender.male,
      quality: VoiceQuality.medium,
      archiveUrl:
          'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-joe-medium.tar.bz2',
      approxSizeBytes: 63 * 1024 * 1024,
    ),
    NeuralVoice(
      id: 'en_GB-alan-medium',
      displayName: 'Alan (British English, medium quality)',
      language: 'en-GB',
      gender: VoiceGender.male,
      quality: VoiceQuality.medium,
      archiveUrl:
          'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_GB-alan-medium.tar.bz2',
      approxSizeBytes: 63 * 1024 * 1024,
    ),
    NeuralVoice(
      id: 'en_GB-alba-medium',
      displayName: 'Alba (British English, medium quality)',
      language: 'en-GB',
      gender: VoiceGender.female,
      quality: VoiceQuality.medium,
      archiveUrl:
          'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_GB-alba-medium.tar.bz2',
      approxSizeBytes: 63 * 1024 * 1024,
    ),
    NeuralVoice(
      id: 'en_US-libritts-high',
      displayName: 'LibriTTS (American English, high quality, multi-speaker)',
      language: 'en-US',
      gender: VoiceGender.unknown,
      quality: VoiceQuality.high,
      archiveUrl:
          'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-libritts-high.tar.bz2',
      approxSizeBytes: 124 * 1024 * 1024,
    ),
  ];

  /// Look up a voice by id. Returns null if the id isn't in the
  /// curated catalog (e.g. a stale pref pointing at a removed voice).
  static NeuralVoice? byId(String id) {
    for (final v in all) {
      if (v.id == id) return v;
    }
    return null;
  }

  /// Helper so other call-sites can build the canonical URL for an id
  /// without depending on the literal entries above.
  static String archiveUrlFor(String id) => _urlFor(id);
}
