import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'di/injection.dart';
import 'provider/provider_downloader.dart';
import 'provider/provider_registry.dart';
import 'repository/downloads_repository.dart';
import 'repository/library_repository.dart';
import 'repository/read_chapters_repository.dart';
import 'services/notification_service.dart';
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
    await LibraryRepository.init();
    await ReadChaptersRepository.init();
    await DownloadsRepository.init();
    await ActiveSourceCubit.init();
    await configureDependencies();
    // Force-eager init of theme + novel-prefs cubits so they read Hive
    // synchronously (they require the `settings` box to be open, which it
    // is by this point thanks to ActiveSourceCubit.init).
    sl<ThemeCubit>();
    sl<NovelPrefsCubit>();
    sl<MangaPrefsCubit>();
    await sl<ProviderRegistry>().seedDefaults();
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
}
