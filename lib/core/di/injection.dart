import 'package:dio/dio.dart';
import 'package:get_it/get_it.dart';

import '../../features/home/bloc/home_bloc.dart';
import '../provider/provider_downloader.dart';
import '../provider/provider_manager.dart';
import '../security/app_lock_cubit.dart';
import '../security/biometric_service.dart';
import '../security/pin_storage.dart';
import '../security/secure_window_channel.dart';
import '../provider/provider_registry.dart';
import '../provider/provider_repo_registry.dart';
import '../repository/book_detail_cache.dart';
import '../repository/categories_repository.dart';
import '../repository/chapter_bookmarks_repository.dart';
import '../repository/chapter_thumbnails_repository.dart';
import '../repository/cross_source_match_cache.dart';
import '../repository/downloads_repository.dart';
import '../repository/library_categories_repository.dart';
import '../repository/library_repository.dart';
import '../repository/notifications_repository.dart';
import '../repository/page_bookmarks_repository.dart';
import '../repository/provider_repository.dart';
import '../repository/provider_settings_repository.dart';
import '../repository/read_chapters_repository.dart';
import '../repository/tracker_repository.dart';
import '../repository/dictionary_repository.dart';
import '../repository/voices_repository.dart';
import '../services/ai/ai_client.dart';
import '../services/ai/gemini_ai_client.dart';
import '../services/apk_installer.dart';
import '../services/changelog_service.dart';
import '../services/chapter_check_service.dart';
import '../services/cross_source_matcher.dart';
import '../services/download_notification_service.dart';
import '../services/novel_tts_service.dart';
import '../services/update_service.dart';
import '../services/voice_downloader.dart';
import '../trackers/anilist/anilist_api.dart';
import '../trackers/anilist/anilist_auth.dart';
import '../trackers/anilist/anilist_tracker.dart';
import '../trackers/mal/mal_api.dart';
import '../trackers/mal/mal_auth.dart';
import '../trackers/mal/mal_tracker.dart';
import '../trackers/tracker.dart';
import '../services/cloudinary_service.dart';
import '../services/notification_service.dart';
import '../state/active_source_cubit.dart';
import '../state/auth_service.dart';
import '../state/auto_switch_prefs.dart';
import '../state/chapter_sort_cubit.dart';
import '../state/incognito_cubit.dart';
import '../state/source_filter_cubit.dart';
import '../state/manga_prefs_cubit.dart';
import '../state/notifications_prefs_cubit.dart';
import '../state/ai_prefs_cubit.dart';
import '../state/novel_prefs_cubit.dart';
import '../state/theme_cubit.dart';
import '../sync/library_sync_service.dart';

final GetIt sl = GetIt.instance;

Future<void> configureDependencies({AppLockCubit? appLock}) async {
  // App Lock — PIN, biometric, FLAG_SECURE. The cubit is built BEFORE
  // runApp by AppBootstrap so the lock screen can paint the first frame.
  sl.registerLazySingleton<PinStorage>(() => PinStorage());
  sl.registerLazySingleton<BiometricService>(() => BiometricService());
  sl.registerLazySingleton<SecureWindowChannel>(() => SecureWindowChannel());
  if (appLock != null) {
    sl.registerSingleton<AppLockCubit>(appLock);
  }

  // Dio with sane defaults for scraping.
  sl.registerLazySingleton<Dio>(() {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 30),
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36',
        'Accept': '*/*',
        'Accept-Language': 'en-US,en;q=0.9',
      },
    ));
    return dio;
  });

  sl.registerLazySingleton<ProviderDownloader>(() => ProviderDownloader(dio: sl()));
  sl.registerLazySingleton<ProviderManager>(() => ProviderManager(dio: sl()));
  // ProviderReposRegistry registered FIRST so ProviderRegistry can pull
  // it in for the legacy-key migration on cold start.
  sl.registerLazySingleton<ProviderReposRegistry>(
    () => ProviderReposRegistry(dio: sl()),
  );
  sl.registerLazySingleton<ProviderRegistry>(
    () => ProviderRegistry(downloader: sl(), manager: sl(), repos: sl()),
  );
  sl.registerLazySingleton<ProviderRepository>(
    () => ProviderRepository(manager: sl(), registry: sl()),
  );
  sl.registerLazySingleton<ProviderSettingsRepository>(
    () => ProviderSettingsRepository(),
  );
  sl.registerLazySingleton<LibraryRepository>(() => LibraryRepository());
  sl.registerLazySingleton<ReadChaptersRepository>(
    () => ReadChaptersRepository(),
  );
  sl.registerLazySingleton<DownloadsRepository>(() => DownloadsRepository());
  sl.registerLazySingleton<ChapterBookmarksRepository>(
    () => ChapterBookmarksRepository(),
  );
  sl.registerLazySingleton<PageBookmarksRepository>(
    () => PageBookmarksRepository(),
  );
  sl.registerLazySingleton<CategoriesRepository>(() => CategoriesRepository());
  sl.registerLazySingleton<LibraryCategoriesRepository>(
    () => LibraryCategoriesRepository(),
  );
  sl.registerLazySingleton<ChapterThumbnailsRepository>(
    () => ChapterThumbnailsRepository(),
  );
  sl.registerLazySingleton<NotificationsRepository>(
    () => NotificationsRepository(),
  );
  sl.registerLazySingleton<BookDetailCache>(() => BookDetailCache());
  // Cross-source fallback: persistent Hive cache + matcher service +
  // user-facing opt-in flag. Backing boxes are opened in AppBootstrap.
  sl.registerLazySingleton<CrossSourceMatchCache>(
    () => CrossSourceMatchCache(),
  );
  sl.registerLazySingleton<CrossSourceMatcher>(
    () => CrossSourceMatcher(repository: sl()),
  );
  sl.registerLazySingleton<AutoSwitchPrefs>(() => AutoSwitchPrefs());
  sl.registerLazySingleton<ActiveSourceCubit>(
    () => ActiveSourceCubit(repository: sl()),
  );
  sl.registerLazySingleton<ThemeCubit>(() => ThemeCubit());
  // Volatile session toggle — never persisted, see [IncognitoCubit].
  sl.registerLazySingleton<IncognitoCubit>(() => IncognitoCubit());
  sl.registerLazySingleton<NovelPrefsCubit>(() => NovelPrefsCubit());
  sl.registerLazySingleton<MangaPrefsCubit>(() => MangaPrefsCubit());
  sl.registerLazySingleton<ChapterSortCubit>(() => ChapterSortCubit());
  sl.registerLazySingleton<SourceFilterCubit>(() => SourceFilterCubit());
  sl.registerLazySingleton<AuthService>(() => AuthService());
  sl.registerLazySingleton<CloudinaryService>(
    () => CloudinaryService(dio: sl()),
  );
  sl.registerLazySingleton<LibrarySyncService>(
    () => LibrarySyncService(
      library: sl(),
      readChapters: sl(),
      chapterBookmarks: sl(),
      pageBookmarks: sl(),
      categories: sl(),
      libraryCategories: sl(),
      auth: sl(),
    ),
  );
  sl.registerLazySingleton<NotificationsPrefsCubit>(
    () => NotificationsPrefsCubit(),
  );
  sl.registerLazySingleton<NotificationService>(() => NotificationService());
  // Novel-reader Text-to-Speech. Held as a singleton so the same
  // handler instance is what AudioService.init() registered with the
  // OS media-controls notification. The prefs cubit is injected so
  // the service can pick the engine (system vs neural) when a new
  // chapter loads; AppBootstrap also calls `attachPrefs` as a
  // belt-and-braces wire-up after the cubit is eagerly built.
  sl.registerLazySingleton<NovelTtsService>(
    () => NovelTtsService(prefs: sl<NovelPrefsCubit>()),
  );
  // Neural-voice catalog repo + downloader. Hive box is opened in
  // AppBootstrap.initialize alongside the other repos. The downloader
  // fetches Piper bundles from the sherpa-onnx GitHub release and
  // hands the resolved paths to the repo for `pathFor` lookups.
  sl.registerLazySingleton<VoicesRepository>(() => VoicesRepository());
  sl.registerLazySingleton<VoiceDownloader>(
    () => VoiceDownloader(dio: sl(), repo: sl()),
  );
  // AI integration. Prefs cubit owns the API key + selected model;
  // the Gemini client reads the key on demand at request time. The
  // summaries repo caches generated text per chapter so re-asks are
  // free.
  sl.registerLazySingleton<AiPrefsCubit>(() => AiPrefsCubit());
  sl.registerLazySingleton<AiClient>(
    () => GeminiAiClient(prefs: sl<AiPrefsCubit>(), dio: sl()),
  );
  // SummariesRepository is registered with the loaded box from
  // AppBootstrap (init() opens the Hive box asynchronously).
  // Persistent download-progress notification. Subscribes to the
  // downloads Hive box on `start()` (called from AppBootstrap) and
  // renders one throttled, replace-in-place notification summarising
  // the active queue.
  // GitHub release-notes fetcher with on-disk cache. Used by the
  // What's new sheet (post version-bump) and /settings/changelog.
  sl.registerLazySingleton<ChangelogService>(
    () => ChangelogService(dio: sl(), boxName: 'settings'),
  );
  // Auto-updater: shares the changelog's release cache. The installer is a
  // thin MethodChannel wrapper around the platform-side FileProvider flow.
  sl.registerLazySingleton<ApkInstaller>(() => const ApkInstaller());
  sl.registerLazySingleton<UpdateService>(
    () => UpdateService(
      changelog: sl(),
      dio: sl(),
      installer: sl(),
      boxName: 'settings',
    ),
  );
  // Word definitions for the novel reader's long-press lookup. The
  // backing Hive cache is opened in app_bootstrap.dart.
  sl.registerLazySingleton<DictionaryRepository>(
    () => DictionaryRepository(dio: sl()),
  );
  sl.registerLazySingleton<DownloadNotificationService>(
    () => DownloadNotificationService(
      downloads: sl(),
      notifications: sl(),
    ),
  );
  sl.registerLazySingleton<ChapterCheckService>(
    () => ChapterCheckService(
      library: sl(),
      providers: sl(),
      notifications: sl(),
      inbox: sl(),
    ),
  );
  // HomeBloc as a singleton so the splash screen can warm it up while its
  // animation plays — by the time the user lands on /home, sections are
  // already loaded (no second spinner).
  sl.registerLazySingleton<HomeBloc>(
    () => HomeBloc(repository: sl(), libraryRepository: sl()),
  );

  // ---- Trackers. ----
  sl.registerLazySingleton<AniListAuth>(() => AniListAuth());
  sl.registerLazySingleton<AniListApi>(
    () => AniListApi(dio: sl(), auth: sl()),
  );
  sl.registerLazySingleton<AniListTracker>(
    () => AniListTracker(api: sl(), auth: sl()),
  );
  sl.registerLazySingleton<MalAuth>(() => MalAuth(dio: sl()));
  sl.registerLazySingleton<MalApi>(
    () => MalApi(dio: sl(), auth: sl()),
  );
  sl.registerLazySingleton<MalTracker>(
    () => MalTracker(api: sl(), auth: sl()),
  );
  sl.registerLazySingleton<TrackerRepository>(
    () => TrackerRepository(trackers: <Tracker>[
      sl<AniListTracker>(),
      sl<MalTracker>(),
    ]),
  );
}
