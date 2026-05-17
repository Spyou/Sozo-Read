import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Direct-from-device uploader for Cloudinary using an *unsigned* upload
/// preset. The preset is created in the Cloudinary dashboard with signing
/// mode = Unsigned, which is what makes mobile uploads safe without shipping
/// the API secret.
class CloudinaryService {
  CloudinaryService({required Dio dio}) : _dio = dio;

  final Dio _dio;

  String? get _cloudName => dotenv.maybeGet('CLOUDINARY_CLOUD_NAME');
  String? get _uploadPreset => dotenv.maybeGet('CLOUDINARY_UPLOAD_PRESET');

  bool get isConfigured =>
      (_cloudName?.isNotEmpty ?? false) && (_uploadPreset?.isNotEmpty ?? false);

  /// Uploads [file] under the configured unsigned preset and returns the
  /// resulting `secure_url`. Caller decides where to persist it (we save to
  /// Supabase user_metadata via [AuthService.updateProfile]).
  ///
  /// [publicId] lets us namespace the avatar by user ID, so re-uploading
  /// replaces the previous file rather than piling up new ones.
  Future<String> uploadAvatar(File file, {String? publicId}) async {
    if (!isConfigured) {
      throw StateError(
        'Cloudinary is not configured. Check CLOUDINARY_CLOUD_NAME and '
        'CLOUDINARY_UPLOAD_PRESET in .env.',
      );
    }
    final url =
        'https://api.cloudinary.com/v1_1/${_cloudName!}/image/upload';

    final form = FormData.fromMap({
      'upload_preset': _uploadPreset!,
      'public_id': ?publicId,
      'file': await MultipartFile.fromFile(file.path),
    });

    try {
      debugPrint('[cloudinary] POST $url (file=${file.path})');
      final resp = await _dio.post<Map<String, dynamic>>(
        url,
        data: form,
        options: Options(
          // Tight enough to fail fast on a stalled mobile connection, loose
          // enough to handle a slow LTE upload of a 1024px JPEG (~200 KB).
          sendTimeout: const Duration(seconds: 20),
          receiveTimeout: const Duration(seconds: 20),
          // We send anonymous (unsigned) — strip any auth headers Dio might
          // have inherited from prior requests.
          headers: const {'Authorization': null},
        ),
      );
      debugPrint('[cloudinary] upload ok: ${resp.data?['secure_url']}');
      final data = resp.data;
      if (data == null) {
        throw StateError('Cloudinary returned an empty response.');
      }
      final secureUrl = data['secure_url'] as String?;
      if (secureUrl == null || secureUrl.isEmpty) {
        throw StateError('Cloudinary response missing secure_url: $data');
      }
      return secureUrl;
    } on DioException catch (e) {
      // Cloudinary error payloads look like {"error": {"message": "..."}}.
      final body = e.response?.data;
      String? cloudMsg;
      if (body is Map && body['error'] is Map) {
        cloudMsg = (body['error'] as Map)['message']?.toString();
      }
      debugPrint('[cloudinary] upload failed: ${cloudMsg ?? e.message}');
      throw StateError(cloudMsg ?? 'Upload failed. Check your connection.');
    }
  }
}
