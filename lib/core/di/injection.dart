import 'package:dio/dio.dart';
import 'package:get_it/get_it.dart';

import '../provider/provider_downloader.dart';
import '../provider/provider_manager.dart';
import '../provider/provider_registry.dart';
import '../repository/library_repository.dart';
import '../repository/provider_repository.dart';

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
  sl.registerLazySingleton<ProviderRepository>(
    () => ProviderRepository(manager: sl(), registry: sl()),
  );
  sl.registerLazySingleton<LibraryRepository>(() => LibraryRepository());
}
