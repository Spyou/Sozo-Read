import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hive/hive.dart';

import '../../features/detail/screens/detail_screen.dart';
import '../../features/genre_browse/screens/genre_browse_screen.dart';
import '../../features/home/screens/home_screen.dart';
import '../../features/library/screens/library_screen.dart';
import '../../features/onboarding/screens/onboarding_screen.dart';
import '../../features/reader/manga_reader/screens/manga_reader_screen.dart';
import '../../features/reader/novel_reader/screens/novel_reader_screen.dart';
import '../../features/search/screens/search_screen.dart';
import '../../features/settings/screens/settings_screen.dart';
import '../../features/sources/screens/sources_screen.dart';
import '../models/book_detail.dart';
import '../models/book_item.dart';
import '../theme/app_colors.dart';

GoRouter buildRouter() {
  // First-run gate: if the user hasn't completed onboarding yet, land on
  // /onboarding instead of /home. The `settings` box is opened during
  // AppBootstrap.initialize, so this read is always safe.
  final onboarded = Hive.box('settings').get('onboarded') == true;
  final initial = onboarded ? '/home' : '/onboarding';
  return GoRouter(
    initialLocation: initial,
    routes: [
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
    ],
  );
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
