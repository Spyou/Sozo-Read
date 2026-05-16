import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'core/app_bootstrap.dart';
import 'core/di/injection.dart';
import 'core/router/app_router.dart';
import 'core/state/theme_cubit.dart';
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
  runApp(const SozoReadApp());
}

class SozoReadApp extends StatefulWidget {
  const SozoReadApp({super.key});

  @override
  State<SozoReadApp> createState() => _SozoReadAppState();
}

class _SozoReadAppState extends State<SozoReadApp> {
  // Build the router once so route state survives theme rebuilds.
  late final _router = buildRouter();

  @override
  Widget build(BuildContext context) {
    return BlocProvider.value(
      value: sl<ThemeCubit>(),
      child: BlocBuilder<ThemeCubit, ThemeSettings>(
        builder: (context, theme) {
          return MaterialApp.router(
            title: 'Sozo Read',
            theme: AppTheme.buildLight(theme.accent),
            darkTheme: AppTheme.buildDark(theme.accent),
            themeMode: theme.mode,
            debugShowCheckedModeBanner: false,
            routerConfig: _router,
          );
        },
      ),
    );
  }
}
