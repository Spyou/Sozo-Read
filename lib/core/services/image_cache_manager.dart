import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../state/incognito_cubit.dart';

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

/// Incognito-mode image cache.
///
/// `CachedNetworkImage` requires *some* `CacheManager`, so we can't
/// truly bypass disk — but we can pin the on-disk footprint to ~1
/// file and evict it the moment its tiny stale window passes. The
/// store is keyed separately so the main cache's warm 30-day window
/// is preserved when the user toggles incognito off.
///
/// Whenever the user flips incognito (on→off or off→on) we also call
/// [AppMemoryOnlyImageCacheManager.purge] from the toggle handlers so
/// nothing the user browsed during the session lingers afterwards.
class AppMemoryOnlyImageCacheManager extends CacheManager
    with ImageCacheManager {
  factory AppMemoryOnlyImageCacheManager() => _instance;
  AppMemoryOnlyImageCacheManager._() : super(Config(
          _key,
          // 1-second stale window + LRU cap of 1 = files are evicted on
          // essentially every subsequent fetch. Memory cache (Flutter's
          // global ImageCache) still serves repeat decodes for free.
          stalePeriod: const Duration(seconds: 1),
          maxNrOfCacheObjects: 1,
          repo: JsonCacheInfoRepository(databaseName: _key),
          fileService: HttpFileService(),
        ));

  static const _key = 'sozoread_image_cache_incognito';
  static final AppMemoryOnlyImageCacheManager _instance =
      AppMemoryOnlyImageCacheManager._();

  /// Drops every cached entry. Best-effort, used on incognito toggles
  /// to make sure nothing the user browsed sticks around.
  Future<void> purge() async {
    try {
      await emptyCache();
    } catch (_) {
      // emptyCache races with in-flight downloads on rare occasions;
      // swallowing here keeps the toggle UI responsive.
    }
  }
}

/// Convenience singleton — counterpart to [appImageCacheManager] for
/// incognito sessions.
final AppMemoryOnlyImageCacheManager appMemoryOnlyImageCacheManager =
    AppMemoryOnlyImageCacheManager();

/// Returns whichever cache manager is appropriate for the current
/// session. Call sites that previously hard-wired
/// `cacheManager: appImageCacheManager` should switch to
/// `cacheManager: sozoCacheManagerFor(context)` so they pick up the
/// memory-only variant the moment incognito flips on.
CacheManager sozoCacheManagerFor(BuildContext context) {
  // `watch` so widgets rebuild on toggle and swap their image provider.
  final incognito = context.watch<IncognitoCubit>().state;
  return incognito ? appMemoryOnlyImageCacheManager : appImageCacheManager;
}
