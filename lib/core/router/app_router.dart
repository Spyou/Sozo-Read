import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../features/detail/screens/detail_screen.dart';
import '../../features/home/screens/home_screen.dart';
import '../../features/library/screens/library_screen.dart';
import '../../features/reader/manga_reader/screens/manga_reader_screen.dart';
import '../../features/reader/novel_reader/screens/novel_reader_screen.dart';
import '../../features/search/screens/search_screen.dart';
import '../../features/sources/screens/sources_screen.dart';
import '../models/book_detail.dart';
import '../models/book_item.dart';
import '../theme/app_colors.dart';

GoRouter buildRouter() {
  return GoRouter(
    initialLocation: '/home',
    routes: [
      ShellRoute(
        builder: (context, state, child) => _ShellScaffold(child: child),
        routes: [
          GoRoute(
            path: '/home',
            name: 'home',
            pageBuilder: (_, _) => const NoTransitionPage(child: HomeScreen()),
          ),
          GoRoute(
            path: '/library',
            name: 'library',
            pageBuilder: (_, _) => const NoTransitionPage(child: LibraryScreen()),
          ),
          GoRoute(
            path: '/sources',
            name: 'sources',
            pageBuilder: (_, _) => const NoTransitionPage(child: SourcesScreen()),
          ),
        ],
      ),
      GoRoute(
        path: '/search',
        name: 'search',
        builder: (_, _) => const SearchScreen(),
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
          // url should always be passed in extra for now
          return DetailScreen(
            sourceId: state.pathParameters['sourceId']!,
            url: url ?? '',
            placeholder: placeholder,
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
  const _ShellScaffold({required this.child});
  final Widget child;

  static const _tabs = <(String, IconData, String)>[
    ('/home', Icons.home_rounded, 'Home'),
    ('/library', Icons.bookmark_rounded, 'Library'),
    ('/sources', Icons.extension_rounded, 'Sources'),
  ];

  int _indexFor(BuildContext context) {
    final location = GoRouterState.of(context).uri.path;
    return _tabs.indexWhere((t) => location.startsWith(t.$1)).clamp(0, _tabs.length - 1);
  }

  @override
  Widget build(BuildContext context) {
    final index = _indexFor(context);
    return Scaffold(
      backgroundColor: AppColors.background,
      body: child,
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: index,
        onTap: (i) => context.go(_tabs[i].$1),
        items: _tabs
            .map((t) => BottomNavigationBarItem(icon: Icon(t.$2), label: t.$3))
            .toList(),
      ),
    );
  }
}
