import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/di/injection.dart';
import '../../../../core/models/book_detail.dart';
import '../../../../core/repository/library_repository.dart';
import '../../../../core/repository/provider_repository.dart';
import '../../../../core/widgets/state_views.dart';
import '../bloc/manga_reader_bloc.dart';
import '../bloc/manga_reader_event.dart';
import '../bloc/manga_reader_state.dart';
import '../widgets/page_image.dart';

class MangaReaderScreen extends StatelessWidget {
  const MangaReaderScreen({super.key, required this.book, required this.chapterIndex});

  final BookDetail book;
  final int chapterIndex;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => MangaReaderBloc(
        providerRepo: sl<ProviderRepository>(),
        libraryRepo: sl<LibraryRepository>(),
      )..add(MangaReaderStarted(book: book, chapterIndex: chapterIndex)),
      child: const _ReaderView(),
    );
  }
}

class _ReaderView extends StatefulWidget {
  const _ReaderView();
  @override
  State<_ReaderView> createState() => _ReaderViewState();
}

class _ReaderViewState extends State<_ReaderView> {
  bool _chromeVisible = true;
  final _scrollController = ScrollController();
  late final PageController _pageController = PageController();

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _scrollController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  void _toggleChrome() => setState(() => _chromeVisible = !_chromeVisible);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: BlocConsumer<MangaReaderBloc, MangaReaderState>(
        listenWhen: (a, b) => a.chapterIndex != b.chapterIndex,
        listener: (_, _) {
          if (_scrollController.hasClients) _scrollController.jumpTo(0);
          if (_pageController.hasClients) _pageController.jumpToPage(0);
        },
        builder: (context, state) {
          return Stack(
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggleChrome,
                child: _buildPages(context, state),
              ),
              if (_chromeVisible) _TopBar(state: state, onBack: () => context.pop()),
              if (_chromeVisible)
                _BottomBar(
                  state: state,
                  onPrev: () => context
                      .read<MangaReaderBloc>()
                      .add(MangaReaderChapterChanged(state.chapterIndex - 1)),
                  onNext: () => context
                      .read<MangaReaderBloc>()
                      .add(MangaReaderChapterChanged(state.chapterIndex + 1)),
                  onToggleMode: () =>
                      context.read<MangaReaderBloc>().add(const MangaReaderModeToggled()),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildPages(BuildContext context, MangaReaderState state) {
    if (state.status == ReaderStatus.loading) return const LoadingView();
    if (state.status == ReaderStatus.error) {
      return ErrorView(
        message: state.error ?? 'Failed to load pages',
        onRetry: () => context
            .read<MangaReaderBloc>()
            .add(MangaReaderChapterChanged(state.chapterIndex)),
      );
    }
    if (state.pages.isEmpty) return const EmptyView(message: 'No pages');

    if (state.mode == ReaderMode.vertical) {
      return NotificationListener<ScrollUpdateNotification>(
        onNotification: (n) {
          // Use scroll fraction (0..1) -> page index. Accurate regardless of
          // each page's actual rendered height.
          final max = n.metrics.maxScrollExtent;
          final total = state.pages.length;
          if (max > 0 && total > 0) {
            final frac = (n.metrics.pixels / max).clamp(0.0, 1.0);
            final idx = (frac * (total - 1)).round();
            if (idx != state.pageIndex) {
              context.read<MangaReaderBloc>().add(MangaReaderPageChanged(idx));
            }
          }
          return false;
        },
        child: ListView.builder(
          controller: _scrollController,
          // Build several screens ahead so images start downloading before the
          // user reaches them. Avoids "blank then half-loaded" feel on slow
          // image hosts.
          cacheExtent: MediaQuery.of(context).size.height * 4,
          itemCount: state.pages.length,
          itemBuilder: (_, i) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PageImage(page: state.pages[i]),
                // Subtle page marker so it's clear how many pages there are
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  color: Colors.black,
                  child: Text(
                    '${i + 1} / ${state.pages.length}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return PageView.builder(
      controller: _pageController,
      itemCount: state.pages.length,
      onPageChanged: (i) => context.read<MangaReaderBloc>().add(MangaReaderPageChanged(i)),
      itemBuilder: (_, i) => InteractiveViewer(
        child: Center(child: PageImage(page: state.pages[i], fit: BoxFit.contain)),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.state, required this.onBack});
  final MangaReaderState state;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final book = state.book;
    final chapter = (book != null && book.chapters.isNotEmpty)
        ? book.chapters[state.chapterIndex].title
        : '';
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: EdgeInsets.only(
          top: MediaQuery.of(context).padding.top,
          bottom: 8,
          left: 4,
          right: 8,
        ),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xCC000000), Colors.transparent],
          ),
        ),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: onBack,
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(book?.title ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                  Text(chapter,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white70, fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.state,
    required this.onPrev,
    required this.onNext,
    required this.onToggleMode,
  });
  final MangaReaderState state;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onToggleMode;

  @override
  Widget build(BuildContext context) {
    final book = state.book;
    final canPrev = state.chapterIndex > 0;
    final canNext = book != null && state.chapterIndex < book.chapters.length - 1;
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: EdgeInsets.only(
          top: 8,
          bottom: MediaQuery.of(context).padding.bottom + 8,
          left: 8,
          right: 8,
        ),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Color(0xCC000000), Colors.transparent],
          ),
        ),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.skip_previous, color: Colors.white),
              onPressed: canPrev ? onPrev : null,
            ),
            Expanded(
              child: Center(
                child: Text(
                  '${state.pageIndex + 1} / ${state.pages.length}',
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ),
            IconButton(
              icon: Icon(
                state.mode == ReaderMode.vertical ? Icons.view_carousel : Icons.view_day,
                color: Colors.white,
              ),
              onPressed: onToggleMode,
            ),
            IconButton(
              icon: const Icon(Icons.skip_next, color: Colors.white),
              onPressed: canNext ? onNext : null,
            ),
          ],
        ),
      ),
    );
  }
}
