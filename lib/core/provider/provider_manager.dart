import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_js/flutter_js.dart';

import '../error/exceptions.dart';
import '../models/book_detail.dart';
import '../models/book_item.dart';
import '../models/chapter.dart';
import '../models/page_content.dart';
import '../models/provider_info.dart';
import 'base_provider.dart';
import 'js_bootstrap.dart';

/// Single shared QuickJS runtime that hosts every loaded provider as
/// `__providers[sourceId]`. This avoids flutter_js's "one channel per name,
/// last-runtime-wins" routing problem when multiple providers exist.
class _JsHost {
  _JsHost({required this.dio}) {
    _runtime = getJavascriptRuntime();
    _runtime.enableHandlePromises();
    _runtime.onMessage('fetch', _onFetch);
    _runtime.onMessage('console', _onConsole);
    final r = _runtime.evaluate(kJsBootstrap);
    if (r.isError) {
      throw JsRuntimeException('Bootstrap failed: ${r.stringResult}');
    }
  }

  final Dio dio;
  late final JavascriptRuntime _runtime;
  final Map<String, JsProvider> providers = {};
  // Mutex so JS calls don't overlap (QuickJS is single-threaded).
  Future<void> _queue = Future.value();

  Future<void> loadProvider(String sourceId, String jsSource) async {
    final wrapped = wrapProviderSource(sourceId, jsSource);
    final r = _runtime.evaluate(wrapped);
    if (r.isError) {
      throw JsRuntimeException('Provider eval failed for $sourceId: ${r.stringResult}');
    }
  }

  void removeProvider(String sourceId) {
    _runtime.evaluate("delete globalThis.__providers[${jsonEncode(sourceId)}];");
  }

  /// Calls `__providers[sourceId][method](...args)` and returns the resolved
  /// JSON string. Serialized via the per-host mutex.
  Future<String> call(String sourceId, String method, List<Object?> args) async {
    final completer = Completer<void>();
    final prev = _queue;
    _queue = completer.future;
    await prev;
    try {
      final v = await _runCall(sourceId, method, args);
      completer.complete();
      return v;
    } catch (e) {
      completer.complete();
      rethrow;
    }
  }

  Future<String> _runCall(String sourceId, String method, List<Object?> args) async {
    final argsJson = jsonEncode(args);
    final expr =
        '__callProvider(${jsonEncode(sourceId)}, ${jsonEncode(method)}, ${jsonEncode(argsJson)})';

    // ignore: avoid_print
    print('[$sourceId] -> $method');
    final asyncResult = await _runtime.evaluateAsync(expr);
    _runtime.executePendingJob();
    final resolved = await _runtime
        .handlePromise(asyncResult)
        .timeout(const Duration(seconds: 25), onTimeout: () {
      throw JsRuntimeException('$method timed out after 25s');
    });
    // ignore: avoid_print
    print('[$sourceId] <- $method ok');
    if (resolved.isError) {
      var msg = resolved.stringResult;
      if (msg.startsWith('"') && msg.endsWith('"')) {
        try {
          final unq = jsonDecode(msg);
          if (unq is String) msg = unq;
        } catch (_) {}
      }
      throw JsRuntimeException(msg);
    }
    var s = resolved.stringResult;
    if (s.isEmpty || s == 'null') {
      throw JsRuntimeException('$sourceId.$method returned null');
    }
    if (s.startsWith('"') && s.endsWith('"')) {
      try {
        final unwrapped = jsonDecode(s);
        if (unwrapped is String) s = unwrapped;
      } catch (_) {}
    }
    return s;
  }

  Map<String, dynamic> _coerceMap(dynamic raw) {
    if (raw is String) return jsonDecode(raw) as Map<String, dynamic>;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    throw FormatException('Unexpected message payload type: ${raw.runtimeType}');
  }

  Future<void> _onFetch(dynamic raw) async {
    String? id;
    try {
      final payload = _coerceMap(raw);
      id = payload['id'] as String;
      final url = payload['url'] as String;
      // ignore: avoid_print
      print('[fetch] ${payload['__src']} GET $url');
      final method = (payload['method'] as String?) ?? 'GET';
      final headers = (payload['headers'] as Map?)?.cast<String, dynamic>() ?? {};
      final body = payload['body'];

      final resp = await dio.requestUri<dynamic>(
        Uri.parse(url),
        data: body,
        options: Options(
          method: method,
          headers: headers.map((k, v) => MapEntry(k, v.toString())),
          responseType: ResponseType.plain,
          followRedirects: true,
          validateStatus: (_) => true,
        ),
      );

      final responseHeaders = <String, String>{};
      resp.headers.forEach((k, v) => responseHeaders[k] = v.join(', '));

      final responseJson = jsonEncode({
        'status': resp.statusCode ?? 0,
        'statusText': resp.statusMessage ?? '',
        'headers': responseHeaders,
        'url': resp.realUri.toString(),
        'body': resp.data?.toString() ?? '',
      });
      // ignore: avoid_print
      print('[fetch] $id <- ${resp.statusCode} ${resp.data?.toString().length ?? 0}B');
      _runtime.evaluate('__resolveFetch(${jsonEncode(id)}, ${jsonEncode(responseJson)});');
    } catch (e) {
      // ignore: avoid_print
      print('[fetch] FAILED $id: $e');
      if (id != null) {
        _runtime.evaluate('__rejectFetch(${jsonEncode(id)}, ${jsonEncode(e.toString())});');
      }
    }
  }

  void _onConsole(dynamic raw) {
    try {
      final map = _coerceMap(raw);
      final src = (map['__src'] ?? '?').toString();
      final level = (map['level'] ?? 'log').toString();
      final message = (map['message'] ?? '').toString();
      // ignore: avoid_print
      print('[$src/js $level] $message');
      providers[src]?.onConsole?.call(level, message);
    } catch (_) {}
  }

  void dispose() {
    _runtime.dispose();
  }
}

/// Thin per-source wrapper. Calls go through the shared _JsHost.
class JsProvider implements BaseProvider {
  JsProvider._({required this.sourceId, required _JsHost host}) : _host = host;

  @override
  final String sourceId;
  final _JsHost _host;

  /// Optional sink for JS console messages.
  void Function(String level, String message)? onConsole;

  Future<String> _call(String method, List<Object?> args) =>
      _host.call(sourceId, method, args);

  @override
  Future<ProviderInfo> getInfo() async {
    final raw = await _call('getInfo', const []);
    final map = jsonDecode(raw) as Map<String, dynamic>;
    return ProviderInfo.fromJson(map);
  }

  @override
  Future<List<BookItem>> search(String query, int page, {String category = ''}) async {
    final raw = await _call('search', [query, page, category]);
    final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    return list.map((m) => BookItem.fromJson({...m, 'sourceId': sourceId})).toList();
  }

  @override
  Future<BookDetail> getDetail(String url) async {
    final raw = await _call('getDetail', [url]);
    final map = jsonDecode(raw) as Map<String, dynamic>;
    return BookDetail.fromJson({...map, 'sourceId': sourceId});
  }

  @override
  Future<List<Chapter>> getChapters(String url) async {
    final raw = await _call('getChapters', [url]);
    final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    return list.map(Chapter.fromJson).toList();
  }

  @override
  Future<List<PageContent>> getPages(String chapterUrl) async {
    final raw = await _call('getPages', [chapterUrl]);
    final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    return list.map(PageContent.fromJson).toList();
  }

  @override
  Future<NovelContent> getChapterContent(String chapterUrl) async {
    final raw = await _call('getChapterContent', [chapterUrl]);
    final map = jsonDecode(raw) as Map<String, dynamic>;
    return NovelContent.fromJson(map);
  }
}

/// Public manager. Owns the single shared QuickJS runtime + registered providers.
class ProviderManager {
  ProviderManager({required Dio dio}) : _host = _JsHost(dio: dio);

  final _JsHost _host;

  Iterable<String> get installedIds => _host.providers.keys;
  List<JsProvider> get all => _host.providers.values.toList();
  JsProvider? get(String id) => _host.providers[id];

  Future<JsProvider> load({required String sourceId, required String jsSource}) async {
    await _host.loadProvider(sourceId, jsSource);
    final provider = JsProvider._(sourceId: sourceId, host: _host);
    _host.providers[sourceId] = provider;
    return provider;
  }

  void remove(String id) {
    _host.removeProvider(id);
    _host.providers.remove(id);
  }

  void disposeAll() {
    _host.providers.clear();
    _host.dispose();
  }
}
