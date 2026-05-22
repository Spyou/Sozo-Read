import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../features/auth/screens/auth_screen.dart';
import '../../features/bookmarks/screens/bookmarks_screen.dart';
import '../../features/detail/screens/detail_screen.dart';
import '../../features/downloads/screens/downloads_screen.dart';
import '../../features/genre_browse/screens/genre_browse_screen.dart';
import '../../features/history/screens/history_screen.dart';
import '../../features/home/screens/home_screen.dart';
import '../../features/library/screens/library_screen.dart';
import '../../features/notifications/screens/notifications_screen.dart';
import '../../features/onboarding/screens/onboarding_screen.dart';
import '../../features/profile/screens/profile_screen.dart';
import '../../features/reader/manga_reader/screens/manga_reader_screen.dart';
import '../../features/reader/novel_reader/screens/novel_reader_screen.dart';
import '../../features/search/screens/search_screen.dart';
import '../../features/settings/screens/about_settings_screen.dart';
import '../../features/settings/screens/appearance_settings_screen.dart';
import '../../features/settings/screens/changelog_screen.dart';
import '../../features/settings/screens/developers_settings_screen.dart';
import '../../features/settings/screens/reading_settings_screen.dart';
import '../../features/settings/screens/security_settings_screen.dart';
import '../../features/settings/screens/settings_screen.dart';
import '../../features/settings/screens/storage_settings_screen.dart';
import '../../features/settings/screens/trackers_settings_screen.dart';
import '../di/injection.dart';
import '../trackers/anilist/anilist_tracker.dart';
import '../trackers/mal/mal_tracker.dart';
import '../../features/sources/screens/source_settings_screen.dart';
import '../../features/sources/screens/sources_screen.dart';
import '../../features/splash/screens/splash_screen.dart';
import '../models/book_detail.dart';
import '../models/book_item.dart';
import '../theme/app_colors.dart';

/// Holds the most recent router instance so platform deep-link callbacks
/// (delivered through `WidgetsBindingObserver.didPushRouteInformation`) can
/// forward routes without dragging a `BuildContext` through `main.dart`.
GoRouter? _routerRef;
GoRouter? get appRouter => _routerRef;

/// Parses a `sozoread://` URI into an in-app path that go_router understands,
/// or returns `null` if the URI shouldn't be handled by this app.
///
/// Supported:
///   `sozoread://manga/{sourceId}/{bookId}?url={encoded}`
///   `sozoread://chapter/{sourceId}/{bookId}/{chapterIndex}?bookUrl={encoded}`
///   `sozoread://downloads`
String? parseSozoReadDeepLink(Uri uri) {
  if (uri.scheme != 'sozoread') return null;
  // On iOS the host is the first path segment (`manga`/`chapter`); on Android
  // it sometimes lands in `uri.host`. Normalise.
  final segments = <String>[
    if (uri.host.isNotEmpty) uri.host,
    ...uri.pathSegments.where((s) => s.isNotEmpty),
  ];
  if (segments.isEmpty) return null;
  final kind = segments.first;
  // Tapping the persistent downloads notification fires this — route the
  // user straight to the downloads queue screen.
  if (kind == 'downloads') {
    return '/downloads';
  }
  if (kind == 'login-callback') {
    // Forward the full URI (incl. fragment / query) as the `link` param so the
    // callback route can hand it to `getSessionFromUrl`.
    return Uri(
      path: '/login-callback',
      queryParameters: {'link': uri.toString()},
    ).toString();
  }
  // OAuth callback for the trackers (AniList implicit grant — token is in
  // the URL fragment, `sozoread://oauth/anilist#access_token=...`). We
  // hand the raw URI to the matching tracker as a side-effect, then send
  // the user back to the trackers settings screen so the UI refreshes.
  if (kind == 'oauth' && segments.length >= 2) {
    final service = segments[1];
    if (service == 'anilist') {
      // ignore: discarded_futures
      sl<AniListTracker>().completeLoginFromCallback(uri);
      return '/settings/trackers';
    }
    if (service == 'mal') {
      // ignore: discarded_futures
      sl<MalTracker>().completeLoginFromCallback(uri);
      return '/settings/trackers';
    }
  }
  if (kind == 'manga' && segments.length >= 3) {
    final sourceId = Uri.encodeComponent(segments[1]);
    final bookId = Uri.encodeComponent(segments[2]);
    final url = uri.queryParameters['url'] ?? '';
    return Uri(
      path: '/manga/$sourceId/$bookId',
      queryParameters: url.isEmpty ? null : {'url': url},
    ).toString();
  }
  if (kind == 'chapter' && segments.length >= 4) {
    final sourceId = Uri.encodeComponent(segments[1]);
    final bookId = Uri.encodeComponent(segments[2]);
    final chapterIndex = Uri.encodeComponent(segments[3]);
    final bookUrl = uri.queryParameters['bookUrl'] ?? '';
    return Uri(
      path: '/chapter/$sourceId/$bookId/$chapterIndex',
      queryParameters: bookUrl.isEmpty ? null : {'bookUrl': bookUrl},
    ).toString();
  }
  return null;
}

GoRouter buildRouter() {
  // Cold-start deep link: Flutter exposes the launch URL on
  // `PlatformDispatcher.defaultRouteName`. If the OS handed us a sozoread://
  // URI it will already be normalised to a path-only form here.
  final initial = _resolveInitialLocation();
  final router = GoRouter(
    initialLocation: initial,
    routes: [
      GoRoute(
        path: '/splash',
        name: 'splash',
        builder: (_, _) => const SplashScreen(),
      ),
      // Bottom-nav shell. IndexedStack keeps each tab's widget mounted so the
      // home BLoC doesn't refetch when the user toggles between tabs.
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            _ShellScaffold(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/home',
              name: 'home',
              pageBuilder: (_, _) => const NoTransitionPage(child: HomeScreen()),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/library',
              name: 'library',
              pageBuilder: (_, _) => const NoTransitionPage(child: LibraryScreen()),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/search',
              name: 'search',
              pageBuilder: (_, _) => const NoTransitionPage(child: SearchScreen()),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/settings',
              name: 'settings',
              pageBuilder: (_, _) => const NoTransitionPage(child: SettingsScreen()),
            ),
          ]),
        ],
      ),

      // Onboarding lives outside the shell so it has no bottom-nav.
      GoRoute(
        path: '/onboarding',
        name: 'onboarding',
        builder: (_, _) => const OnboardingScreen(),
      ),

      // Modal-style routes — pushed on top of the shell.
      GoRoute(
        path: '/sources',
        name: 'sources',
        builder: (_, _) => const SourcesScreen(),
      ),
      GoRoute(
        // The composite `(repoUrl, sourceId)` key can't fit in the
        // path because `repoUrl` contains slashes — pass it via query
        // params instead. `extra` would work too but query lets the
        // route survive deep-linking later if needed.
        path: '/sources/:sourceId/settings',
        name: 'source-settings',
        builder: (_, state) {
          final repoUrl = state.uri.queryParameters['repoUrl'] ?? '';
          final displayName = state.uri.queryParameters['displayName'];
          return SourceSettingsScreen(
            sourceId: state.pathParameters['sourceId']!,
            repoUrl: repoUrl,
            displayName: displayName,
          );
        },
      ),
      GoRoute(
        path: '/history',
        name: 'history',
        builder: (_, _) => const HistoryScreen(),
      ),
      GoRoute(
        path: '/downloads',
        name: 'downloads',
        builder: (_, _) => const DownloadsScreen(),
      ),
      GoRoute(
        path: '/bookmarks',
        name: 'bookmarks',
        builder: (_, _) => const BookmarksScreen(),
      ),
      GoRoute(
        path: '/notifications',
        name: 'notifications',
        builder: (_, _) => const NotificationsScreen(),
      ),
      GoRoute(
        path: '/auth',
        name: 'auth',
        builder: (_, state) {
          final mode = state.uri.queryParameters['mode'];
          return AuthScreen(
            initialMode:
                mode == 'signup' ? AuthMode.signUp : AuthMode.signIn,
          );
        },
      ),
      GoRoute(
        path: '/profile',
        name: 'profile',
        builder: (_, _) => const ProfileScreen(),
      ),
      GoRoute(
        path: '/settings/appearance',
        name: 'settings-appearance',
        builder: (_, _) => const AppearanceSettingsScreen(),
      ),
      GoRoute(
        path: '/settings/reading',
        name: 'settings-reading',
        builder: (_, _) => const ReadingSettingsScreen(),
      ),
      GoRoute(
        path: '/settings/storage',
        name: 'settings-storage',
        builder: (_, _) => const StorageSettingsScreen(),
      ),
      GoRoute(
        path: '/settings/developers',
        name: 'settings-developers',
        builder: (_, _) => const DevelopersSettingsScreen(),
      ),
      GoRoute(
        path: '/settings/about',
        name: 'settings-about',
        builder: (_, _) => const AboutSettingsScreen(),
      ),
      GoRoute(
        path: '/settings/changelog',
        name: 'settings-changelog',
        builder: (_, _) => const ChangelogScreen(),
      ),
      GoRoute(
        path: '/settings/trackers',
        name: 'settings-trackers',
        builder: (_, _) => const TrackersSettingsScreen(),
      ),
      GoRoute(
        path: '/settings/security',
        name: 'settings-security',
        builder: (_, _) => const SecuritySettingsScreen(),
      ),
      GoRoute(
        path: '/detail/:sourceId/:bookId',
        name: 'detail',
        builder: (_, state) {
          final extra = state.extra;
          BookItem? placeholder;
          String? url;
          if (extra is BookItem) {
            placeholder = extra;
            url = extra.url;
          }
          return DetailScreen(
            sourceId: state.pathParameters['sourceId']!,
            url: url ?? '',
            placeholder: placeholder,
          );
        },
      ),
      GoRoute(
        path: '/genre/:sourceId/:genre',
        name: 'genre-browse',
        builder: (_, state) {
          final raw = state.pathParameters['genre']!;
          // The path segment is URL-encoded by go_router; decode for display
          // and for use as the search query.
          final decoded = Uri.decodeComponent(raw);
          return GenreBrowseScreen(
            sourceId: state.pathParameters['sourceId']!,
            genre: decoded,
          );
        },
      ),
      GoRoute(
        path: '/reader/manga/:sourceId/:bookId',
        name: 'manga-reader',
        builder: (_, state) {
          final extra = state.extra as Map<String, dynamic>;
          return MangaReaderScreen(
            book: extra['book'] as BookDetail,
            chapterIndex: extra['chapterIndex'] as int,
            initialPageIndex: extra['initialPageIndex'] as int?,
          );
        },
      ),
      GoRoute(
        path: '/reader/novel/:sourceId/:bookId',
        name: 'novel-reader',
        builder: (_, state) {
          final extra = state.extra as Map<String, dynamic>;
          return NovelReaderScreen(
            book: extra['book'] as BookDetail,
            chapterIndex: extra['chapterIndex'] as int,
          );
        },
      ),

      // Supabase magic-link return URL — `sozoread://login-callback`.
      // Consumes the OTP from the URL fragment and routes the user home.
      GoRoute(
        path: '/login-callback',
        name: 'login-callback',
        builder: (_, state) {
          final encoded = state.uri.queryParameters['link'] ?? '';
          return _LoginCallbackScreen(rawLink: encoded);
        },
      ),

      // Deep-link entry points (sozoread://). The path-only forms here are
      // what `parseSozoReadDeepLink` rewrites to. Both routes ultimately land
      // the user on the detail screen — the reader is reached by the user
      // tapping the desired chapter after the detail loads.
      GoRoute(
        path: '/manga/:sourceId/:bookId',
        name: 'deep-manga',
        builder: (_, state) {
          final encoded = state.uri.queryParameters['url'] ?? '';
          final url = encoded.isEmpty ? '' : Uri.decodeComponent(encoded);
          return DetailScreen(
            sourceId: state.pathParameters['sourceId']!,
            url: url,
            placeholder: null,
          );
        },
      ),
      GoRoute(
        path: '/chapter/:sourceId/:bookId/:chapterIndex',
        name: 'deep-chapter',
        // MVP: just open detail. Chapter pre-jump is a follow-up — opening
        // the reader needs the BookDetail object which is only resolvable
        // after the detail load completes.
        redirect: (_, state) {
          final src = state.pathParameters['sourceId']!;
          final book = state.pathParameters['bookId']!;
          final bookUrl = state.uri.queryParameters['bookUrl'];
          final q = bookUrl == null || bookUrl.isEmpty
              ? ''
              : '?url=${Uri.encodeQueryComponent(bookUrl)}';
          return '/manga/$src/$book$q';
        },
      ),
    ],
  );
  _routerRef = router;
  return router;
}

String _resolveInitialLocation() {
  const fallback = '/splash';
  final raw = ui.PlatformDispatcher.instance.defaultRouteName;
  if (raw.isEmpty || raw == '/') return fallback;
  // The launcher may hand us a full sozoread:// URI on cold start.
  if (raw.startsWith('sozoread://')) {
    return parseSozoReadDeepLink(Uri.parse(raw)) ?? fallback;
  }
  // Or it may be a normalised path that already matches our deep-link routes.
  if (raw.startsWith('/manga/') ||
      raw.startsWith('/chapter/') ||
      raw.startsWith('/login-callback')) {
    return raw;
  }
  return fallback;
}

class _ShellScaffold extends StatelessWidget {
  const _ShellScaffold({required this.navigationShell});
  final StatefulNavigationShell navigationShell;

  static const _tabs = <(IconData, String)>[
    (Icons.home_rounded, 'Home'),
    (Icons.bookmark_rounded, 'Library'),
    (Icons.search_rounded, 'Search'),
    (Icons.settings_rounded, 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: navigationShell,
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: navigationShell.currentIndex,
        onTap: (i) => navigationShell.goBranch(
          i,
          // Reset the branch's stack when re-tapping the active tab.
          initialLocation: i == navigationShell.currentIndex,
        ),
        items: [
          for (final t in _tabs)
            BottomNavigationBarItem(icon: Icon(t.$1), label: t.$2),
        ],
      ),
    );
  }
}

/// Handles the redirect from a Supabase magic-link email. The OTP arrives in
/// the URL fragment; we hand the full URI to `getSessionFromUrl` which
/// completes the session, then bounce the user to `/home`.
class _LoginCallbackScreen extends StatefulWidget {
  const _LoginCallbackScreen({required this.rawLink});
  final String rawLink;

  @override
  State<_LoginCallbackScreen> createState() => _LoginCallbackScreenState();
}

class _LoginCallbackScreenState extends State<_LoginCallbackScreen> {
  String? _error;

  @override
  void initState() {
    super.initState();
    _consume();
  }

  Future<void> _consume() async {
    try {
      final raw = widget.rawLink.isEmpty
          ? Uri.base
          : Uri.parse(Uri.decodeComponent(widget.rawLink));
      await Supabase.instance.client.auth.getSessionFromUrl(raw);
      if (!mounted) return;
      context.go('/home');
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: _error == null
            ? const CircularProgressIndicator()
            : Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline, size: 48),
                    const SizedBox(height: 12),
                    Text('Sign-in failed:\n$_error',
                        textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: () => context.go('/home'),
                      child: const Text('Continue'),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
