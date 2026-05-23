import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive/hive.dart';

import '../services/ai/ai_models.dart';

/// AI integration preferences.
///
/// Mixed storage by sensitivity:
///   * `apiKey` — secret. Stored in `flutter_secure_storage` (Android
///     Keystore / iOS Keychain). NEVER persisted to Hive.
///   * `enabled` and `model` — non-secret. Persisted in the shared
///     `settings` Hive box alongside the reader prefs so the AI screen
///     can read them synchronously on first paint.
///
/// The cubit emits `apiKeyPresent` rather than the key itself so the
/// settings UI can branch on "is the user set up?" without holding the
/// secret in state.
class AiPrefs extends Equatable {
  const AiPrefs({
    required this.enabled,
    required this.model,
    required this.apiKeyPresent,
  });

  /// Master toggle. When false, AI features are hidden from the
  /// reader toolbar so the ✨ icon doesn't appear for users who never
  /// supplied a key.
  final bool enabled;

  /// Currently selected Gemini model. The summary calls pick this up
  /// at request time so the user can flip mid-session.
  final AiModel model;

  /// True when an API key is stored. The actual value is read on
  /// demand from secure storage; we never copy it into Bloc state.
  final bool apiKeyPresent;

  AiPrefs copyWith({bool? enabled, AiModel? model, bool? apiKeyPresent}) {
    return AiPrefs(
      enabled: enabled ?? this.enabled,
      model: model ?? this.model,
      apiKeyPresent: apiKeyPresent ?? this.apiKeyPresent,
    );
  }

  @override
  List<Object?> get props => [enabled, model, apiKeyPresent];
}

class AiPrefsCubit extends Cubit<AiPrefs> {
  AiPrefsCubit({
    FlutterSecureStorage? storage,
    String boxName = 'settings',
  })  : _storage = storage ?? const FlutterSecureStorage(),
        _boxName = boxName,
        super(const AiPrefs(
          enabled: false,
          model: AiModel.gemini35Flash,
          apiKeyPresent: false,
        ));

  final FlutterSecureStorage _storage;
  final String _boxName;

  static const String _kEnabled = 'ai.enabled';
  static const String _kModel = 'ai.model';
  // Secure-storage key — distinct prefix so it can't collide with the
  // PIN storage (`lock.*`) or tracker tokens.
  static const String _kApiKey = 'ai.gemini_api_key';

  Box get _box => Hive.box(_boxName);

  /// Hydrates state from disk. Safe to call multiple times — emits the
  /// same state if nothing changed.
  Future<void> load() async {
    final enabled = (_box.get(_kEnabled) as bool?) ?? false;
    final modelId = _box.get(_kModel) as String?;
    final key = await _storage.read(key: _kApiKey);
    emit(state.copyWith(
      enabled: enabled,
      model: AiModel.fromApiId(modelId),
      apiKeyPresent: key != null && key.isNotEmpty,
    ));
  }

  /// Reads the API key on demand. Returns null when no key is set.
  /// Callers (the Gemini client) only need this at request time.
  Future<String?> readApiKey() => _storage.read(key: _kApiKey);

  Future<void> setApiKey(String key) async {
    final trimmed = key.trim();
    if (trimmed.isEmpty) {
      await _storage.delete(key: _kApiKey);
      emit(state.copyWith(apiKeyPresent: false));
      return;
    }
    await _storage.write(key: _kApiKey, value: trimmed);
    emit(state.copyWith(apiKeyPresent: true));
  }

  Future<void> clearApiKey() async {
    await _storage.delete(key: _kApiKey);
    emit(state.copyWith(apiKeyPresent: false));
  }

  void setEnabled(bool v) {
    if (v == state.enabled) return;
    _box.put(_kEnabled, v);
    emit(state.copyWith(enabled: v));
  }

  void setModel(AiModel m) {
    if (m == state.model) return;
    _box.put(_kModel, m.apiId);
    emit(state.copyWith(model: m));
  }
}
