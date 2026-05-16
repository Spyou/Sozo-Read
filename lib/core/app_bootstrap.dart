import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'di/injection.dart';
import 'provider/provider_downloader.dart';
import 'provider/provider_registry.dart';
import 'repository/library_repository.dart';

class AppBootstrap {
  static Future<void> initialize() async {
    try {
      await dotenv.load();
    } catch (_) {
      // .env may be missing in some build configs — ignore.
    }
    await Hive.initFlutter();
    await ProviderDownloader.init();
    await ProviderRegistry.init();
    await LibraryRepository.init();
    await configureDependencies();
    await sl<ProviderRegistry>().seedDefaults();
    // Note: we do NOT call loadAll() here — that would try to download
    // providers from the placeholder GitHub URL and waste time. In dev,
    // main.dart calls loadBundledProviders() instead.
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
