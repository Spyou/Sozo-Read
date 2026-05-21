import 'package:dio/dio.dart';
import 'package:get_it/get_it.dart';

import '../../features/home/bloc/home_bloc.dart';
import '../provider/provider_downloader.dart';
import '../provider/provider_manager.dart';
import '../provider/provider_registry.dart';
import '../provider/provider_repo_registry.dart';
import '../repository/book_detail_cache.dart';
import '../repository/chapter_bookmarks_repository.dart';
import '../repository/chapter_thumbnails_repository.dart';
import '../repository/downloads_repository.dart';
import '../repository/library_repository.dart';
import '../repository/notifications_repository.dart';
import '../repository/page_bookmarks_repository.dart';
import '../repository/provider_repository.dart';
import '../repository/read_chapters_repository.dart';
import '../repository/tracker_repository.dart';
import '../services/chapter_check_service.dart';
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
import '../state/chapter_sort_cubit.dart';
import '../state/source_filter_cubit.dart';
import '../state/manga_prefs_cubit.dart';
import '../state/notifications_prefs_cubit.dart';
import '../state/novel_prefs_cubit.dart';
import '../state/theme_cubit.dart';
import '../sync/library_sync_service.dart';

final GetIt sl = GetIt.instance;

Future<void> configureDependencies() async {
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
  sl.registerLazySingleton<ProviderRegistry>(
    () => ProviderRegistry(downloader: sl(), manager: sl()),
  );
  sl.registerLazySingleton<ProviderReposRegistry>(
    () => ProviderReposRegistry(dio: sl()),
  );
  sl.registerLazySingleton<ProviderRepository>(
    () => ProviderRepository(manager: sl(), registry: sl()),
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
  sl.registerLazySingleton<ChapterThumbnailsRepository>(
    () => ChapterThumbnailsRepository(),
  );
  sl.registerLazySingleton<NotificationsRepository>(
    () => NotificationsRepository(),
  );
  sl.registerLazySingleton<BookDetailCache>(() => BookDetailCache());
  sl.registerLazySingleton<ActiveSourceCubit>(
    () => ActiveSourceCubit(repository: sl()),
  );
  sl.registerLazySingleton<ThemeCubit>(() => ThemeCubit());
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
      auth: sl(),
    ),
  );
  sl.registerLazySingleton<NotificationsPrefsCubit>(
    () => NotificationsPrefsCubit(),
  );
  sl.registerLazySingleton<NotificationService>(() => NotificationService());
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
