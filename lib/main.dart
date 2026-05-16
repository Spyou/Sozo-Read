import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/app_bootstrap.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));
  await AppBootstrap.initialize();
  // Dev convenience: also load JS providers bundled with the app, so the
  // first run works without a configured GitHub registry.
  // Three working sources by default. All deliver full chapter pages.
  // mangadex.js and mangakakalot.js are still shipped as assets but not
  // auto-loaded (mangakakalot caps at 6 SSR pages; mangadex's popular feed
  // is dominated by licensed manhwa with no images).
  await loadBundledProviders(['weebcentral', 'mangapill', 'mangakatana']);
  runApp(const AizenReadApp());
}

class AizenReadApp extends StatelessWidget {
  const AizenReadApp({super.key});

  @override
  Widget build(BuildContext context) {
    final router = buildRouter();
    return MaterialApp.router(
      title: 'AizenRead',
      theme: AppTheme.dark,
      debugShowCheckedModeBanner: false,
      routerConfig: router,
    );
  }
}
