import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:package_info_plus/package_info_plus.dart';

import 'di/injection.dart';
import 'provider/provider_downloader.dart';
import 'provider/provider_registry.dart';
import 'provider/provider_repo_registry.dart';
import 'repository/book_detail_cache.dart';
import 'repository/categories_repository.dart';
import 'repository/chapter_bookmarks_repository.dart';
import 'repository/cross_source_match_cache.dart';
import 'repository/dictionary_repository.dart';
import 'repository/chapter_thumbnails_repository.dart';
import 'repository/downloads_repository.dart';
import 'repository/library_categories_repository.dart';
import 'repository/library_repository.dart';
import 'repository/notifications_repository.dart';
import 'repository/page_bookmarks_repository.dart';
import 'repository/provider_repository.dart';
import 'repository/provider_settings_repository.dart';
import 'repository/read_chapters_repository.dart';
import 'provider/provider_manager.dart';
import 'repository/tracker_repository.dart';
import 'security/app_lock_cubit.dart';
import 'services/changelog_service.dart';
import 'package:audio_service/audio_service.dart';

import 'services/download_notification_service.dart';
import 'services/downloads_background_service.dart';
import 'services/notification_service.dart';
import 'services/novel_tts_service.dart';
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
    await CategoriesRepository.init();
    await LibraryCategoriesRepository.init();
    await ChapterThumbnailsRepository.init();
    await NotificationsRepository.init();
    await DictionaryRepository.init();
    await BookDetailCache.init();
    await CrossSourceMatchCache.init();
    await ProviderSettingsRepository.init();
    await TrackerRepository.init();
    await ActiveSourceCubit.init();
    // Build the App Lock cubit BEFORE configureDependencies so it can be
    // injected into the DI graph at registration time. The constructor
    // resolves PIN presence + FLAG_SECURE so the very first frame paints
    // the lock screen (or not) deterministically.
    final appLock = await AppLockCubit.init();
    await configureDependencies(appLock: appLock);
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
    // Rewrites legacy bare-sourceId keys in `provider_registry` to the
    // composite `(repoUrl, sourceId)` keys introduced by the multi-repo
    // refactor. Idempotent — already-composite keys are skipped. Must
    // run BEFORE seedDefaults so newly-seeded entries aren't re-rewritten.
    await sl<ProviderRegistry>().migrate();
    await sl<ProviderRegistry>().seedDefaults();
    // Push every saved per-source settings row into the JS runtime so
    // providers can read `__settings[sourceId]` from their first call.
    // The runtime hasn't loaded any providers yet (loadBundledProviders /
    // loadAll runs later) but `__settings` is a plain object — pre-
    // seeding it is harmless and cheaper than racing with the provider
    // load to push settings before the first user-triggered call.
    _seedRuntimeSettings();
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
    // After the refresh lands, re-stamp any `bundled://` / `builtin://`
    // entries whose sourceId is now claimed by exactly one tracked
    // repo. Without this the Repos tab leaves them marked "Not
    // installed" even though they're loaded and running.
    // ignore: discarded_futures
    () async {
      await sl<ProviderReposRegistry>().refreshAllInBackground();
      try {
        await sl<ProviderRegistry>().reassociateBundled();
      } catch (e) {
        debugPrint('[bootstrap] reassociateBundled failed: $e');
      }
    }();
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

    // Android foreground service for in-progress downloads. Configures
    // the plugin (channel + entry point) but does NOT start it — the
    // lifecycle binder below flips it on the first time the queue
    // becomes non-empty and back off when it drains. iOS gets the
    // plugin's default ~30s background grace.
    await DownloadsBackgroundService.initialize();

    // Register the novel-reader TTS handler with the OS media session
    // so the play/pause/skip controls show up on the lock screen and
    // notification shade. Best-effort: in test runners (no native
    // platform channel) this throws — swallow so the rest of bootstrap
    // continues.
    try {
      await AudioService.init(
        builder: () => sl<NovelTtsService>(),
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'com.spyou.sozo_manga.tts',
          androidNotificationChannelName: 'Novel Text-to-Speech',
          androidNotificationOngoing: true,
          androidStopForegroundOnPause: true,
        ),
      );
    } catch (e) {
      debugPrint('[bootstrap] AudioService.init failed: $e');
    }

    // Push the user's persisted novel-TTS preferences into the service
    // so the very first speak() call honours them (pitch / volume /
    // language are async on Android — without this seed, the first
    // chapter plays at engine defaults until the user touches a slider).
    try {
      final prefsCubit = sl<NovelPrefsCubit>();
      final prefs = prefsCubit.state;
      final tts = sl<NovelTtsService>();
      // ignore: discarded_futures
      tts.setLanguage(prefs.ttsLanguage);
      // ignore: discarded_futures
      tts.setPitch(prefs.ttsPitch);
      // ignore: discarded_futures
      tts.setVolume(prefs.ttsVolume);
      tts.setSkipMarkers(prefs.ttsSkipMarkers);
      tts.setParagraphPauseMs(prefs.ttsParagraphPauseMs);
      tts.setStopAtChapterEnd(prefs.ttsStopAtChapterEnd);
      tts.setPronunciations(prefs.ttsPronunciations);
    } catch (e) {
      debugPrint('[bootstrap] TTS pref seeding failed: $e');
    }

    // Persistent system notification that mirrors the active queue.
    // Attaches its own Hive box subscription; cheap to start even
    // when the queue is empty (it just renders nothing).
    await sl<DownloadNotificationService>().start();

    // Drive foreground-service lifecycle off the same Hive box. The
    // returned subscription lives for the process lifetime — there is
    // no global teardown hook, but `Hive.close()` during shutdown
    // tears the stream down cleanly.
    bindDownloadsBackgroundLifecycle(sl<DownloadsRepository>());

    // Detect a version bump since the last cold start. The "What's
    // new" sheet shown by `main.dart` reads `pendingShow` after the
    // first frame. A null `last_seen_version` (fresh install) does
    // NOT trigger the sheet — only an actual upgrade does.
    try {
      const lastSeenKey = 'changelog.last_seen_version';
      final settingsBox = Hive.box('settings');
      final pkg = await PackageInfo.fromPlatform();
      final currentVersion = '${pkg.version}+${pkg.buildNumber}';
      final lastSeen = settingsBox.get(lastSeenKey) as String?;
      final service = sl<ChangelogService>();
      if (lastSeen != null && lastSeen != currentVersion) {
        service.pendingShow = true;
      }
      await settingsBox.put(lastSeenKey, currentVersion);
    } catch (e) {
      debugPrint('[bootstrap] version-bump detection failed: $e');
    }
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

/// Pushes every persisted per-source settings row into the JS runtime
/// so providers can read `__settings[sourceId]` immediately on first
/// invocation. Reads from the composite-key Hive box and strips the
/// repoUrl prefix because the runtime only knows about `sourceId`s —
/// the live `(repoUrl, sourceId)` slot for any given sourceId is
/// whichever entry was loaded last (see `ProviderManager.load`).
void _seedRuntimeSettings() {
  try {
    final repo = sl<ProviderSettingsRepository>();
    final manager = sl<ProviderManager>();
    final all = repo.getAll();
    for (final entry in all.entries) {
      final sourceId = ProviderRegistry.sourceIdOf(entry.key);
      manager.setSettings(sourceId, entry.value);
    }
  } catch (e) {
    debugPrint('[bootstrap] seed provider settings failed: $e');
  }
}
