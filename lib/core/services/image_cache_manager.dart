import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Size-capped image disk cache.
///
/// `cached_network_image`'s `DefaultCacheManager` is unbounded — it
/// keeps every page / cover / thumbnail it has ever decoded on disk
/// forever. In a manga reader that browses (or downloads) hundreds of
/// chapters this regularly grows past 400 MB, fragments the process
/// heap, and triggers native OOMs on mid-RAM devices (Scudo abort,
/// `internal map failure requesting 4KB`).
///
/// We swap in a [CacheManager] with explicit limits:
///   * `maxNrOfCacheObjects: 500` — at ~300 KB / page that's ~150 MB
///     of disk worst case, with LRU eviction beyond that.
///   * `stalePeriod: 30 days` — covers / thumbs the user re-visits stay
///     warm for a month; the in-flight reading window obviously stays
///     warm regardless.
///
/// The cache key (`_key`) is distinct from `DefaultCacheManager`'s
/// `libCachedImageData` so an older unbounded cache from previous app
/// versions is left intact until [StorageSettingsScreen] purges it.
/// Avoids any first-launch eviction storm.
class AppImageCacheManager extends CacheManager with ImageCacheManager {
  factory AppImageCacheManager() => _instance;
  AppImageCacheManager._() : super(Config(
          _key,
          stalePeriod: const Duration(days: 30),
          maxNrOfCacheObjects: 500,
          repo: JsonCacheInfoRepository(databaseName: _key),
          fileService: HttpFileService(),
        ));

  static const _key = 'sozoread_image_cache';
  static final AppImageCacheManager _instance = AppImageCacheManager._();
}

/// Convenience singleton — pass this as `cacheManager:` on every
/// `CachedNetworkImage` / `CachedNetworkImageProvider` instance so they
/// share the size-bounded backend instead of `DefaultCacheManager`.
final AppImageCacheManager appImageCacheManager = AppImageCacheManager();
