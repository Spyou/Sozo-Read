import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'core/app_bootstrap.dart';
import 'core/di/injection.dart';
import 'core/router/app_router.dart' show buildRouter, parseSozoReadDeepLink;
import 'core/services/chapter_check_service.dart';
import 'core/state/theme_cubit.dart';
import 'core/theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Image cache caps. The Flutter default is 100 MB / 1000 images which
  // a 1000-chapter manga thumbnail list can easily blow past, pushing
  // low-RAM devices to OOM and triggering aggressive GC pauses during
  // scroll. 64 MB / 200 images comfortably covers the visible window
  // plus a generous scroll-ahead buffer.
  PaintingBinding.instance.imageCache
    ..maximumSize = 200
    ..maximumSizeBytes = 64 * 1024 * 1024;
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));
  await AppBootstrap.initialize();
  // Dev convenience: also load JS providers bundled with the app, so the
  // first run works without a configured GitHub registry.
  // Manga: weebcentral, mangapill, mangakatana — full chapter pages.
  // Novel: freewebnovel, novelbin — server-side HTML, no CF gate.
  // mangadex.js and mangakakalot.js are still shipped as assets but not
  // auto-loaded (mangakakalot caps at 6 SSR pages; mangadex's popular feed
  // is dominated by licensed manhwa with no images).
  await loadBundledProviders([
    'weebcentral',
    'mangapill',
    'mangakatana',
    'freewebnovel',
    'novelbin',
  ]);
  runApp(const SozoReadApp());
}

class SozoReadApp extends StatefulWidget {
  const SozoReadApp({super.key});

  @override
  State<SozoReadApp> createState() => _SozoReadAppState();
}

class _SozoReadAppState extends State<SozoReadApp> with WidgetsBindingObserver {
  // Build the router once so route state survives theme rebuilds.
  late final _router = buildRouter();

  // Throttle so re-foregrounding the app doesn't hammer the chapter
  // sources. 30 minutes is enough to catch updates without being annoying.
  DateTime? _lastChapterCheckAt;
  static const _chapterCheckCooldown = Duration(minutes: 30);

  // Cold + warm start sozoread:// deep-link routing. `app_links` is the
  // only way to reliably capture deep links on modern Flutter — the
  // PlatformDispatcher.defaultRouteName approach is unreliable when other
  // plugins also bind to the same intent action.
  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _deepLinkSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Fire once at cold-start (after the first frame so the UI isn't
    // blocked) — covers the "user just installed and saved a manga"
    // path before any backgrounding has happened.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeCheckNewChapters();
      _initDeepLinks();
    });
  }

  @override
  void dispose() {
    _deepLinkSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _initDeepLinks() async {
    // Cold-start: the URI that launched the app (if any).
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) {
        debugPrint('[deeplink] cold-start uri: $initial');
        _routeFromUri(initial);
      }
    } catch (e) {
      debugPrint('[deeplink] getInitialLink failed: $e');
    }
    // Warm-start: every subsequent sozoread:// fired while the app is
    // running (foreground or background → resumed) lands here.
    _deepLinkSub = _appLinks.uriLinkStream.listen(
      (uri) {
        debugPrint('[deeplink] warm uri: $uri');
        _routeFromUri(uri);
      },
      onError: (Object e) => debugPrint('[deeplink] stream error: $e'),
    );
  }

  void _routeFromUri(Uri uri) {
    final target = parseSozoReadDeepLink(uri);
    if (target == null) {
      debugPrint('[deeplink] no route for $uri');
      return;
    }
    // If we're already on the target screen, skip navigation. This is the
    // common case for OAuth callbacks — the user tapped "Connect" from
    // /settings/trackers, the browser sent them back, and we're now
    // already on that screen. Calling .go() would replace the navigation
    // stack and the back button would disappear.
    final current =
        _router.routerDelegate.currentConfiguration.uri.path;
    if (current == target) {
      debugPrint('[deeplink] already on $target — skipping go()');
      return;
    }
    debugPrint('[deeplink] routing to $target');
    _router.go(target);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _maybeCheckNewChapters();
    }
    super.didChangeAppLifecycleState(state);
  }

  /// Fired by the engine when Android signals memory pressure
  /// (`onTrimMemory(TRIM_MEMORY_RUNNING_LOW)` etc). Drop every cached
  /// decoded image so the next paint cycle frees back to the system.
  /// Without this, the cache stays at its 64 MB cap even when the OS is
  /// about to start killing background services — which previously
  /// fragmented the heap enough to trigger native OOMs during the
  /// downloads worker burst.
  @override
  void didHaveMemoryPressure() {
    debugPrint('[memory] OS reported pressure — flushing image cache');
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    super.didHaveMemoryPressure();
  }

  /// Polls every saved book's source for new chapters and fires a
  /// notification on growth. Throttled to once per [_chapterCheckCooldown]
  /// so a user toggling between apps doesn't trigger N network calls.
  /// Fire-and-forget — runs in the background, no UI block.
  void _maybeCheckNewChapters() {
    final now = DateTime.now();
    if (_lastChapterCheckAt != null &&
        now.difference(_lastChapterCheckAt!) < _chapterCheckCooldown) {
      return;
    }
    _lastChapterCheckAt = now;
    // ignore: unawaited_futures
    sl<ChapterCheckService>().checkAllForNewChapters();
  }

  /// Foreground deep-link delivery. When the OS routes a sozoread:// URI to
  /// an already-running app, Flutter calls this with the URI's components.
  @override
  Future<bool> didPushRouteInformation(RouteInformation routeInformation) async {
    final raw = routeInformation.uri.toString();
    String? target;
    if (raw.startsWith('sozoread://')) {
      target = parseSozoReadDeepLink(routeInformation.uri);
    } else if (raw.startsWith('/manga/') || raw.startsWith('/chapter/')) {
      target = raw;
    }
    if (target != null) {
      final current =
          _router.routerDelegate.currentConfiguration.uri.path;
      if (current != target) {
        _router.go(target);
      }
      return true;
    }
    return super.didPushRouteInformation(routeInformation);
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider.value(
      value: sl<ThemeCubit>(),
      child: BlocBuilder<ThemeCubit, ThemeSettings>(
        builder: (context, theme) {
          // Light mode is disabled for v1 — the light palette hasn't been
          // polished yet. Hardcoding ThemeMode.dark ignores both the cubit's
          // saved value and the system theme. Remove this override (revert to
          // `themeMode: theme.mode`) once Light is ready to ship.
          return MaterialApp.router(
            title: 'Sozo Read',
            theme: AppTheme.buildLight(theme.accent),
            darkTheme: AppTheme.buildDark(theme.accent),
            themeMode: ThemeMode.dark,
            debugShowCheckedModeBanner: false,
            routerConfig: _router,
          );
        },
      ),
    );
  }
}
