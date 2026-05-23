import 'dart:convert';

import 'package:dio/dio.dart';

import '../../state/ai_prefs_cubit.dart';
import 'ai_client.dart';
import 'ai_models.dart';

/// Gemini implementation of [AiClient]. Hits the public v1beta REST
/// endpoint (no GCP project / OAuth required — the user-supplied API
/// key is the only credential). Multimodal payloads are sent inline
/// as base64 `inlineData` parts so we don't need the separate File API
/// upload step.
class GeminiAiClient implements AiClient {
  GeminiAiClient({required AiPrefsCubit prefs, Dio? dio})
      : _prefs = prefs,
        _dio = dio ?? Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 90),
              sendTimeout: const Duration(seconds: 60),
            ));

  final AiPrefsCubit _prefs;
  final Dio _dio;

  static const String _baseUrl =
      'https://generativelanguage.googleapis.com/v1beta';

  @override
  Future<String> summarize({
    required String prompt,
    String? text,
    List<AiImage>? images,
    required AiModel model,
  }) async {
    final hasText = text != null && text.trim().isNotEmpty;
    final hasImages = images != null && images.isNotEmpty;
    if (!hasText && !hasImages) {
      throw AiClientException('summarize() needs text or images',
          kind: AiErrorKind.badResponse);
    }
    final apiKey = await _prefs.readApiKey();
    if (apiKey == null || apiKey.isEmpty) {
      throw AiClientException(
        'No Gemini API key set.',
        kind: AiErrorKind.noApiKey,
      );
    }
    // Gemini accepts a list of `parts` per content turn. We always
    // send the instruction first so the model knows what to do with
    // the body that follows.
    final parts = <Map<String, dynamic>>[
      {'text': prompt},
      if (hasText) {'text': text},
      if (hasImages)
        for (final img in images)
          {
            'inlineData': {
              'mimeType': img.mimeType,
              'data': base64Encode(img.bytes),
            },
          },
    ];
    final body = {
      'contents': [
        {'role': 'user', 'parts': parts},
      ],
      // Conservative bounds: ~1500-token summaries are plenty for a
      // chapter, and capping protects users from runaway billing if
      // the model wanders.
      'generationConfig': {
        'temperature': 0.4,
        'maxOutputTokens': 1500,
      },
    };
    return _post(model: model, apiKey: apiKey, body: body);
  }

  @override
  Future<bool> ping({required AiModel model}) async {
    final apiKey = await _prefs.readApiKey();
    if (apiKey == null || apiKey.isEmpty) {
      throw AiClientException(
        'No Gemini API key set.',
        kind: AiErrorKind.noApiKey,
      );
    }
    final body = {
      'contents': [
        {
          'role': 'user',
          'parts': [
            {'text': 'Reply with the single word: ok'},
          ],
        }
      ],
      // 3.5 Flash (and other thinking models) spend reasoning tokens
      // *inside* the response budget. With a tiny output cap the
      // model burns all of them on thinking and emits empty parts —
      // which used to make ping() report "Empty text" even though
      // the key worked. Disable thinking and reserve enough tokens
      // for a one-word answer so the response always has text.
      'generationConfig': {
        'temperature': 0,
        'maxOutputTokens': 64,
        'thinkingConfig': {'thinkingBudget': 0},
      },
    };
    // Use the validating-but-text-tolerant path: we only care that
    // the API accepted the key (2xx response). An empty text body
    // here would still indicate auth + quota are fine.
    final url = '$_baseUrl/models/${model.apiId}:generateContent';
    Response<dynamic> resp;
    try {
      resp = await _dio.post<dynamic>(
        url,
        queryParameters: {'key': apiKey},
        data: body,
        options: Options(
          headers: {'Content-Type': 'application/json'},
          validateStatus: (_) => true,
        ),
      );
    } on DioException catch (e) {
      throw AiClientException(
        'Network error: ${e.message ?? e.type.name}',
        kind: AiErrorKind.network,
      );
    }
    final status = resp.statusCode ?? 0;
    if (status == 401 || status == 403) {
      throw AiClientException(
        'Invalid Gemini API key.',
        kind: AiErrorKind.invalidApiKey,
      );
    }
    if (status == 429) {
      throw AiClientException(
        'Daily Gemini quota hit.',
        kind: AiErrorKind.rateLimited,
      );
    }
    if (status < 200 || status >= 300) {
      final msg = _extractErrorMessage(resp.data) ?? 'HTTP $status';
      throw AiClientException(msg, kind: AiErrorKind.badResponse);
    }
    return true;
  }

  /// One-stop POST + response unpacking + error mapping. Concentrates
  /// all of the Gemini-specific JSON pathing in one place so the rest
  /// of the codebase only sees plain Dart errors.
  Future<String> _post({
    required AiModel model,
    required String apiKey,
    required Map<String, dynamic> body,
  }) async {
    final url = '$_baseUrl/models/${model.apiId}:generateContent';
    Response<dynamic> resp;
    try {
      resp = await _dio.post<dynamic>(
        url,
        queryParameters: {'key': apiKey},
        data: body,
        options: Options(
          headers: {'Content-Type': 'application/json'},
          // Don't throw inside Dio — we want to map status codes to
          // typed AiClientException ourselves.
          validateStatus: (_) => true,
        ),
      );
    } on DioException catch (e) {
      throw AiClientException(
        'Network error: ${e.message ?? e.type.name}',
        kind: AiErrorKind.network,
      );
    }
    final status = resp.statusCode ?? 0;
    final data = resp.data;
    if (status == 401 || status == 403) {
      throw AiClientException(
        'Invalid Gemini API key. Re-check it in Settings > AI integration.',
        kind: AiErrorKind.invalidApiKey,
      );
    }
    if (status == 429) {
      throw AiClientException(
        'Daily Gemini quota hit. Try again later or upgrade the key.',
        kind: AiErrorKind.rateLimited,
      );
    }
    if (status < 200 || status >= 300) {
      final msg = _extractErrorMessage(data) ?? 'HTTP $status';
      throw AiClientException(msg, kind: AiErrorKind.badResponse);
    }
    if (data is! Map) {
      throw AiClientException('Unexpected response shape',
          kind: AiErrorKind.badResponse);
    }
    final candidates = data['candidates'];
    if (candidates is! List || candidates.isEmpty) {
      // Some responses include only `promptFeedback` when the model
      // refused (e.g. safety filters). Surface that to the user.
      final feedback = data['promptFeedback'];
      if (feedback is Map && feedback['blockReason'] != null) {
        throw AiClientException(
          'Blocked by Gemini safety filters: ${feedback['blockReason']}',
          kind: AiErrorKind.badResponse,
        );
      }
      throw AiClientException('Empty response from Gemini',
          kind: AiErrorKind.badResponse);
    }
    final first = candidates.first;
    if (first is! Map) {
      throw AiClientException('Malformed candidate',
          kind: AiErrorKind.badResponse);
    }
    final content = first['content'];
    if (content is! Map) {
      throw AiClientException('Malformed content',
          kind: AiErrorKind.badResponse);
    }
    final parts = content['parts'];
    if (parts is! List || parts.isEmpty) {
      throw AiClientException('Empty parts',
          kind: AiErrorKind.badResponse);
    }
    // Concat all text parts — Gemini sometimes splits long answers
    // into multiple text segments within the same candidate.
    final out = StringBuffer();
    for (final p in parts) {
      if (p is Map && p['text'] is String) {
        out.write(p['text'] as String);
      }
    }
    final text = out.toString().trim();
    if (text.isEmpty) {
      throw AiClientException('Empty text from Gemini',
          kind: AiErrorKind.badResponse);
    }
    return text;
  }

  String? _extractErrorMessage(dynamic data) {
    if (data is! Map) return null;
    final err = data['error'];
    if (err is! Map) return null;
    final msg = err['message'];
    return msg is String ? msg : null;
  }
}
