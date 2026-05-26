import 'package:dio/dio.dart';
import 'package:hive/hive.dart';

import '../error/exceptions.dart';

class CachedProvider {
  final String name;
  final String jsCode;
  final String url;
  final DateTime fetchedAt;

  CachedProvider({
    required this.name,
    required this.jsCode,
    required this.url,
    required this.fetchedAt,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'jsCode': jsCode,
        'url': url,
        'fetchedAt': fetchedAt.toIso8601String(),
      };

  factory CachedProvider.fromJson(Map<String, dynamic> j) => CachedProvider(
        name: j['name'] as String,
        jsCode: j['jsCode'] as String,
        url: j['url'] as String,
        fetchedAt: DateTime.parse(j['fetchedAt'] as String),
      );
}

/// Downloads provider JS files from GitHub raw URLs and caches them in Hive.
class ProviderDownloader {
  static const String boxName = 'provider_js_cache';
  static const Duration maxAge = Duration(hours: 24);

  ProviderDownloader({required Dio dio}) : _dio = dio;
  final Dio _dio;

  Box<Map> get _box => Hive.box<Map>(boxName);

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await Hive.openBox<Map>(boxName);
    }
  }

  Future<CachedProvider> fetch({
    required String name,
    required String url,
    bool force = false,
  }) async {
    final cached = _read(name);
    if (!force && cached != null && DateTime.now().difference(cached.fetchedAt) < maxAge) {
      return cached;
    }
    try {
      final resp = await _dio.getUri<String>(
        Uri.parse(url),
        options: Options(
          responseType: ResponseType.plain,
          validateStatus: (s) => s != null && s < 500,
          // raw.githubusercontent.com sits behind Fastly with a ~5 min
          // edge cache. Without this header, "force: true" still got us
          // stale JS — Fastly served the previous version even after a
          // fresh push. Same fix the directory service uses.
          headers: force ? {'Cache-Control': 'no-cache'} : null,
        ),
      );
      if (resp.statusCode == null || resp.statusCode! >= 400) {
        if (cached != null) return cached;
        throw NetworkException('Failed to download $name', statusCode: resp.statusCode);
      }
      final js = resp.data ?? '';
      if (js.trim().isEmpty) {
        if (cached != null) return cached;
        throw ProviderException('Downloaded provider $name is empty');
      }
      final entry = CachedProvider(name: name, jsCode: js, url: url, fetchedAt: DateTime.now());
      await _box.put(name, entry.toJson());
      return entry;
    } on DioException catch (e) {
      if (cached != null) return cached;
      throw NetworkException('Dio error: ${e.message}', statusCode: e.response?.statusCode);
    }
  }

  CachedProvider? _read(String name) {
    final raw = _box.get(name);
    if (raw == null) return null;
    return CachedProvider.fromJson(Map<String, dynamic>.from(raw));
  }

  CachedProvider? readCached(String name) => _read(name);

  Future<void> remove(String name) async {
    await _box.delete(name);
  }

  Future<void> clear() async {
    await _box.clear();
  }
}
