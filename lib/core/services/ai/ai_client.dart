import 'dart:typed_data';

import 'ai_models.dart';

/// Thrown by [AiClient] when the user-supplied API key is missing,
/// invalid, or rate-limited. The reader UI converts these into
/// snackbar prompts (e.g. "Set up your API key" or "Daily quota
/// exhausted").
class AiClientException implements Exception {
  AiClientException(this.message, {this.kind = AiErrorKind.unknown});

  final String message;
  final AiErrorKind kind;

  @override
  String toString() => 'AiClientException($kind): $message';
}

enum AiErrorKind {
  noApiKey,
  invalidApiKey,
  rateLimited,
  network,
  badResponse,
  unknown,
}

/// One inline image payload for a multimodal request — the raw bytes
/// plus the MIME type Gemini needs (image/jpeg, image/png, image/webp,
/// or image/heic).
class AiImage {
  AiImage({required this.bytes, required this.mimeType});

  final Uint8List bytes;
  final String mimeType;
}

/// Abstract surface for AI features. The reader UIs depend on this,
/// not on Gemini specifically — keeps the door open for users to plug
/// in Anthropic / OpenAI / Groq later by registering a different
/// implementation in DI.
abstract class AiClient {
  /// Summarize the provided text and/or images using the given model.
  /// `prompt` is the instruction (e.g. "Summarize this manga chapter
  /// in 5 bullets"); `text` and `images` are the content. Either may
  /// be empty but not both.
  Future<String> summarize({
    required String prompt,
    String? text,
    List<AiImage>? images,
    required AiModel model,
  });

  /// Lightweight ping used by the AI settings screen's "Test
  /// connection" button. Returns true on success, throws on failure.
  Future<bool> ping({required AiModel model});
}
