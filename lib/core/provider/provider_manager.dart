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
  // Per-source failure tracking. A provider with 3+ consecutive failures is
  // marked `broken`; one with any prior failure but a recent success may be
  // `degraded` until cleared.
  final Map<String, _ProviderHealth> _health = {};

  ProviderHealthStatus healthFor(String sourceId) =>
      _health[sourceId]?.status ?? ProviderHealthStatus.healthy;
  String? lastErrorFor(String sourceId) => _health[sourceId]?.lastError;
  int failuresFor(String sourceId) => _health[sourceId]?.failures ?? 0;

  void resetHealth(String sourceId) {
    _health.remove(sourceId);
  }

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

  /// Pushes [settings] into the JS runtime as `__settings[sourceId]`.
  ///
  /// One-shot synchronous eval — no mutex / queue. The existing call
  /// path already runs without a host-wide lock (see [call]'s doc), and
  /// QuickJS serialises FFI calls internally, so writing this slot
  /// between provider calls is safe. Replaces the slot entirely rather
  /// than merging, so cleared keys disappear from the JS side too.
  void setSettings(String sourceId, Map<String, dynamic> settings) {
    final r = _runtime.evaluate(
      '__settings[${jsonEncode(sourceId)}] = ${jsonEncode(settings)};',
    );
    if (r.isError) {
      // Don't throw — settings push is best-effort. The provider just
      // sees an empty object and falls back to its schema defaults.
      // ignore: avoid_print
      print('[settings] push failed for $sourceId: ${r.stringResult}');
    }
  }

  /// Calls `__providers[sourceId][method](...args)` and returns the resolved
  /// JSON string.
  ///
  /// Concurrency note: we deliberately do NOT serialize calls behind a
  /// host-wide mutex. QuickJS already serializes at the FFI layer
  /// (`evaluate` is sync), and the JS bootstrap routes by source id +
  /// uses unique fetch ids — there's no shared mutable JS state to
  /// protect. A previous version had a `_queue` mutex which caused
  /// search to fail under load: a slow provider (8-15s of HTTP fetches)
  /// would queue every other provider AND every subsequent user search
  /// behind it. The bloc's 10s per-source timeout then fired on calls
  /// that hadn't even started running, producing "no sources reached".
  Future<String> call(String sourceId, String method, List<Object?> args) async {
    try {
      final v = await _runCall(sourceId, method, args);
      _recordSuccess(sourceId);
      return v;
    } catch (e) {
      _recordFailure(sourceId, e);
      rethrow;
    }
  }

  void _recordSuccess(String sourceId) {
    final h = _health[sourceId];
    if (h == null) return;
    // A success clears the failure streak; keep degraded status until reset
    // only if it was broken (so the UI shows recovery as healthy).
    _health.remove(sourceId);
  }

  void _recordFailure(String sourceId, Object error) {
    final prev = _health[sourceId];
    final failures = (prev?.failures ?? 0) + 1;
    final status = failures >= 3
        ? ProviderHealthStatus.broken
        : ProviderHealthStatus.degraded;
    _health[sourceId] = _ProviderHealth(
      failures: failures,
      lastError: error.toString(),
      status: status,
    );
  }

  Future<String> _runCall(String sourceId, String method, List<Object?> args) async {
    final argsJson = jsonEncode(args);
    final expr =
        '__callProvider(${jsonEncode(sourceId)}, ${jsonEncode(method)}, ${jsonEncode(argsJson)})';

    // ignore: avoid_print
    print('[$sourceId] -> $method');
    final asyncResult = await _runtime.evaluateAsync(expr);
    // flutter_js's `handlePromise` pumps the JS microtask queue
    // internally via a 20ms periodic timer; calling executePendingJob
    // here would just be a redundant FFI hop. The 15s ceiling is tighter
    // than the previous 25s because the bloc-level per-source timeout is
    // 10s — keeping these close together bounds how long the package's
    // internal pump-timer keeps running after we've already abandoned
    // the call (it auto-cancels when the JS promise resolves OR fails).
    final resolved = await _runtime
        .handlePromise(asyncResult)
        .timeout(const Duration(seconds: 15), onTimeout: () {
      throw JsRuntimeException('$method timed out after 15s');
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

enum ProviderHealthStatus { healthy, degraded, broken }

class _ProviderHealth {
  _ProviderHealth({
    required this.failures,
    required this.lastError,
    required this.status,
  });
  final int failures;
  final String lastError;
  final ProviderHealthStatus status;
}

/// Thin per-source wrapper. Calls go through the shared _JsHost.
class JsProvider implements BaseProvider {
  JsProvider._({
    required this.sourceId,
    required this.originRepoUrl,
    required this.displayName,
    required _JsHost host,
  }) : _host = host;

  @override
  final String sourceId;

  /// Manifest URL of the repo this provider was installed from.
  /// Empty for legacy / built-in entries that pre-date the
  /// composite-key refactor.
  final String originRepoUrl;

  /// Human-readable repo name, snapshotted at install time. Used by
  /// the source picker to render the row's subtitle.
  final String displayName;

  final _JsHost _host;

  /// Optional sink for JS console messages.
  void Function(String level, String message)? onConsole;

  ProviderHealthStatus get healthStatus => _host.healthFor(sourceId);
  String? get lastError => _host.lastErrorFor(sourceId);
  int get failureCount => _host.failuresFor(sourceId);
  void resetHealth() => _host.resetHealth(sourceId);

  Future<String> _call(String method, List<Object?> args) =>
      _host.call(sourceId, method, args);

  /// Provider metadata is invariant across the app's lifetime (it's just
  /// the JS file's getInfo() return value), so cache it. Without this the
  /// source picker waits behind every active JS call — opening it while
  /// Home is loading 1000+ chapters made it look frozen.
  ProviderInfo? _infoCache;

  @override
  Future<ProviderInfo> getInfo() async {
    final cached = _infoCache;
    if (cached != null) return cached;
    final raw = await _call('getInfo', const []);
    final map = jsonDecode(raw) as Map<String, dynamic>;
    final info = ProviderInfo.fromJson(map);
    _infoCache = info;
    return info;
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

  /// Returns the provider's settings schema, or null if the JS file
  /// doesn't define `getSettings()`. Never throws — the wrapped
  /// namespace map sets the slot to `null` for providers without the
  /// function, which `__callProvider` reports as a "missing method"
  /// rejection; we treat that as "no schema" rather than a hard error.
  Future<List<dynamic>?> getSettingsSchema() async {
    try {
      final raw = await _call('getSettings', const []);
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded;
      return null;
    } catch (e) {
      final msg = e is JsRuntimeException ? e.message : e.toString();
      // The bootstrap signals an absent function with this exact prefix.
      if (msg.contains('missing method: getSettings')) return null;
      // ignore: avoid_print
      print('[settings] schema load failed for $sourceId: $msg');
      return null;
    }
  }
}

/// Public manager. Owns the single shared QuickJS runtime + registered providers.
class ProviderManager {
  ProviderManager({required Dio dio}) : _host = _JsHost(dio: dio);

  final _JsHost _host;

  Iterable<String> get installedIds => _host.providers.keys;
  List<JsProvider> get all => _host.providers.values.toList();
  JsProvider? get(String id) => _host.providers[id];

  /// Loads [jsSource] under [sourceId] in the shared QuickJS runtime.
  ///
  /// Constraint: only one provider per [sourceId] can be active at a
  /// time — `globalThis.__providers[sourceId]` is a single slot.
  /// Calling [load] a second time with the same [sourceId] silently
  /// replaces the previous definition. The Dart-side registry tracks
  /// every installed (repo, sourceId) pair, but the runtime mirror is
  /// one-per-id; callers swap by calling `ProviderRegistry.setRuntimeActive`.
  Future<JsProvider> load({
    required String sourceId,
    required String jsSource,
    String originRepoUrl = '',
    String displayName = '',
  }) async {
    await _host.loadProvider(sourceId, jsSource);
    final provider = JsProvider._(
      sourceId: sourceId,
      originRepoUrl: originRepoUrl,
      displayName: displayName,
      host: _host,
    );
    _host.providers[sourceId] = provider;
    return provider;
  }

  void remove(String id) {
    _host.removeProvider(id);
    _host.providers.remove(id);
    _host.resetHealth(id);
  }

  /// Mirrors per-source settings into the JS runtime so subsequent
  /// provider calls can read them as `__settings[sourceId]`. Safe to
  /// call at any time — the underlying eval is single-shot.
  void setSettings(String sourceId, Map<String, dynamic> settings) =>
      _host.setSettings(sourceId, settings);

  void resetHealth(String id) => _host.resetHealth(id);

  void disposeAll() {
    _host.providers.clear();
    _host.dispose();
  }
}
