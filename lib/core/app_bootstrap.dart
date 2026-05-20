import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'di/injection.dart';
import 'provider/provider_downloader.dart';
import 'provider/provider_registry.dart';
import 'provider/provider_repo_registry.dart';
import 'repository/book_detail_cache.dart';
import 'repository/chapter_bookmarks_repository.dart';
import 'repository/chapter_thumbnails_repository.dart';
import 'repository/downloads_repository.dart';
import 'repository/library_repository.dart';
import 'repository/page_bookmarks_repository.dart';
import 'repository/provider_repository.dart';
import 'repository/read_chapters_repository.dart';
import 'repository/tracker_repository.dart';
import 'services/notification_service.dart';
import 'trackers/anilist/anilist_tracker.dart';
import 'trackers/mal/mal_tracker.dart';
import 'state/active_source_cubit.dart';
import 'state/manga_prefs_cubit.dart';
import 'state/novel_prefs_cubit.dart';
import 'state/theme_cubit.dart';
import 'sync/library_sync_service.dart';

class AppBootstrap {
  static Future<void> initialize() async {
    try {
      await dotenv.load();
    } catch (_) {
      // .env may be missing in some build configs — ignore.
    }
    // Optional Supabase auth + sync. If env vars are missing or the network
    // is unreachable, log and continue — the app must remain usable offline.
    try {
      final url = dotenv.maybeGet('SUPABASE_URL');
      final anon = dotenv.maybeGet('SUPABASE_ANON_KEY');
      if (url != null && url.isNotEmpty && anon != null && anon.isNotEmpty) {
        await Supabase.initialize(url: url, anonKey: anon);
      } else {
        debugPrint('[bootstrap] Supabase env vars missing — auth disabled.');
      }
    } catch (e) {
      debugPrint('[bootstrap] Supabase.initialize failed: $e');
    }
    await Hive.initFlutter();
    await ProviderDownloader.init();
    await ProviderRegistry.init();
    await ProviderReposRegistry.init();
    await LibraryRepository.init();
    await ReadChaptersRepository.init();
    await DownloadsRepository.init();
    await ChapterBookmarksRepository.init();
    await PageBookmarksRepository.init();
    await ChapterThumbnailsRepository.init();
    await BookDetailCache.init();
    await TrackerRepository.init();
    await ActiveSourceCubit.init();
    await configureDependencies();
    // Eager-init each tracker so their auth state is resolved (tokens
    // read from secure storage, viewer fetched) before any UI reads
    // `isAuthenticated`. Fire-and-forget — failure to reach the remote
    // service at boot shouldn't block the app starting.
    // ignore: discarded_futures
    sl<AniListTracker>().init();
    // ignore: discarded_futures
    sl<MalTracker>().init();
    // Force-eager init of theme + novel-prefs cubits so they read Hive
    // synchronously (they require the `settings` box to be open, which it
    // is by this point thanks to ActiveSourceCubit.init).
    sl<ThemeCubit>();
    sl<NovelPrefsCubit>();
    sl<MangaPrefsCubit>();
    await sl<ProviderRegistry>().seedDefaults();
    // Seed the default Provider repo (Spyou's manifest) at first
    // launch. Idempotent — subsequent launches are a no-op when the
    // URL is already tracked. Fire-and-forget so a slow first-launch
    // network call doesn't delay the splash.
    final defaultRepo = dotenv.maybeGet('DEFAULT_PROVIDER_REPO')?.trim();
    if (defaultRepo != null && defaultRepo.isNotEmpty) {
      // ignore: discarded_futures
      sl<ProviderReposRegistry>().seedDefaultRepo(defaultRepo);
    }
    // Silently refresh every tracked repo's manifest in the background
    // so users see new / removed sources without needing to manually
    // hit the refresh icon. Fire-and-forget; errors are swallowed per
    // repo so one dead URL doesn't impact the rest of bootstrap.
    // ignore: discarded_futures
    sl<ProviderReposRegistry>().refreshAllInBackground();
    // Note: we do NOT call loadAll() here — that would try to download
    // providers from the placeholder GitHub URL and waste time. In dev,
    // main.dart calls loadBundledProviders() instead.

    // Start the library sync engine. If the user is signed in this kicks
    // off a background pull from Supabase and wires up the local-write
    // debouncer so future changes get pushed.
    await sl<LibrarySyncService>().start();

    // Local notifications. Best-effort: failing to initialise (e.g.
    // running on a desktop / test runner where the plugin isn't
    // available) is logged and ignored so the rest of the app boots
    // normally. The periodic chapter-check used to be a workmanager
    // background task, but the plugin was abandoned and OEM power-
    // savers kill background work anyway — see
    // [ChapterCheckLifecycleObserver] (wired in main.dart) for the
    // on-resume replacement.
    await sl<NotificationService>().init();
  }
}

/// Load bundled provider JS from assets when in dev (no GitHub host).
/// Call from main.dart after [AppBootstrap.initialize] to inject local
/// `providers/*.js` files into the runtime without downloading.
Future<void> loadBundledProviders(List<String> names) async {
  final registry = sl<ProviderRegistry>();
  for (final name in names) {
    try {
      final js = await rootBundle.loadString('providers/$name.js');
      await registry.installFromBundled(name, js);
      // ignore: avoid_print
      print('[bootstrap] loaded bundled provider: $name (${js.length} bytes)');
    } catch (e, st) {
      // ignore: avoid_print
      print('[bootstrap] FAILED to load $name: $e\n$st');
    }
  }
  // Pre-warm each provider's metadata cache so the source picker can read
  // from cache instead of queueing behind whatever JS calls Home is doing.
  // Failures here are non-fatal — the picker falls back to its async path.
  // ignore: discarded_futures
  _prewarmProviderInfo();
}

Future<void> _prewarmProviderInfo() async {
  for (final p in sl<ProviderRepository>().providers) {
    try {
      await p.getInfo();
    } catch (_) {/* tolerated */}
  }
}
