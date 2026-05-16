import 'package:dartz/dartz.dart';

import '../error/exceptions.dart';
import '../error/failures.dart';
import '../models/book_detail.dart';
import '../models/book_item.dart';
import '../models/chapter.dart';
import '../models/page_content.dart';
import '../models/provider_info.dart';
import '../provider/provider_manager.dart';
import '../provider/provider_registry.dart';

/// Thin wrapper over [ProviderManager] / [ProviderRegistry] that returns
/// `Either<Failure, T>` and aggregates results across multiple providers.
class ProviderRepository {
  ProviderRepository({
    required ProviderManager manager,
    required ProviderRegistry registry,
  })  : _manager = manager,
        _registry = registry;

  final ProviderManager _manager;
  final ProviderRegistry _registry;

  List<JsProvider> get providers => _manager.all;
  JsProvider? provider(String sourceId) => _manager.get(sourceId);

  Future<Either<Failure, ProviderInfo>> info(String sourceId) =>
      _guard(() => _need(sourceId).getInfo());

  Future<Either<Failure, List<BookItem>>> search(
    String sourceId,
    String query, {
    int page = 1,
    String category = '',
  }) =>
      _guard(() => _need(sourceId).search(query, page, category: category));

  /// Searches every loaded provider and returns merged results.
  Future<Map<String, Either<Failure, List<BookItem>>>> searchAll(
    String query, {
    int page = 1,
  }) async {
    final out = <String, Either<Failure, List<BookItem>>>{};
    await Future.wait(providers.map((p) async {
      out[p.sourceId] = await _guard(() => p.search(query, page));
    }));
    return out;
  }

  Future<Either<Failure, BookDetail>> detail(String sourceId, String url) =>
      _guard(() => _need(sourceId).getDetail(url));

  Future<Either<Failure, List<Chapter>>> chapters(String sourceId, String url) =>
      _guard(() => _need(sourceId).getChapters(url));

  Future<Either<Failure, List<PageContent>>> pages(String sourceId, String chapterUrl) =>
      _guard(() => _need(sourceId).getPages(chapterUrl));

  Future<Either<Failure, NovelContent>> novelContent(String sourceId, String chapterUrl) =>
      _guard(() => _need(sourceId).getChapterContent(chapterUrl));

  // ---- registry ops ----
  Future<Either<Failure, void>> install(String name, String url) async {
    try {
      await _registry.install(name: name, url: url);
      return const Right(null);
    } catch (e) {
      return Left(_mapError(e));
    }
  }

  Future<Either<Failure, void>> uninstall(String name) async {
    try {
      await _registry.uninstall(name);
      return const Right(null);
    } catch (e) {
      return Left(_mapError(e));
    }
  }

  Future<Either<Failure, void>> refresh(String name) async {
    try {
      await _registry.loadIntoRuntime(name, force: true);
      return const Right(null);
    } catch (e) {
      return Left(_mapError(e));
    }
  }

  // ---- internals ----
  JsProvider _need(String sourceId) {
    final p = _manager.get(sourceId);
    if (p == null) {
      throw ProviderException('Provider not loaded: $sourceId');
    }
    return p;
  }

  Future<Either<Failure, T>> _guard<T>(Future<T> Function() fn) async {
    try {
      return Right(await fn());
    } catch (e) {
      return Left(_mapError(e));
    }
  }

  Failure _mapError(Object e) {
    if (e is NetworkException) return NetworkFailure(e.message, statusCode: e.statusCode);
    if (e is ProviderException) return ProviderFailure(e.message);
    if (e is JsRuntimeException) return JsRuntimeFailure(e.message);
    if (e is ParseException) return ParseFailure(e.message);
    return UnknownFailure(e.toString());
  }
}
