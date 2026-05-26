import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import '../../../core/services/image_cache_manager.dart';
import 'package:flutter/material.dart';
import '../../../core/widgets/app_snack.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:hive/hive.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shimmer/shimmer.dart';

import 'package:dio/dio.dart';

import '../../../core/di/injection.dart';
import '../../../core/models/book_detail.dart';
import '../../../core/models/book_item.dart';
import '../../../core/models/chapter.dart';
import '../../../core/models/page_content.dart';
import '../../../core/models/provider_info.dart';
import '../../../core/repository/book_detail_cache.dart';
import '../../../core/repository/chapter_bookmarks_repository.dart';
import '../../../core/repository/chapter_thumbnails_repository.dart';
import '../../../core/repository/cross_source_match_cache.dart';
import '../../../core/repository/downloads_repository.dart';
import '../../../core/repository/library_repository.dart';
import '../../../core/repository/page_bookmarks_repository.dart';
import '../../../core/repository/provider_repository.dart';
import '../../../core/repository/read_chapters_repository.dart';
import '../../../core/services/cross_source_matcher.dart';
import '../../../core/state/auth_service.dart';
import '../../../core/state/auto_switch_prefs.dart';
import '../../../core/state/chapter_sort_cubit.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/book_card.dart';
import '../../../core/widgets/state_views.dart';
import '../widgets/tracker_status_pill.dart';
import '../bloc/detail_bloc.dart';
import '../bloc/detail_event.dart';
import '../bloc/detail_state.dart';

class DetailScreen extends StatelessWidget {
  const DetailScreen({super.key, required this.sourceId, required this.url, this.placeholder});

  final String sourceId;
  final String url;
  final BookItem? placeholder;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => DetailBloc(
        providerRepo: sl<ProviderRepository>(),
        libraryRepo: sl<LibraryRepository>(),
        readChaptersRepo: sl<ReadChaptersRepository>(),
        cache: sl<BookDetailCache>(),
        matcher: sl<CrossSourceMatcher>(),
        matchCache: sl<CrossSourceMatchCache>(),
        autoSwitch: sl<AutoSwitchPrefs>(),
      )..add(DetailLoaded(
          sourceId: sourceId,
          url: url,
          // Threaded through so the bloc can do a cache lookup without
          // waiting for the network — see DetailBloc._fetch.
          bookId: placeholder?.id,
          // Title for the auto-switch fanout when detail fetch fails
          // before anything else (cache, library) can supply one.
          placeholderTitle: placeholder?.title,
        )),
      child: _DetailView(placeholder: placeholder),
    );
  }
}

class _DetailView extends StatelessWidget {
  const _DetailView({this.placeholder});
  final BookItem? placeholder;

  Future<void> _handleToggleLibrary(BuildContext context) async {
    // Saving to library requires a signed-in account so the entries can be
    // cloud-synced (Round 4 sync engine). When signed out, surface the
    // requirement inline instead of silently writing a local-only entry
    // that would be wiped on the next sign-in.
    if (!sl<AuthService>().isSignedIn) {
      ScaffoldMessenger.of(context).showAppSnack(
        SnackBar(
          content: const Text('Sign in to save manga to your library.'),
          action: SnackBarAction(
            label: 'Sign in',
            textColor: Colors.white,
            onPressed: () => context.push('/auth'),
          ),
        ),
      );
      return;
    }
    final bloc = context.read<DetailBloc>();
    final currentStatus = bloc.state.library?.status;
    final result = await showModalBottomSheet<_LibraryAction>(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) =>
          _LibraryStatusSheet(currentStatus: currentStatus),
    );
    if (result == null) return;
    if (result.remove) {
      bloc.add(const DetailLibraryRemoved());
    } else if (result.status != null) {
      bloc.add(DetailLibrarySaved(result.status!));
    }
  }

  Future<void> _handleShare(BuildContext context, BookDetail book) async {
    // Build a `sozoread://manga/<sourceId>/<bookId>?url=<encoded book.url>`
    // deep link. The receiving side (parseSozoReadDeepLink in app_router.dart)
    // decodes these segments back into route parameters.
    final link =
        'sozoread://manga/${Uri.encodeComponent(book.sourceId)}/${Uri.encodeComponent(book.id)}'
        '?url=${Uri.encodeQueryComponent(book.url)}';
    final shareText = '${book.title} on Sozo Read\n$link';
    // share_plus 10.x exposes the static `Share.share(...)` helper. The
    // `SharePlus.instance.share(ShareParams(...))` API only landed in 11.x.
    await Share.share(shareText, subject: book.title);
  }

  void _openReader(
    BuildContext context,
    BookDetail book,
    int chapterIndex, {
    int? initialPageIndex,
  }) {
    final isManga = book.type.name != 'novel';
    context.pushNamed(
      isManga ? 'manga-reader' : 'novel-reader',
      pathParameters: {'sourceId': book.sourceId, 'bookId': book.id},
      extra: {
        'book': book,
        'chapterIndex': chapterIndex,
        'initialPageIndex': ?initialPageIndex,
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      // Listen for cross-source fallback suggestions and surface them as
      // a snackbar with Switch / Cancel actions. The bloc only emits this
      // when the user has opted in via AutoSwitchPrefs.
      body: BlocListener<DetailBloc, DetailState>(
        listenWhen: (prev, curr) =>
            prev.fallbackSuggestion != curr.fallbackSuggestion &&
            curr.fallbackSuggestion != null,
        listener: (ctx, state) => _showFallbackSnack(ctx, state),
        child: BlocBuilder<DetailBloc, DetailState>(
          builder: (context, state) {
            if (state.status == DetailStatus.loading && state.book == null) {
              return _SkeletonDetail(placeholder: placeholder);
            }
            if (state.status == DetailStatus.error && state.book == null) {
              return ErrorView(
                message: state.error ?? 'Failed to load',
                onRetry: () =>
                    context.read<DetailBloc>().add(const DetailReloaded()),
              );
            }
            final book = state.book;
            if (book == null) return const LoadingView();
            return _DetailBody(
              book: book,
              inLibrary: state.inLibrary,
              lastChapterIndex: state.library?.lastChapterIndex ?? 0,
              readChapterIds: state.readChapterIds,
              similar: state.similar,
              similarLoading: state.similarStatus == SimilarStatus.loading,
              onToggleLibrary: () => _handleToggleLibrary(context),
              onShare: () => _handleShare(context, book),
              onOpenChapter: (i) => _openReader(context, book, i),
              onOpenChapterAtPage: (i, page) =>
                  _openReader(context, book, i, initialPageIndex: page),
            );
          },
        ),
      ),
    );
  }

  void _showFallbackSnack(BuildContext context, DetailState state) {
    final s = state.fallbackSuggestion;
    if (s == null) return;
    final bloc = context.read<DetailBloc>();
    var actionTaken = false;
    final messenger = ScaffoldMessenger.of(context);
    final ctrl = messenger.showAppSnack(
      SnackBar(
        duration: const Duration(seconds: 8),
        content: Text(
          'This source failed — found this on ${s.displayName}. Switch?',
        ),
        action: SnackBarAction(
          label: 'Switch',
          textColor: Colors.white,
          onPressed: () {
            actionTaken = true;
            // Build the BookItem placeholder the detail route expects.
            final placeholder = BookItem(
              id: s.bookId,
              title: state.book?.title ?? '',
              url: s.url,
              type: state.book?.type ?? ProviderType.manga,
              sourceId: s.sourceId,
            );
            // Replace current route so back doesn't bounce into the
            // same failing page.
            context.replaceNamed(
              'detail',
              pathParameters: {
                'sourceId': s.sourceId,
                'bookId': s.bookId,
              },
              extra: placeholder,
            );
          },
        ),
      ),
    );
    // Fire the dismiss event when the snackbar closes (timeout, swipe,
    // or after the action ran). Guarded against the bloc being closed.
    // ignore: discarded_futures
    ctrl.closed.then((_) {
      if (!actionTaken && !bloc.isClosed) {
        bloc.add(const DetailDismissFallback());
      }
    });
  }
}

class _DetailBody extends StatefulWidget {
  const _DetailBody({
    required this.book,
    required this.inLibrary,
    required this.lastChapterIndex,
    required this.readChapterIds,
    required this.similar,
    required this.similarLoading,
    required this.onToggleLibrary,
    required this.onShare,
    required this.onOpenChapter,
    required this.onOpenChapterAtPage,
  });

  final BookDetail book;
  final bool inLibrary;
  final int lastChapterIndex;
  final Set<String> readChapterIds;
  final List<BookItem> similar;
  final bool similarLoading;
  final VoidCallback onToggleLibrary;
  final VoidCallback onShare;
  final void Function(int chapterIndex) onOpenChapter;

  /// Used by the Bookmarks tab when the user taps a page bookmark — the
  /// reader needs both the chapter index AND the bookmark's page index
  /// so it lands on the exact saved page, not the chapter's beginning.
  final void Function(int chapterIndex, int pageIndex) onOpenChapterAtPage;

  @override
  State<_DetailBody> createState() => _DetailBodyState();
}

class _DetailBodyState extends State<_DetailBody> with SingleTickerProviderStateMixin {
  late final TabController _tabController = TabController(length: 4, vsync: this);

  static const double _expandedHeight = 340;
  // Show the app-bar title once the user has scrolled past the cover.
  bool _showAppBarTitle = false;
  // Tracker info is hidden by default — toggled on via the timeline icon
  // in the app bar. Keeps the detail page un-cluttered for users who
  // don't care about sync.
  bool _showTracker = false;
  // Chapter-list search state. Search field is hidden by default; tapping
  // the magnifier toggles it. Query is local to the detail page lifetime —
  // it resets the next time the user opens this screen.
  final TextEditingController _chapterSearchController = TextEditingController();
  bool _chapterSearchExpanded = false;
  String _chapterSearchQuery = '';

  // Memoized chapter display list. Filter+sort over a 1000+ chapter list
  // is cheap individually (sub-ms) but compounds when BlocBuilder rebuilds
  // fire on every search keystroke or progress event. Cache the result
  // against (book identity, sort direction, query) so repeated rebuilds
  // with identical inputs return the same list without re-walking.
  List<({int originalIndex, Chapter chapter})>? _displayCache;
  String? _displayCacheBookKey;
  bool? _displayCacheAscending;
  String? _displayCacheQuery;

  // Multi-select state for batch chapter actions (download / mark
  // read). Enter mode via long-press on a chapter row. Set holds the
  // selected chapter IDs (stable across re-sorts) — exits to empty +
  // [_selectMode] = false when the user cancels or completes an action.
  bool _selectMode = false;
  final Set<String> _selectedChapterIds = <String>{};

  void _enterSelectMode(Chapter ch) {
    setState(() {
      _selectMode = true;
      _selectedChapterIds.add(ch.id);
    });
  }

  void _toggleSelected(Chapter ch) {
    setState(() {
      if (_selectedChapterIds.contains(ch.id)) {
        _selectedChapterIds.remove(ch.id);
        // Auto-exit when the user deselects the last row — saves them
        // an explicit X tap.
        if (_selectedChapterIds.isEmpty) _selectMode = false;
      } else {
        _selectedChapterIds.add(ch.id);
      }
    });
  }

  void _exitSelectMode() {
    setState(() {
      _selectMode = false;
      _selectedChapterIds.clear();
    });
  }

  /// Looks up the chapters whose IDs match the current selection. Walks
  /// [book.chapters] once so the result is in source order (newest-first).
  List<Chapter> _selectedChapters(BookDetail book) {
    if (_selectedChapterIds.isEmpty) return const [];
    return [
      for (final ch in book.chapters)
        if (_selectedChapterIds.contains(ch.id)) ch,
    ];
  }

  Future<void> _enqueueChapters(
    BookDetail book,
    List<Chapter> chapters,
  ) async {
    if (chapters.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    final providerRepo = sl<ProviderRepository>();
    // The foundation agent's enqueueMany handles per-chapter errors
    // (logs + skips), so we don't try/catch here — only the outer call
    // could throw (e.g. Hive write error) which we surface generically.
    try {
      await sl<DownloadsRepository>().enqueueMany(
        book: book,
        chapters: chapters,
        fetchPages: (ch) => providerRepo
            .pages(book.sourceId, ch.url)
            .then((r) => r.fold((_) => <PageContent>[], (p) => p)),
        dio: sl<Dio>(),
      );
      messenger.showAppSnack(
        SnackBar(
          content: Text(
            'Downloading ${chapters.length} chapter${chapters.length == 1 ? '' : 's'}',
          ),
        ),
      );
    } catch (e) {
      messenger.showAppSnack(
        SnackBar(content: Text('Could not start downloads: $e')),
      );
    }
  }

  Future<void> _downloadSelected(BookDetail book) async {
    final chapters = _selectedChapters(book);
    if (chapters.isEmpty) return;
    await _enqueueChapters(book, chapters);
    if (!mounted) return;
    _exitSelectMode();
  }

  Future<void> _markSelected(BookDetail book, {required bool read}) async {
    final messenger = ScaffoldMessenger.of(context);
    final repo = sl<ReadChaptersRepository>();
    final ids = List<String>.from(_selectedChapterIds);
    for (final id in ids) {
      try {
        if (read) {
          await repo.mark(book.sourceId, book.id, id);
        } else {
          await repo.unmark(book.sourceId, book.id, id);
        }
      } catch (_) {
        // Swallow per-chapter so one bad row doesn't kill the batch.
      }
    }
    if (!mounted) return;
    messenger.showAppSnack(
      SnackBar(
        content: Text(
          read
              ? 'Marked ${ids.length} chapter${ids.length == 1 ? '' : 's'} as read'
              : 'Marked ${ids.length} chapter${ids.length == 1 ? '' : 's'} as unread',
        ),
      ),
    );
    _exitSelectMode();
    // Force a rebuild so the read-state opacity in the chapter list
    // updates without waiting for the bloc to refresh.
    setState(() {});
  }

  bool _onScroll(ScrollNotification n) {
    // Only react to vertical scrolls in the outer (header) viewport.
    if (n.metrics.axis != Axis.vertical) return false;
    final showThreshold = _expandedHeight - kToolbarHeight - 24;
    final shouldShow = n.metrics.pixels > showThreshold;
    if (shouldShow != _showAppBarTitle) {
      setState(() => _showAppBarTitle = shouldShow);
    }
    return false;
  }

  @override
  void dispose() {
    _tabController.dispose();
    _chapterSearchController.dispose();
    super.dispose();
  }

  void _openGenre(BuildContext context, String genre) {
    context.pushNamed(
      'genre-browse',
      pathParameters: {
        'sourceId': widget.book.sourceId,
        // Encode so '/' or spaces in genre names don't break the path.
        'genre': Uri.encodeComponent(genre),
      },
    );
  }

  void _openSimilar(BuildContext context, BookItem item) {
    context.pushNamed(
      'detail',
      pathParameters: {'sourceId': item.sourceId, 'bookId': item.id},
      extra: item,
    );
  }

  void _toggleChapterSearch() {
    setState(() {
      _chapterSearchExpanded = !_chapterSearchExpanded;
      // Closing the search clears the query so the next open starts
      // fresh and the chapter list is back to full.
      if (!_chapterSearchExpanded) {
        _chapterSearchController.clear();
        _chapterSearchQuery = '';
      }
    });
  }

  /// Applies the current ascending/descending sort + search filter to
  /// the book's chapters and returns the display list. Each entry knows
  /// its original index so taps still map back to the bloc's
  /// newest-first chapterIndex world.
  ///
  /// Memoized — when the (book, ascending, query) tuple is unchanged
  /// from the previous call, the cached list is returned without
  /// re-walking the chapters. BlocBuilder triggers a rebuild on every
  /// state mutation (chapter-read updates, library writes, etc.) so the
  /// hit rate is high during normal use.
  List<({int originalIndex, Chapter chapter})> _buildChapterDisplay(
    BookDetail book,
    bool ascending,
  ) {
    // Book identity = sourceId + bookId + chapters.length. The length
    // guards against in-place chapter-list growth (pull-to-refresh adds
    // a new chapter) — counting bytes here would be slower than just
    // rebuilding.
    final bookKey = '${book.sourceId}::${book.id}::${book.chapters.length}';
    final q = _chapterSearchQuery.trim().toLowerCase();
    if (_displayCache != null &&
        _displayCacheBookKey == bookKey &&
        _displayCacheAscending == ascending &&
        _displayCacheQuery == q) {
      return _displayCache!;
    }

    final indexed = List.generate(
      book.chapters.length,
      (i) => (originalIndex: i, chapter: book.chapters[i]),
    );
    // Source returns chapters newest-first. Ascending = oldest-first, so
    // we reverse the list. Descending keeps the source order.
    final ordered = ascending ? indexed.reversed.toList() : indexed;
    final List<({int originalIndex, Chapter chapter})> result;
    if (q.isEmpty) {
      result = ordered;
    } else {
      result = ordered.where((e) {
        final title = e.chapter.title.toLowerCase();
        if (title.contains(q)) return true;
        // Number-only match as a fallback (titles vary widely between
        // sources; some don't include the chapter number at all).
        final num = e.chapter.number;
        if (num != null && num.toString().contains(q)) return true;
        return false;
      }).toList();
    }

    _displayCache = result;
    _displayCacheBookKey = bookKey;
    _displayCacheAscending = ascending;
    _displayCacheQuery = q;
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final book = widget.book;
    final inLibrary = widget.inLibrary;
    final lastChapterIndex = widget.lastChapterIndex;
    final similar = widget.similar;
    final similarLoading = widget.similarLoading;
    final onToggleLibrary = widget.onToggleLibrary;
    final onOpenChapter = widget.onOpenChapter;

    return PopScope(
      // Intercept the back gesture/button while multi-select is active
      // so the user lands back on the chapter list instead of popping
      // the whole detail screen.
      canPop: !_selectMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selectMode) _exitSelectMode();
      },
      child: Stack(
        children: [
          NotificationListener<ScrollNotification>(
            onNotification: _onScroll,
            child: NestedScrollView(
      headerSliverBuilder: (context, _) => [
        SliverAppBar(
          expandedHeight: _expandedHeight,
          pinned: true,
          backgroundColor: AppColors.background,
          surfaceTintColor: Colors.transparent,
          shadowColor: Colors.transparent,
          centerTitle: false,
          titleSpacing: 0,
          title: AnimatedOpacity(
            opacity: _showAppBarTitle ? 1 : 0,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            child: Text(
              book.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.2,
              ),
            ),
          ),
          actions: [
            IconButton(
              tooltip: _showTracker ? 'Hide tracker' : 'Show tracker',
              icon: Icon(
                _showTracker
                    ? Icons.track_changes_rounded
                    : Icons.track_changes_outlined,
                color: Colors.white,
              ),
              onPressed: () =>
                  setState(() => _showTracker = !_showTracker),
            ),
            IconButton(
              tooltip: 'Share',
              icon: const Icon(
                Icons.share_rounded,
                color: Colors.white,
              ),
              onPressed: widget.onShare,
            ),
            IconButton(
              tooltip: inLibrary ? 'In library' : 'Save to library',
              icon: Icon(
                inLibrary ? Icons.bookmark : Icons.bookmark_outline,
                color: Colors.white,
              ),
              onPressed: onToggleLibrary,
            ),
          ],
          flexibleSpace: FlexibleSpaceBar(
            collapseMode: CollapseMode.parallax,
            background: _BackdropHeader(book: book),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (book.description != null && book.description!.isNotEmpty) ...[
                  Text(
                    book.description!,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: AppColors.textSecondary,
                          height: 1.4,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _tabController.animateTo(2),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(
                          'More',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
                if (book.genres.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: book.genres.take(5).map((g) {
                      return ActionChip(
                        label: Text(g),
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        onPressed: () => _openGenre(context, g),
                      );
                    }).toList(),
                  ),
                ],
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.play_arrow_rounded, size: 22),
                    label: Text(
                      widget.readChapterIds.isNotEmpty
                          ? 'Continue reading'
                          : 'Start reading',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.primary,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      elevation: 0,
                    ),
                    onPressed: book.chapters.isEmpty
                        ? null
                        : () => onOpenChapter(
                              lastChapterIndex.clamp(0, book.chapters.length - 1),
                            ),
                  ),
                ),
                // Reading-progress bar. Hidden for never-opened series so a
                // brand-new detail page stays clean; shows the moment you
                // finish your first chapter.
                if (widget.readChapterIds.isNotEmpty &&
                    book.chapters.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: _ReadingProgress(
                      readCount: widget.readChapterIds.length,
                      totalCount: book.chapters.length,
                    ),
                  ),
                // Tracker card (AniList). Hidden by default — surfaces only
                // when the user taps the timeline icon in the app bar.
                // The card owns its own horizontal margins so this slot
                // is left flush.
                if (_showTracker)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: TrackerStatusPill(
                      sourceId: book.sourceId,
                      bookId: book.id,
                      localTitle: book.title,
                    ),
                  ),
                // Batch-download shortcut row. Only shown when there's
                // at least one chapter AND the user hasn't already
                // finished everything (otherwise both buttons would
                // be no-ops). Sits between the primary actions and
                // the tab bar so it stays close to the chapter list
                // Quick-batch buttons (Download next 5 / Download all
                // unread) intentionally removed — they cluttered the
                // detail header. Same actions are available via the
                // long-press multi-select flow on the chapter list.
              ],
            ),
          ),
        ),
        SliverPersistentHeader(
          pinned: true,
          delegate: _TabBarDelegate(
            _BookmarkAwareTabBar(
              controller: _tabController,
              chapterCount: book.chapters.length,
              sourceId: book.sourceId,
              bookId: book.id,
              accent: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
      ],
      body: TabBarView(
        controller: _tabController,
        children: [
          // ---- Chapters ----
          _RefreshableTab(
            child: book.chapters.isEmpty
                ? ListView(
                    // ListView so the RefreshIndicator can still be triggered.
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: const [
                      SizedBox(height: 48),
                      EmptyView(
                        icon: Icons.menu_book_outlined,
                        message:
                            'No chapters available from this source.\nTry another source.',
                      ),
                    ],
                  )
                : BlocBuilder<ChapterSortCubit, bool>(
                    bloc: sl<ChapterSortCubit>(),
                    builder: (context, ascending) {
                      final display = _buildChapterDisplay(book, ascending);
                      return Column(
                        children: [
                          _ChapterListHeader(
                            ascending: ascending,
                            searchExpanded: _chapterSearchExpanded,
                            searchController: _chapterSearchController,
                            onToggleSort: () =>
                                sl<ChapterSortCubit>().toggle(),
                            onToggleSearch: _toggleChapterSearch,
                            onSearchChanged: (v) =>
                                setState(() => _chapterSearchQuery = v),
                            filteredCount: display.length,
                            totalCount: book.chapters.length,
                          ),
                          Expanded(
                            child: display.isEmpty
                                ? const EmptyView(
                                    icon: Icons.search_off_rounded,
                                    message: 'No chapters match this search.',
                                  )
                                // Thumbnail subscription has been pushed
                                // DOWN into each [_ChapterThumbnail] —
                                // wrapping the whole list in a watch
                                // stream rebuilt all visible rows on
                                // every thumbnail write, expensive in a
                                // 1000-chapter scroll path. Per-row
                                // listeners filter by chapterId and only
                                // the affected row rebuilds.
                                : ListView.separated(
                                    physics:
                                        const AlwaysScrollableScrollPhysics(),
                                    padding: EdgeInsets.zero,
                                    itemCount: display.length,
                                    separatorBuilder: (_, _) =>
                                        const Divider(height: 1),
                                    itemBuilder: (_, displayIndex) {
                                      final entry = display[displayIndex];
                                      final i = entry.originalIndex;
                                      final Chapter ch = entry.chapter;
                                      final read = widget.readChapterIds
                                              .contains(ch.id) ||
                                          i < lastChapterIndex;
                                      final selected = _selectedChapterIds
                                          .contains(ch.id);
                                      final titleStyle = TextStyle(
                                        color: read
                                            ? AppColors.textTertiary
                                            : AppColors.textPrimary,
                                        fontWeight: i == lastChapterIndex
                                            ? FontWeight.w600
                                            : FontWeight.w400,
                                      );
                                      final titleText = Text(
                                        ch.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: titleStyle,
                                      );
                                      // In select mode, the leading slot
                                      // swaps from the chapter thumbnail
                                      // to a checkbox so the row's
                                      // selectable state reads at a
                                      // glance. Outside select mode the
                                      // original thumbnail returns.
                                      final Widget leading = _selectMode
                                          ? SizedBox(
                                              width: 48,
                                              height: 64,
                                              child: Center(
                                                child: Checkbox(
                                                  value: selected,
                                                  onChanged: (_) =>
                                                      _toggleSelected(ch),
                                                  visualDensity:
                                                      VisualDensity.compact,
                                                  materialTapTargetSize:
                                                      MaterialTapTargetSize
                                                          .shrinkWrap,
                                                  activeColor:
                                                      AppColors.primary,
                                                ),
                                              ),
                                            )
                                          : Opacity(
                                              opacity: read ? 0.5 : 1.0,
                                              child: _ChapterThumbnail(
                                                // `url: null` triggers
                                                // the widget's own
                                                // self-watch against the
                                                // repo for THIS
                                                // chapterId only.
                                                url: null,
                                                fallbackUrl: book.cover,
                                                sourceId: book.sourceId,
                                                bookId: book.id,
                                                chapter: ch,
                                              ),
                                            );
                                      return Container(
                                        color: selected
                                            ? AppColors.primary
                                                .withValues(alpha: 0.15)
                                            : Colors.transparent,
                                        child: ListTile(
                                          dense: true,
                                          contentPadding:
                                              const EdgeInsets.symmetric(
                                                  vertical: 4, horizontal: 16),
                                          onTap: _selectMode
                                              ? () => _toggleSelected(ch)
                                              : () => onOpenChapter(i),
                                          onLongPress: _selectMode
                                              ? null
                                              : () => _enterSelectMode(ch),
                                          leading: leading,
                                          title: Opacity(
                                            opacity: read ? 0.5 : 1.0,
                                            child: titleText,
                                          ),
                                          subtitle: ch.date != null
                                              ? Opacity(
                                                  opacity: read ? 0.5 : 1.0,
                                                  child: Text(
                                                    ch.date!,
                                                    style: const TextStyle(
                                                      color: AppColors
                                                          .textTertiary,
                                                      fontSize: 11,
                                                    ),
                                                  ),
                                                )
                                              : null,
                                          // Trailing controls clutter the
                                          // row during multi-select, so
                                          // hide everything there until
                                          // the user exits select mode.
                                          trailing: _selectMode
                                              ? null
                                              : Row(
                                                  mainAxisAlignment:
                                                      MainAxisAlignment.end,
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    if (i == lastChapterIndex)
                                                      const Padding(
                                                        padding:
                                                            EdgeInsets.only(
                                                                right: 4),
                                                        child: Icon(
                                                            Icons.play_circle,
                                                            color: AppColors
                                                                .primary,
                                                            size: 18),
                                                      ),
                                                    _ChapterBookmarkButton(
                                                        book: book,
                                                        chapter: ch),
                                                    _ChapterRowMenu(
                                                        book: book,
                                                        chapter: ch),
                                                  ],
                                                ),
                                        ),
                                      );
                                    },
                                  ),
                          ),
                        ],
                      );
                    },
                  ),
          ),
          // ---- More like this ----
          _RefreshableTab(
            child: _SimilarTab(
              similar: similar,
              loading: similarLoading,
              onOpen: (b) => _openSimilar(context, b),
              hasGenres: book.genres.isNotEmpty,
            ),
          ),
          // ---- Details ----
          _DetailsTab(
            book: book,
            onOpenGenre: (g) => _openGenre(context, g),
          ),
          // ---- Bookmarks ----
          _BookmarksTab(
            book: book,
            onOpenChapter: onOpenChapter,
            onOpenChapterAtPage: widget.onOpenChapterAtPage,
          ),
        ],
      ),
      ),
          ),
          // Bottom contextual action bar — only present while
          // multi-select is active. Sits above the system bottom
          // padding so it doesn't get clipped by gesture insets.
          if (_selectMode)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _MultiSelectActionBar(
                count: _selectedChapterIds.length,
                onDownload: () => _downloadSelected(book),
                onMarkRead: () => _markSelected(book, read: true),
                onMarkUnread: () => _markSelected(book, read: false),
                onClose: _exitSelectMode,
              ),
            ),
        ],
      ),
    );
  }
}

/// Thin progress bar + caption shown under the Start Reading button on
/// the detail screen. Communicates "how far through this series am I"
/// at a glance — read count over total, with the percentage spelled out.
///
/// Capped at 100% in the visual so over-counted progress (e.g. a chapter
/// id collision after a source restructures) doesn't render as a
/// nonsense >100% caption.
class _ReadingProgress extends StatelessWidget {
  const _ReadingProgress({
    required this.readCount,
    required this.totalCount,
  });

  final int readCount;
  final int totalCount;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final clampedRead = readCount.clamp(0, totalCount);
    final fraction = totalCount > 0 ? clampedRead / totalCount : 0.0;
    final percent = (fraction * 100).round();
    final isComplete = clampedRead == totalCount && totalCount > 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: fraction,
            minHeight: 4,
            backgroundColor: AppColors.card,
            valueColor: AlwaysStoppedAnimation<Color>(accent),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: Text(
                '$clampedRead of $totalCount chapters',
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (isComplete)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.check_circle_rounded, size: 12, color: accent),
                  const SizedBox(width: 4),
                  Text(
                    '100%',
                    style: TextStyle(
                      color: accent,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              )
            else
              Text(
                '$percent%',
                style: const TextStyle(
                  color: AppColors.textTertiary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// Thin header strip sitting above the chapter list with a search-toggle
/// icon on the left and a sort-toggle chip on the right.
///
/// Default state shows the chapter count + sort chip. Tapping the search
/// icon swaps the left side for an inline text field that filters the
/// list as the user types.
class _ChapterListHeader extends StatelessWidget {
  const _ChapterListHeader({
    required this.ascending,
    required this.searchExpanded,
    required this.searchController,
    required this.onToggleSort,
    required this.onToggleSearch,
    required this.onSearchChanged,
    required this.filteredCount,
    required this.totalCount,
  });

  final bool ascending;
  final bool searchExpanded;
  final TextEditingController searchController;
  final VoidCallback onToggleSort;
  final VoidCallback onToggleSearch;
  final ValueChanged<String> onSearchChanged;
  final int filteredCount;
  final int totalCount;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      decoration: const BoxDecoration(
        color: AppColors.background,
        border: Border(
          bottom: BorderSide(color: AppColors.card, width: 0.6),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: searchExpanded ? 'Close search' : 'Search chapters',
            icon: Icon(
              searchExpanded ? Icons.close_rounded : Icons.search_rounded,
              size: 20,
              color: AppColors.textSecondary,
            ),
            onPressed: onToggleSearch,
            visualDensity: VisualDensity.compact,
          ),
          if (searchExpanded)
            Expanded(
              child: TextField(
                controller: searchController,
                autofocus: true,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 14,
                ),
                decoration: const InputDecoration(
                  hintText: 'Filter chapters…',
                  hintStyle: TextStyle(
                    color: AppColors.textTertiary,
                    fontSize: 14,
                  ),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(vertical: 8),
                ),
                onChanged: onSearchChanged,
              ),
            )
          else
            Expanded(
              child: Text(
                searchExpanded || filteredCount == totalCount
                    ? '$totalCount chapters'
                    : '$filteredCount of $totalCount',
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          Material(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              onTap: onToggleSort,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      ascending
                          ? Icons.arrow_upward_rounded
                          : Icons.arrow_downward_rounded,
                      size: 14,
                      color: AppColors.textPrimary,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      ascending ? 'Asc' : 'Desc',
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}

class _TabBarDelegate extends SliverPersistentHeaderDelegate {
  _TabBarDelegate(this.tabBar);
  final PreferredSizeWidget tabBar;

  @override
  double get minExtent => tabBar.preferredSize.height;
  @override
  double get maxExtent => tabBar.preferredSize.height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      elevation: 0,
      child: tabBar,
    );
  }

  @override
  bool shouldRebuild(covariant _TabBarDelegate oldDelegate) =>
      tabBar != oldDelegate.tabBar;
}

/// Tab bar that listens to chapter + page bookmark repository streams
/// and refreshes the "Bookmarks (N)" label whenever bookmarks are
/// added or removed elsewhere in the app.
class _BookmarkAwareTabBar extends StatefulWidget implements PreferredSizeWidget {
  const _BookmarkAwareTabBar({
    required this.controller,
    required this.chapterCount,
    required this.sourceId,
    required this.bookId,
    required this.accent,
  });

  final TabController controller;
  final int chapterCount;
  final String sourceId;
  final String bookId;
  final Color accent;

  @override
  Size get preferredSize => const Size.fromHeight(kTextTabBarHeight);

  @override
  State<_BookmarkAwareTabBar> createState() => _BookmarkAwareTabBarState();
}

class _BookmarkAwareTabBarState extends State<_BookmarkAwareTabBar> {
  StreamSubscription<BoxEvent>? _chapterSub;
  StreamSubscription<BoxEvent>? _pageSub;

  @override
  void initState() {
    super.initState();
    _chapterSub = sl<ChapterBookmarksRepository>().watch().listen((_) {
      if (mounted) setState(() {});
    });
    _pageSub = sl<PageBookmarksRepository>().watch().listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _chapterSub?.cancel();
    _pageSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chapterRepo = sl<ChapterBookmarksRepository>();
    final pageRepo = sl<PageBookmarksRepository>();
    final n = chapterRepo
            .getBookmarkedChapterIds(widget.sourceId, widget.bookId)
            .length +
        pageRepo.getAllForBook(widget.sourceId, widget.bookId).length;
    return TabBar(
      controller: widget.controller,
      isScrollable: true,
      tabAlignment: TabAlignment.start,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      labelPadding: const EdgeInsets.symmetric(horizontal: 14),
      labelColor: widget.accent,
      unselectedLabelColor: AppColors.textTertiary,
      indicatorSize: TabBarIndicatorSize.label,
      indicator: UnderlineTabIndicator(
        borderSide: BorderSide(color: widget.accent, width: 2),
        insets: const EdgeInsets.symmetric(horizontal: 2),
      ),
      dividerHeight: 0,
      splashFactory: NoSplash.splashFactory,
      overlayColor: WidgetStateProperty.all(Colors.transparent),
      labelStyle: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.2,
      ),
      unselectedLabelStyle: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.2,
      ),
      tabs: [
        Tab(text: 'Chapters (${widget.chapterCount})'),
        const Tab(text: 'More like this'),
        const Tab(text: 'Details'),
        Tab(text: n == 0 ? 'Bookmarks' : 'Bookmarks ($n)'),
      ],
    );
  }
}

class _SimilarTab extends StatelessWidget {
  const _SimilarTab({
    required this.similar,
    required this.loading,
    required this.onOpen,
    required this.hasGenres,
  });
  final List<BookItem> similar;
  final bool loading;
  final bool hasGenres;
  final void Function(BookItem book) onOpen;

  @override
  Widget build(BuildContext context) {
    if (loading && similar.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 48),
          Center(
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.primary,
              ),
            ),
          ),
        ],
      );
    }
    if (!hasGenres) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 48),
          EmptyView(
            message: 'No genres found for this book — nothing to compare against.',
            icon: Icons.label_outline,
          ),
        ],
      );
    }
    if (similar.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 48),
          EmptyView(message: 'No similar books found.'),
        ],
      );
    }
    return GridView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 24),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: 0.5,
        crossAxisSpacing: 10,
        mainAxisSpacing: 14,
      ),
      itemCount: similar.length,
      itemBuilder: (_, i) => BookCard(
        book: similar[i],
        onTap: () => onOpen(similar[i]),
      ),
    );
  }
}

class _RefreshableTab extends StatelessWidget {
  const _RefreshableTab({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return RefreshIndicator(
      color: scheme.primary,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      onRefresh: () async {
        context.read<DetailBloc>().add(const DetailReloaded());
        // Await one frame so the indicator stays visible briefly; the bloc
        // will emit new state and rebuild the tab when the fetch completes.
        await Future<void>.delayed(const Duration(milliseconds: 350));
      },
      child: child,
    );
  }
}

class _DetailsTab extends StatelessWidget {
  const _DetailsTab({required this.book, required this.onOpenGenre});
  final BookDetail book;
  final void Function(String genre) onOpenGenre;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        if (book.description != null && book.description!.isNotEmpty) ...[
          const _SmallLabel('Description'),
          const SizedBox(height: 6),
          Text(book.description!, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 18),
        ],
        if (book.genres.isNotEmpty) ...[
          const _SmallLabel('Genres'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: book.genres
                .map((g) => ActionChip(
                      label: Text(g),
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      onPressed: () => onOpenGenre(g),
                    ))
                .toList(),
          ),
          const SizedBox(height: 18),
        ],
        if (book.authors.isNotEmpty) ...[
          const _SmallLabel('Author(s)'),
          const SizedBox(height: 4),
          Text(
            book.authors.join(', '),
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 18),
        ],
        const _SmallLabel('Source'),
        const SizedBox(height: 4),
        Text(book.sourceId, style: Theme.of(context).textTheme.bodyMedium),
      ],
    );
  }
}

class _SmallLabel extends StatelessWidget {
  const _SmallLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        color: Theme.of(context).colorScheme.primary,
        fontSize: 11,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.2,
      ),
    );
  }
}

class _BackdropHeader extends StatelessWidget {
  const _BackdropHeader({required this.book});
  final BookDetail book;

  @override
  Widget build(BuildContext context) {
    final cover = book.cover;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (cover != null)
          CachedNetworkImage(
            cacheManager: sozoCacheManagerFor(context),
            imageUrl: cover,
            httpHeaders: book.coverHeaders,
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
          )
        else
          Container(color: AppColors.card),
        // Darken so text + thumbnail edges are legible.
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0x66000000),
                Color(0xAA0A0A0A),
                AppColors.background,
              ],
              stops: [0.0, 0.65, 1.0],
            ),
          ),
        ),
        // Cover thumbnail + title block, side-by-side at the bottom.
        Positioned(
          left: 20,
          right: 20,
          bottom: 20,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              SizedBox(
                height: 170,
                child: AspectRatio(
                  aspectRatio: 2 / 3,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: cover != null
                        ? CachedNetworkImage(
                            cacheManager: sozoCacheManagerFor(context),
                            imageUrl: cover,
                            httpHeaders: book.coverHeaders,
                            fit: BoxFit.cover,
                          )
                        : Container(color: AppColors.card),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        book.title,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.3,
                          height: 1.15,
                          shadows: [Shadow(blurRadius: 6, color: Colors.black87)],
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          _StatusBadge(status: book.status),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              book.sourceId,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});
  final BookStatus status;
  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      BookStatus.ongoing => AppColors.success,
      BookStatus.completed => AppColors.primary,
      BookStatus.hiatus => AppColors.warning,
      BookStatus.cancelled => AppColors.textTertiary,
      BookStatus.unknown => AppColors.textTertiary,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        status.name.toUpperCase(),
        style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.8),
      ),
    );
  }
}

class _SkeletonDetail extends StatelessWidget {
  const _SkeletonDetail({this.placeholder});
  final BookItem? placeholder;

  @override
  Widget build(BuildContext context) {
    final hasCover = placeholder?.cover != null;
    return CustomScrollView(
      physics: const NeverScrollableScrollPhysics(),
      slivers: [
        SliverToBoxAdapter(
          child: SizedBox(
            height: 340,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (hasCover)
                  CachedNetworkImage(
                    cacheManager: sozoCacheManagerFor(context),
                    imageUrl: placeholder!.cover!,
                    httpHeaders: placeholder!.coverHeaders,
                    fit: BoxFit.cover,
                    alignment: Alignment.topCenter,
                  )
                else
                  const _ShimmerBlock(
                    height: double.infinity,
                    radius: 0,
                  ),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color(0x66000000),
                        Color(0xAA0A0A0A),
                        AppColors.background,
                      ],
                      stops: [0.0, 0.65, 1.0],
                    ),
                  ),
                ),
                Positioned(
                  left: 20,
                  right: 20,
                  bottom: 20,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      SizedBox(
                        height: 170,
                        child: AspectRatio(
                          aspectRatio: 2 / 3,
                          child: hasCover
                              ? ClipRRect(
                                  borderRadius: BorderRadius.circular(10),
                                  child: CachedNetworkImage(
                                    cacheManager: sozoCacheManagerFor(context),
                                    imageUrl: placeholder!.cover!,
                                    httpHeaders: placeholder!.coverHeaders,
                                    fit: BoxFit.cover,
                                  ),
                                )
                              : const _ShimmerBlock(
                                  height: double.infinity,
                                  radius: 10,
                                ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      const Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(bottom: 6),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _ShimmerBlock(height: 18, widthFactor: 0.9),
                              SizedBox(height: 8),
                              _ShimmerBlock(height: 18, widthFactor: 0.6),
                              SizedBox(height: 12),
                              _ShimmerBlock(height: 14, widthFactor: 0.4),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 18, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ShimmerBlock(height: 12, widthFactor: 1.0),
                SizedBox(height: 8),
                _ShimmerBlock(height: 12, widthFactor: 0.95),
                SizedBox(height: 8),
                _ShimmerBlock(height: 12, widthFactor: 0.6),
                SizedBox(height: 18),
                // Genre chips
                Row(
                  children: [
                    _ShimmerBlock(width: 64, height: 26, radius: 14),
                    SizedBox(width: 6),
                    _ShimmerBlock(width: 80, height: 26, radius: 14),
                    SizedBox(width: 6),
                    _ShimmerBlock(width: 54, height: 26, radius: 14),
                  ],
                ),
                SizedBox(height: 18),
                _ShimmerBlock(height: 48, radius: 10),
              ],
            ),
          ),
        ),
        // Tab bar shimmer
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
            child: Row(
              children: const [
                _ShimmerBlock(width: 80, height: 14),
                SizedBox(width: 18),
                _ShimmerBlock(width: 100, height: 14),
                SizedBox(width: 18),
                _ShimmerBlock(width: 60, height: 14),
              ],
            ),
          ),
        ),
        const SliverToBoxAdapter(child: Divider(height: 1)),
        SliverList.builder(
          itemCount: 7,
          itemBuilder: (_, _) => const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ShimmerBlock(height: 13, widthFactor: 0.7),
                SizedBox(height: 6),
                _ShimmerBlock(height: 10, widthFactor: 0.3),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Per-chapter overflow menu — replaces the old dedicated download
/// button. Hosts both read/unread toggling and the full download
/// lifecycle (start / pause / resume / retry / cancel / re-download /
/// delete) behind a single horizontal 3-dot trigger to keep the row
/// trailing area uncluttered.
///
/// A small status indicator (spinner / pause / check / error) renders
/// next to the trigger when there's an active or completed download so
/// users still get an at-a-glance read on chapter state without
/// opening the menu.
class _ChapterRowMenu extends StatelessWidget {
  const _ChapterRowMenu({required this.book, required this.chapter});

  final BookDetail book;
  final Chapter chapter;

  Future<void> _startDownload(BuildContext context) async {
    final repo = sl<DownloadsRepository>();
    final providerRepo = sl<ProviderRepository>();
    final dio = sl<Dio>();
    final messenger = ScaffoldMessenger.of(context);

    // Novels: fetch the chapter text directly and store inline. No image
    // CDN gymnastics needed — a single Hive write captures the whole
    // chapter (~50 KB even for very long ones).
    if (book.type == ProviderType.novel) {
      final res =
          await providerRepo.novelContent(book.sourceId, chapter.url);
      res.fold(
        (f) => messenger.showAppSnack(
          SnackBar(content: Text('Download failed: ${f.message}')),
        ),
        (content) async {
          if (content.text.trim().isEmpty) {
            messenger.showAppSnack(
              const SnackBar(content: Text('Chapter is empty — nothing to save.')),
            );
            return;
          }
          await repo.enqueueNovel(
            book: book,
            chapter: chapter,
            text: content.text,
            nextChapterUrl: content.nextUrl,
          );
          messenger.showAppSnack(
            SnackBar(content: Text('Saved ${chapter.title} for offline')),
          );
        },
      );
      return;
    }

    // Manga path — fetch image URLs then stream each one to disk.
    final pagesRes = await providerRepo.pages(book.sourceId, chapter.url);
    pagesRes.fold(
      (f) => messenger.showAppSnack(
        SnackBar(content: Text('Failed to fetch pages: ${f.message}')),
      ),
      (pages) {
        if (pages.isEmpty) {
          messenger.showAppSnack(
            const SnackBar(content: Text('No pages to download')),
          );
          return;
        }
        // Fire-and-forget; the repo emits via watch().
        // ignore: discarded_futures
        repo.enqueue(book, chapter, pages, dio);
        messenger.showAppSnack(
          SnackBar(content: Text('Downloading ${chapter.title}…')),
        );
      },
    );
  }

  Future<void> _delete(BuildContext context) async {
    final repo = sl<DownloadsRepository>();
    await repo.delete(book.sourceId, book.id, chapter.id);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showAppSnack(
      const SnackBar(content: Text('Download deleted')),
    );
  }

  Future<void> _cancel(BuildContext context) async {
    final repo = sl<DownloadsRepository>();
    await repo.cancel(book.sourceId, book.id, chapter.id);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showAppSnack(
      const SnackBar(content: Text('Download cancelled')),
    );
  }

  PopupMenuItem<String> _item(
    String value, {
    required IconData icon,
    required String label,
  }) {
    return PopupMenuItem<String>(
      value: value,
      height: 40,
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppColors.textSecondary),
          const SizedBox(width: 12),
          Text(
            label,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final downloads = sl<DownloadsRepository>();
    final reads = sl<ReadChaptersRepository>();
    final accent = Theme.of(context).colorScheme.primary;

    return StreamBuilder<DownloadEntry>(
      stream: downloads.watch(book.sourceId, book.id, chapter.id),
      builder: (context, snap) {
        return StreamBuilder<BoxEvent>(
          stream: reads.watch(),
          builder: (context, _) {
            final entry =
                snap.data ?? downloads.get(book.sourceId, book.id, chapter.id);
            final isDeleted = entry?.error == '__deleted__';
            final effective = isDeleted ? null : entry;
            final status = effective?.status;
            final isRead =
                reads.isRead(book.sourceId, book.id, chapter.id);

            // Compact at-a-glance indicator next to the menu trigger so
            // the chapter row still communicates download state without
            // requiring the user to open the menu.
            Widget? statusIcon;
            if (status == DownloadStatus.queued ||
                status == DownloadStatus.downloading) {
              final progress = (effective!.total == 0)
                  ? null
                  : effective.completed / effective.total;
              statusIcon = SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  value: progress,
                  color: accent,
                ),
              );
            } else if (status == DownloadStatus.paused) {
              statusIcon = const Icon(Icons.pause_circle_outline,
                  color: AppColors.textSecondary, size: 18);
            } else if (status == DownloadStatus.done) {
              statusIcon = Icon(Icons.check_circle, color: accent, size: 18);
            } else if (status == DownloadStatus.failed) {
              statusIcon = const Icon(Icons.error_outline,
                  color: AppColors.warning, size: 18);
            }

            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (statusIcon != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 2),
                    child: statusIcon,
                  ),
                PopupMenuButton<String>(
                  tooltip: 'More',
                  color: AppColors.card,
                  padding: EdgeInsets.zero,
                  icon: const Icon(
                    Icons.more_horiz,
                    color: AppColors.textTertiary,
                    size: 20,
                  ),
                  onSelected: (value) async {
                    final messenger = ScaffoldMessenger.of(context);
                    switch (value) {
                      case 'mark_read':
                        await reads.mark(
                            book.sourceId, book.id, chapter.id);
                        messenger.showAppSnack(
                          const SnackBar(content: Text('Marked as read')),
                        );
                        break;
                      case 'mark_unread':
                        await reads.unmark(
                            book.sourceId, book.id, chapter.id);
                        messenger.showAppSnack(
                          const SnackBar(content: Text('Marked as unread')),
                        );
                        break;
                      case 'download':
                      case 'retry':
                        await _startDownload(context);
                        break;
                      case 'pause':
                        await downloads.pause(
                            book.sourceId, book.id, chapter.id);
                        break;
                      case 'resume':
                        await downloads.resume(
                            book.sourceId, book.id, chapter.id);
                        break;
                      case 'cancel':
                        await _cancel(context);
                        break;
                      case 'delete':
                        await _delete(context);
                        break;
                      case 'redownload':
                        await _delete(context);
                        if (!context.mounted) return;
                        await _startDownload(context);
                        break;
                    }
                  },
                  itemBuilder: (ctx) {
                    final items = <PopupMenuEntry<String>>[
                      _item(
                        isRead ? 'mark_unread' : 'mark_read',
                        icon: isRead
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        label: isRead ? 'Mark as unread' : 'Mark as read',
                      ),
                      const PopupMenuDivider(height: 1),
                    ];
                    if (status == null) {
                      items.add(_item('download',
                          icon: Icons.download_outlined,
                          label: 'Download'));
                    } else {
                      switch (status) {
                        case DownloadStatus.queued:
                        case DownloadStatus.downloading:
                          items.add(_item('pause',
                              icon: Icons.pause_outlined,
                              label: 'Pause'));
                          items.add(_item('cancel',
                              icon: Icons.close_rounded,
                              label: 'Cancel'));
                          break;
                        // ignore: unreachable_switch_case
                        case DownloadStatus.paused:
                          items.add(_item('resume',
                              icon: Icons.play_arrow_rounded,
                              label: 'Resume'));
                          items.add(_item('cancel',
                              icon: Icons.close_rounded,
                              label: 'Cancel'));
                          break;
                        case DownloadStatus.failed:
                          items.add(_item('retry',
                              icon: Icons.refresh, label: 'Retry'));
                          items.add(_item('cancel',
                              icon: Icons.close_rounded,
                              label: 'Cancel'));
                          break;
                        case DownloadStatus.done:
                          items.add(_item('redownload',
                              icon: Icons.refresh,
                              label: 'Re-download'));
                          items.add(_item('delete',
                              icon: Icons.delete_outline,
                              label: 'Delete download'));
                          break;
                      }
                    }
                    return items;
                  },
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _ShimmerBlock extends StatelessWidget {
  const _ShimmerBlock({
    this.width,
    this.height = 12,
    this.widthFactor,
    this.radius = 4,
  });

  final double? width;
  final double height;
  final double? widthFactor;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final block = Shimmer.fromColors(
      baseColor: AppColors.shimmerBase,
      highlightColor: AppColors.shimmerHighlight,
      child: Container(
        width: width ?? double.infinity,
        height: height,
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(radius),
        ),
      ),
    );
    if (widthFactor != null) {
      return FractionallySizedBox(
        alignment: Alignment.centerLeft,
        widthFactor: widthFactor,
        child: block,
      );
    }
    return block;
  }
}

/// Contextual action bar that slides in at the bottom of the detail
/// screen while the user has chapters selected via long-press. Shows
/// the running selection count + the two batch operations (download,
/// mark read/unread) and an X to bail.
class _MultiSelectActionBar extends StatelessWidget {
  const _MultiSelectActionBar({
    required this.count,
    required this.onDownload,
    required this.onMarkRead,
    required this.onMarkUnread,
    required this.onClose,
  });

  final int count;
  final VoidCallback onDownload;
  final VoidCallback onMarkRead;
  final VoidCallback onMarkUnread;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return SafeArea(
      top: false,
      child: Material(
        color: AppColors.card,
        elevation: 8,
        child: Container(
          decoration: const BoxDecoration(
            border: Border(
              top: BorderSide(
                color: Color(0x33FFFFFF),
                width: 0.5,
              ),
            ),
          ),
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Cancel',
                icon: const Icon(Icons.close_rounded,
                    color: AppColors.textPrimary),
                onPressed: onClose,
              ),
              Expanded(
                child: Text(
                  '$count selected',
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: count == 0 ? null : onDownload,
                icon: Icon(Icons.download_rounded, color: accent, size: 18),
                label: Text(
                  'Download',
                  style: TextStyle(
                    color: accent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'More',
                icon: const Icon(
                  Icons.more_vert_rounded,
                  color: AppColors.textPrimary,
                ),
                onSelected: (v) {
                  switch (v) {
                    case 'read':
                      onMarkRead();
                      break;
                    case 'unread':
                      onMarkUnread();
                      break;
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem<String>(
                    value: 'read',
                    child: Row(
                      children: [
                        Icon(Icons.done_all_rounded, size: 18),
                        SizedBox(width: 12),
                        Text('Mark read'),
                      ],
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'unread',
                    child: Row(
                      children: [
                        Icon(Icons.remove_done_rounded, size: 18),
                        SizedBox(width: 12),
                        Text('Mark unread'),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Result envelope from the library status sheet. Either picks a status
/// (add/update) or signals removal. Null means dismissed without choosing.
class _LibraryAction {
  const _LibraryAction._({this.status, this.remove = false});
  const _LibraryAction.status(LibraryStatus s) : this._(status: s);
  const _LibraryAction.remove() : this._(remove: true);

  final LibraryStatus? status;
  final bool remove;
}

/// Bottom sheet shown when the user taps the bookmark icon. Lets them pick
/// which library shelf the book belongs on (Reading / On hold / Plan to
/// read / Completed) or remove it altogether. The current status (if any)
/// is highlighted with the theme accent.
class _LibraryStatusSheet extends StatelessWidget {
  const _LibraryStatusSheet({this.currentStatus});

  final LibraryStatus? currentStatus;

  static const _options = <(LibraryStatus, String, IconData)>[
    (LibraryStatus.reading, 'Reading', Icons.menu_book_rounded),
    (LibraryStatus.onHold, 'On hold', Icons.pause_circle_outline_rounded),
    (LibraryStatus.planning, 'Plan to read', Icons.event_note_rounded),
    (LibraryStatus.completed, 'Completed', Icons.check_circle_outline_rounded),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isInLibrary = currentStatus != null;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 12),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                isInLibrary ? 'Move to' : 'Save to library',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                  color: Colors.white,
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          for (final opt in _options)
            _StatusRow(
              icon: opt.$3,
              label: opt.$2,
              selected: currentStatus == opt.$1,
              accent: theme.colorScheme.primary,
              onTap: () => Navigator.pop(
                context,
                _LibraryAction.status(opt.$1),
              ),
            ),
          if (isInLibrary) ...[
            Divider(
              color: Colors.white.withValues(alpha: 0.08),
              height: 1,
              indent: 16,
              endIndent: 16,
            ),
            ListTile(
              leading: const Icon(
                Icons.delete_outline_rounded,
                color: Color(0xFFE57373),
              ),
              title: const Text(
                'Remove from library',
                style: TextStyle(color: Color(0xFFE57373)),
              ),
              onTap: () =>
                  Navigator.pop(context, const _LibraryAction.remove()),
            ),
          ],
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.icon,
    required this.label,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: Icon(icon, color: selected ? accent : Colors.white70),
      title: Text(
        label,
        style: TextStyle(
          color: selected ? accent : Colors.white,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
      trailing: selected
          ? Icon(Icons.check_rounded, color: accent, size: 22)
          : null,
    );
  }
}

/// Compact bookmark toggle in the chapter list row trailing slot.
///
/// Watches the chapter bookmarks repo so flipping the bookmark anywhere
/// (here, from the bookmarks tab, or from a future sync push) updates
/// the icon immediately. Tapping toggles the bookmark and shows an
/// Undo snackbar.
class _ChapterBookmarkButton extends StatelessWidget {
  const _ChapterBookmarkButton({required this.book, required this.chapter});

  final BookDetail book;
  final Chapter chapter;

  Future<void> _toggle(BuildContext context, bool isBookmarked) async {
    final repo = sl<ChapterBookmarksRepository>();
    final messenger = ScaffoldMessenger.of(context);
    if (isBookmarked) {
      await repo.remove(book.sourceId, book.id, chapter.id);
      messenger.hideCurrentSnackBar();
      messenger.showAppSnack(
        SnackBar(
          content: const Text('Bookmark removed'),
          duration: const Duration(seconds: 3),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () =>
                repo.add(book.sourceId, book.id, chapter.id),
          ),
        ),
      );
    } else {
      await repo.add(book.sourceId, book.id, chapter.id);
      // Proactively fetch the chapter's first page so a brand-new
      // bookmark for a never-opened chapter still renders a thumbnail
      // in the bookmarks tab. Fire-and-forget; errors are swallowed
      // via debugPrint so a network blip never breaks the bookmark
      // flow.
      _prefetchThumbnail(book, chapter);
      messenger.hideCurrentSnackBar();
      messenger.showAppSnack(
        SnackBar(
          content: Text('Bookmarked ${chapter.title}'),
          duration: const Duration(seconds: 3),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () =>
                repo.remove(book.sourceId, book.id, chapter.id),
          ),
        ),
      );
    }
  }

  void _prefetchThumbnail(BookDetail book, Chapter chapter) {
    // Skip if we already have a cached thumbnail — most chapters
    // bookmarked from the chapter list have been seen at least once,
    // so this short-circuits the network call in the common case.
    final thumbs = sl<ChapterThumbnailsRepository>();
    if (thumbs.get(book.sourceId, book.id, chapter.id) != null) return;
    () async {
      try {
        final r = await sl<ProviderRepository>()
            .pages(book.sourceId, chapter.url);
        r.fold((_) {}, (pages) {
          if (pages.isNotEmpty) {
            thumbs.rememberFirstPage(
              sourceId: book.sourceId,
              bookId: book.id,
              chapterId: chapter.id,
              firstPageUrl: pages.first.url,
            );
          }
        });
      } catch (e) {
        debugPrint('Chapter bookmark thumbnail prefetch failed: $e');
      }
    }();
  }

  @override
  Widget build(BuildContext context) {
    final repo = sl<ChapterBookmarksRepository>();
    return StreamBuilder<BoxEvent>(
      stream: repo.watch(),
      builder: (context, _) {
        final bookmarked =
            repo.isBookmarked(book.sourceId, book.id, chapter.id);
        return IconButton(
          tooltip: bookmarked ? 'Remove bookmark' : 'Bookmark chapter',
          icon: Icon(
            bookmarked ? Icons.bookmark : Icons.bookmark_outline,
            size: 18,
            color: bookmarked ? AppColors.primary : AppColors.textTertiary,
          ),
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(),
          onPressed: () => _toggle(context, bookmarked),
        );
      },
    );
  }
}

/// "Bookmarks" tab body — shows the chapter bookmarks and page
/// bookmarks for this series in two sections. Listens to both repos
/// so the list refreshes whenever the user toggles a bookmark from
/// the chapter row or the reader long-press menu.
class _BookmarksTab extends StatefulWidget {
  const _BookmarksTab({
    required this.book,
    required this.onOpenChapter,
    required this.onOpenChapterAtPage,
  });

  final BookDetail book;
  final void Function(int chapterIndex) onOpenChapter;
  final void Function(int chapterIndex, int pageIndex) onOpenChapterAtPage;

  @override
  State<_BookmarksTab> createState() => _BookmarksTabState();
}

class _BookmarksTabState extends State<_BookmarksTab> {
  StreamSubscription<BoxEvent>? _chapterSub;
  StreamSubscription<BoxEvent>? _pageSub;
  // Thumbnails arrive asynchronously after a chapter bookmark prefetch
  // or after the user reads a chapter — watch the cache so the leading
  // image swaps in without needing the user to scroll away and back.
  StreamSubscription<BoxEvent>? _thumbsSub;

  // Section + group expansion. Default everything to expanded; the user
  // collapses what they don't want to see. Page groups track the
  // *collapsed* chapter ids (inverse) so freshly-bookmarked chapters
  // appear expanded by default without needing to populate the set.
  bool _chaptersExpanded = true;
  bool _pagesExpanded = true;
  final Set<String> _collapsedPageGroups = <String>{};

  @override
  void initState() {
    super.initState();
    _chapterSub = sl<ChapterBookmarksRepository>().watch().listen((_) {
      if (mounted) setState(() {});
    });
    _pageSub = sl<PageBookmarksRepository>().watch().listen((_) {
      if (mounted) setState(() {});
    });
    _thumbsSub = sl<ChapterThumbnailsRepository>().watch().listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _chapterSub?.cancel();
    _pageSub?.cancel();
    _thumbsSub?.cancel();
    super.dispose();
  }

  /// Maps a chapter id back to its index in [book.chapters] so we can
  /// reuse the existing [onOpenChapter] callback. Returns null if the
  /// chapter no longer exists (e.g. source restructure since the
  /// bookmark was added).
  int? _indexForChapter(String chapterId) {
    for (var i = 0; i < widget.book.chapters.length; i++) {
      if (widget.book.chapters[i].id == chapterId) return i;
    }
    return null;
  }

  String _titleForChapter(String chapterId) {
    final i = _indexForChapter(chapterId);
    if (i == null) return chapterId;
    return widget.book.chapters[i].title;
  }

  String _formatDate(DateTime dt) {
    final local = dt.toLocal();
    final y = local.year.toString().padLeft(4, '0');
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $hh:$mm';
  }

  Future<void> _removeChapter(ChapterBookmark b) async {
    final repo = sl<ChapterBookmarksRepository>();
    final messenger = ScaffoldMessenger.of(context);
    await repo.remove(b.sourceId, b.bookId, b.chapterId);
    messenger.hideCurrentSnackBar();
    messenger.showAppSnack(
      SnackBar(
        content: const Text('Bookmark removed'),
        duration: const Duration(seconds: 3),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => repo.add(b.sourceId, b.bookId, b.chapterId,
              note: b.note),
        ),
      ),
    );
  }

  /// Opens an [AlertDialog] with a multiline text field pre-filled with
  /// [initialNote] (if any) and returns the new note string, or `null`
  /// if the user cancelled. An empty string indicates the user wants to
  /// clear the existing note.
  Future<String?> _showNoteDialog({String? initialNote}) async {
    final controller = TextEditingController(text: initialNote ?? '');
    final isEdit = initialNote != null && initialNote.isNotEmpty;
    final result = await showDialog<String?>(
      context: context,
      builder: (dialogCtx) {
        return AlertDialog(
          backgroundColor: AppColors.card,
          title: Text(
            isEdit ? 'Edit note' : 'Add note',
            style: const TextStyle(color: AppColors.textPrimary),
          ),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLines: 4,
            minLines: 2,
            maxLength: 200,
            style: const TextStyle(color: AppColors.textPrimary),
            decoration: const InputDecoration(
              hintText: 'Why is this bookmarked?',
              hintStyle: TextStyle(color: AppColors.textTertiary),
              counterStyle: TextStyle(color: AppColors.textTertiary),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(null),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.of(dialogCtx).pop(controller.text.trim()),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
    // Defer dispose to a post-frame callback so any pending IME / keyboard
    // teardown callbacks can drain before the controller goes away. Without
    // this, dismissing the keyboard right after closing the dialog can race
    // a late IMM callback against the disposed controller.
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    return result;
  }

  Future<void> _editChapterNote(ChapterBookmark b) async {
    final next = await _showNoteDialog(initialNote: b.note);
    if (next == null) return;
    // [add] is idempotent — same key, refreshed row with the new note.
    // Passing an empty string clears the note (stored as null since
    // [ChapterBookmark.toJson] skips empty values via the `if (note !=
    // null)` guard — but we still want an empty string to mean
    // "clear", so normalize here).
    await sl<ChapterBookmarksRepository>().add(
      b.sourceId,
      b.bookId,
      b.chapterId,
      note: next.isEmpty ? null : next,
    );
  }

  Future<void> _editPageNote(PageBookmark b) async {
    final next = await _showNoteDialog(initialNote: b.note);
    if (next == null) return;
    await sl<PageBookmarksRepository>().add(
      sourceId: b.sourceId,
      bookId: b.bookId,
      chapterId: b.chapterId,
      pageIndex: b.pageIndex,
      pageUrl: b.pageUrl,
      note: next.isEmpty ? null : next,
    );
  }

  Future<void> _removePage(PageBookmark b) async {
    final repo = sl<PageBookmarksRepository>();
    final messenger = ScaffoldMessenger.of(context);
    await repo.remove(
      sourceId: b.sourceId,
      bookId: b.bookId,
      chapterId: b.chapterId,
      pageIndex: b.pageIndex,
    );
    messenger.hideCurrentSnackBar();
    messenger.showAppSnack(
      SnackBar(
        content: const Text('Bookmark removed'),
        duration: const Duration(seconds: 3),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => repo.add(
            sourceId: b.sourceId,
            bookId: b.bookId,
            chapterId: b.chapterId,
            pageIndex: b.pageIndex,
            pageUrl: b.pageUrl,
            note: b.note,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final chapterRepo = sl<ChapterBookmarksRepository>();
    final pageRepo = sl<PageBookmarksRepository>();
    final chapterBookmarks =
        chapterRepo.getAllForBook(widget.book.sourceId, widget.book.id);
    final pageBookmarks =
        pageRepo.getAllForBook(widget.book.sourceId, widget.book.id);

    if (chapterBookmarks.isEmpty && pageBookmarks.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 48),
          EmptyView(
            icon: Icons.bookmark_border,
            message:
                'No bookmarks yet. Long-press a chapter or page to save it.',
          ),
        ],
      );
    }

    // Group page bookmarks by chapter id so the user can collapse the
    // bookmarks for a single chapter independently. LinkedHashMap
    // semantics (Dart's default) preserve repo insertion order across
    // the keys — i.e. the first chapter the user bookmarked a page in
    // appears first.
    final pageGroups = <String, List<PageBookmark>>{};
    for (final b in pageBookmarks) {
      (pageGroups[b.chapterId] ??= <PageBookmark>[]).add(b);
    }

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        if (chapterBookmarks.isNotEmpty) ...[
          _BookmarksSectionHeader(
            text: 'Chapters',
            count: chapterBookmarks.length,
            expanded: _chaptersExpanded,
            onTap: () => setState(
                () => _chaptersExpanded = !_chaptersExpanded),
          ),
          if (_chaptersExpanded)
            for (final b in chapterBookmarks)
              ListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(
                    vertical: 4, horizontal: 16),
                leading: _ChapterThumbnail(
                  url: sl<ChapterThumbnailsRepository>().get(
                      b.sourceId, b.bookId, b.chapterId),
                  fallbackUrl: widget.book.cover,
                ),
                title: Text(
                  _titleForChapter(b.chapterId),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppColors.textPrimary),
                ),
                subtitle: _BookmarkSubtitle(
                  primary: _formatDate(b.addedAt),
                  note: b.note,
                ),
                trailing: _BookmarkRowMenu(
                  hasNote: b.note != null && b.note!.isNotEmpty,
                  onEditNote: () => _editChapterNote(b),
                  onRemove: () => _removeChapter(b),
                ),
                onTap: () {
                  final i = _indexForChapter(b.chapterId);
                  if (i != null) widget.onOpenChapter(i);
                },
                onLongPress: () => _editChapterNote(b),
              ),
        ],
        if (pageBookmarks.isNotEmpty) ...[
          _BookmarksSectionHeader(
            text: 'Pages',
            count: pageBookmarks.length,
            expanded: _pagesExpanded,
            onTap: () =>
                setState(() => _pagesExpanded = !_pagesExpanded),
            topPadding: 16,
          ),
          if (_pagesExpanded)
            for (final entry in pageGroups.entries) ...[
              _PageGroupHeader(
                title: _titleForChapter(entry.key),
                count: entry.value.length,
                expanded: !_collapsedPageGroups.contains(entry.key),
                onTap: () => setState(() {
                  if (_collapsedPageGroups.contains(entry.key)) {
                    _collapsedPageGroups.remove(entry.key);
                  } else {
                    _collapsedPageGroups.add(entry.key);
                  }
                }),
              ),
              if (!_collapsedPageGroups.contains(entry.key))
                for (final b in entry.value)
                  ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.fromLTRB(
                        28, 4, 16, 4),
                    leading: _ChapterThumbnail(
                      url: b.pageUrl,
                      fallbackUrl: widget.book.cover,
                    ),
                    title: Text(
                      'Page ${b.pageIndex + 1}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          const TextStyle(color: AppColors.textPrimary),
                    ),
                    subtitle: _BookmarkSubtitle(
                      primary: _formatDate(b.addedAt),
                      note: b.note,
                    ),
                    trailing: _BookmarkRowMenu(
                      hasNote: b.note != null && b.note!.isNotEmpty,
                      onEditNote: () => _editPageNote(b),
                      onRemove: () => _removePage(b),
                    ),
                    onTap: () {
                      final i = _indexForChapter(b.chapterId);
                      if (i != null) {
                        widget.onOpenChapterAtPage(i, b.pageIndex);
                      }
                    },
                    onLongPress: () => _editPageNote(b),
                  ),
            ],
        ],
        const SizedBox(height: 24),
      ],
    );
  }
}

/// Top-level bookmark section header (CHAPTERS / PAGES). Tappable —
/// flips the parent's expanded state — and shows the section's
/// bookmark count + a chevron reflecting open/closed state. Replaces
/// the old plain text label so the user can collapse a long section
/// without scrolling past it.
class _BookmarksSectionHeader extends StatelessWidget {
  const _BookmarksSectionHeader({
    required this.text,
    required this.count,
    required this.expanded,
    required this.onTap,
    this.topPadding = 8,
  });

  final String text;
  final int count;
  final bool expanded;
  final VoidCallback onTap;
  final double topPadding;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: EdgeInsets.fromLTRB(8, topPadding, 8, 0),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: [
              Text(
                text.toUpperCase(),
                style: TextStyle(
                  color: accent,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '($count)',
                style: const TextStyle(
                  color: AppColors.textTertiary,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              Icon(
                expanded ? Icons.expand_less : Icons.expand_more,
                color: AppColors.textTertiary,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Sub-header inside the PAGES section that groups page bookmarks by
/// chapter. Each group is independently collapsible so a chapter with
/// many bookmarked panels doesn't push the rest of the list off-screen.
class _PageGroupHeader extends StatelessWidget {
  const _PageGroupHeader({
    required this.title,
    required this.count,
    required this.expanded,
    required this.onTap,
  });

  final String title;
  final int count;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(
              expanded
                  ? Icons.keyboard_arrow_down
                  : Icons.keyboard_arrow_right,
              color: AppColors.textSecondary,
              size: 20,
            ),
            const SizedBox(width: 2),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '$count',
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Small 48×64 thumbnail rendered to the left of a chapter row in the
/// chapter list and the chapter-bookmarks list. Shows the first page of
/// the chapter when known (cached lazily by [ChapterThumbnailsRepository]
/// as the user reads) and falls back to a neutral placeholder when no
/// thumbnail has been seen yet.
/// Trailing 3-dot menu for a bookmark row. Surfaces Add/Edit note as an
/// explicit option (so the feature is discoverable beyond the long-press
/// gesture) and Remove with a red tint.
class _BookmarkRowMenu extends StatelessWidget {
  const _BookmarkRowMenu({
    required this.hasNote,
    required this.onEditNote,
    required this.onRemove,
  });

  final bool hasNote;
  final VoidCallback onEditNote;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'More',
      icon: const Icon(
        Icons.more_vert_rounded,
        color: AppColors.textSecondary,
        size: 18,
      ),
      padding: EdgeInsets.zero,
      onSelected: (v) {
        switch (v) {
          case 'note':
            onEditNote();
            break;
          case 'remove':
            onRemove();
            break;
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem<String>(
          value: 'note',
          child: Row(
            children: [
              Icon(
                hasNote
                    ? Icons.edit_note_rounded
                    : Icons.note_add_outlined,
                size: 18,
              ),
              const SizedBox(width: 12),
              Text(hasNote ? 'Edit note' : 'Add note'),
            ],
          ),
        ),
        const PopupMenuItem<String>(
          value: 'remove',
          child: Row(
            children: [
              Icon(Icons.delete_outline_rounded,
                  size: 18, color: AppColors.primary),
              SizedBox(width: 12),
              Text(
                'Remove',
                style: TextStyle(color: AppColors.primary),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Lazy-fetched first-page thumbnail. When the chapter has no cached
/// thumbnail AND the caller passes a [chapter] + [sourceId] + [bookId],
/// this widget kicks off a one-shot background fetch on first mount —
/// throttled globally to 3 in-flight requests so scrolling a long
/// chapter list doesn't spam the source.
///
/// While the fetch is in flight (or if it ultimately fails), the row
/// renders [fallbackUrl] (the series cover). Once the fetch lands, the
/// cached URL replaces it on the next StreamBuilder tick.
class _ChapterThumbnail extends StatefulWidget {
  const _ChapterThumbnail({
    required this.url,
    this.fallbackUrl,
    this.sourceId,
    this.bookId,
    this.chapter,
  });

  /// Primary URL — the cached first-page thumbnail. When this is null
  /// (chapter never opened, never bookmarked) we drop to [fallbackUrl]
  /// while a background fetch fills in the cache.
  final String? url;

  /// Series cover URL — used while the chapter's first page is being
  /// fetched (or if the fetch ultimately fails). Beats an empty grey
  /// placeholder.
  final String? fallbackUrl;

  /// When set together with [bookId] and [chapter], the widget lazily
  /// fetches the chapter's first page on first mount if no cached
  /// thumbnail exists yet. Pass null at call sites that should NOT
  /// trigger a fetch (e.g. the Bookmarks tab, where the bookmark add
  /// flow already triggered a proactive fetch).
  final String? sourceId;
  final String? bookId;
  final Chapter? chapter;

  static const double _w = 48;
  static const double _h = 64;

  @override
  State<_ChapterThumbnail> createState() => _ChapterThumbnailState();
}

class _ChapterThumbnailState extends State<_ChapterThumbnail> {
  /// Locally-cached thumbnail URL for this row. Seeded from
  /// [widget.url] (when the caller passed one) or from the repo on
  /// first mount, and updated when the repo's watch stream fires for
  /// OUR chapterId.
  String? _cachedUrl;

  /// Subscription to the repo's watch stream. Only set when the widget
  /// owns its own (sourceId, bookId, chapter) — call sites that pass a
  /// pre-resolved URL skip the subscription entirely (the parent
  /// rebuilds them on its own).
  StreamSubscription<BoxEvent>? _watchSub;

  String? get _ownKey {
    final s = widget.sourceId, b = widget.bookId, c = widget.chapter?.id;
    if (s == null || b == null || c == null) return null;
    return '$s::$b::$c';
  }

  @override
  void initState() {
    super.initState();
    _cachedUrl = widget.url;
    _seedFromRepo();
    _subscribeIfOwned();
    _maybeScheduleFetch();
  }

  @override
  void didUpdateWidget(covariant _ChapterThumbnail old) {
    super.didUpdateWidget(old);
    final keyChanged = old.sourceId != widget.sourceId ||
        old.bookId != widget.bookId ||
        old.chapter?.id != widget.chapter?.id;
    if (keyChanged) {
      // Recycled row → resubscribe + reseed for the new chapter.
      _watchSub?.cancel();
      _cachedUrl = widget.url;
      _seedFromRepo();
      _subscribeIfOwned();
      _maybeScheduleFetch();
    } else if (widget.url != null && widget.url != _cachedUrl) {
      // Parent overrode the URL → use it.
      setState(() => _cachedUrl = widget.url);
    }
  }

  @override
  void dispose() {
    _watchSub?.cancel();
    super.dispose();
  }

  void _seedFromRepo() {
    if (_cachedUrl != null && _cachedUrl!.isNotEmpty) return;
    final s = widget.sourceId, b = widget.bookId, c = widget.chapter?.id;
    if (s == null || b == null || c == null) return;
    final stored = sl<ChapterThumbnailsRepository>().get(s, b, c);
    if (stored != null && stored.isNotEmpty) _cachedUrl = stored;
  }

  void _subscribeIfOwned() {
    final myKey = _ownKey;
    if (myKey == null) return;
    _watchSub = sl<ChapterThumbnailsRepository>().watch().listen((event) {
      // The Hive watch stream fires for every write to the box; filter
      // to the chapterId this row cares about so unrelated writes don't
      // trigger a setState.
      if (event.key != myKey) return;
      if (!mounted) return;
      final fresh = sl<ChapterThumbnailsRepository>().get(
        widget.sourceId!,
        widget.bookId!,
        widget.chapter!.id,
      );
      if (fresh == _cachedUrl) return;
      setState(() => _cachedUrl = fresh);
    });
  }

  void _maybeScheduleFetch() {
    if (_cachedUrl != null && _cachedUrl!.isNotEmpty) return;
    final src = widget.sourceId;
    final book = widget.bookId;
    final ch = widget.chapter;
    if (src == null || book == null || ch == null) return;
    _ChapterThumbnailFetchQueue.instance.enqueue(
      sourceId: src,
      bookId: book,
      chapter: ch,
    );
  }

  @override
  Widget build(BuildContext context) {
    final String? src = (_cachedUrl != null && _cachedUrl!.isNotEmpty)
        ? _cachedUrl
        : (widget.fallbackUrl != null && widget.fallbackUrl!.isNotEmpty
            ? widget.fallbackUrl
            : null);
    return SizedBox(
      width: _ChapterThumbnail._w,
      height: _ChapterThumbnail._h,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: src != null
            ? CachedNetworkImage(
                cacheManager: sozoCacheManagerFor(context),
                imageUrl: src,
                fit: BoxFit.cover,
                placeholder: (_, _) => Container(color: AppColors.card),
                errorWidget: (_, _, _) => _placeholder(Icons.broken_image),
              )
            : _placeholder(Icons.image_outlined),
      ),
    );
  }

  Widget _placeholder(IconData icon) {
    return Container(
      color: AppColors.card,
      alignment: Alignment.center,
      child: Opacity(
        opacity: 0.5,
        child: Icon(icon, size: 18, color: AppColors.textTertiary),
      ),
    );
  }
}

/// Global LIFO queue of chapter-first-page prefetches, throttled to
/// [_kMaxConcurrent] in-flight HTTP calls so a fast scroll through a
/// 1000-chapter series doesn't pile up requests.
///
/// LIFO order ("freshest visible row wins") deliberately drops older
/// requests for chapters the user has already scrolled past — they no
/// longer need a thumbnail urgently. The deduplication set guards
/// against double-fetching the same chapter when the row briefly
/// recycles in and out of view.
class _ChapterThumbnailFetchQueue {
  _ChapterThumbnailFetchQueue._();
  static final _ChapterThumbnailFetchQueue instance =
      _ChapterThumbnailFetchQueue._();

  static const int _kMaxConcurrent = 3;

  final List<_FetchTask> _pending = <_FetchTask>[];
  final Set<String> _inFlightOrQueued = <String>{};
  int _inFlight = 0;

  String _key(String sourceId, String bookId, String chapterId) =>
      '$sourceId::$bookId::$chapterId';

  void enqueue({
    required String sourceId,
    required String bookId,
    required Chapter chapter,
  }) {
    final key = _key(sourceId, bookId, chapter.id);
    if (_inFlightOrQueued.contains(key)) return;
    // Skip if a thumbnail already landed between the call site's check
    // and ours (e.g. the user briefly visited the reader for this
    // chapter while the row was off-screen).
    final cached = sl<ChapterThumbnailsRepository>()
        .get(sourceId, bookId, chapter.id);
    if (cached != null && cached.isNotEmpty) return;
    _inFlightOrQueued.add(key);
    _pending.add(_FetchTask(
      key: key,
      sourceId: sourceId,
      bookId: bookId,
      chapter: chapter,
    ));
    _drain();
  }

  void _drain() {
    while (_inFlight < _kMaxConcurrent && _pending.isNotEmpty) {
      // LIFO — newest enqueued wins, matching what the user is
      // currently looking at after a scroll burst.
      final task = _pending.removeLast();
      _inFlight++;
      // ignore: discarded_futures
      _runOne(task);
    }
  }

  Future<void> _runOne(_FetchTask task) async {
    try {
      final r = await sl<ProviderRepository>()
          .pages(task.sourceId, task.chapter.url);
      r.fold((_) {}, (pages) {
        if (pages.isEmpty) return;
        // ignore: discarded_futures
        sl<ChapterThumbnailsRepository>().rememberFirstPage(
          sourceId: task.sourceId,
          bookId: task.bookId,
          chapterId: task.chapter.id,
          firstPageUrl: pages.first.url,
        );
      });
    } catch (_) {
      // Best-effort. A failed fetch just means the row keeps showing
      // the cover fallback until the user opens the chapter (which
      // writes the thumbnail via the reader's hook).
    } finally {
      _inFlightOrQueued.remove(task.key);
      _inFlight--;
      _drain();
    }
  }
}

class _FetchTask {
  _FetchTask({
    required this.key,
    required this.sourceId,
    required this.bookId,
    required this.chapter,
  });
  final String key;
  final String sourceId;
  final String bookId;
  final Chapter chapter;
}

/// Subtitle slot for a bookmark row — shows the existing primary text
/// (date / page index) on the first line and, when the user has attached
/// a note, the note in italic on a second line. Truncates the note at
/// two lines so a long entry never blows the row height.
class _BookmarkSubtitle extends StatelessWidget {
  const _BookmarkSubtitle({required this.primary, this.note});

  final String primary;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final hasNote = note != null && note!.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          primary,
          style: const TextStyle(
            color: AppColors.textTertiary,
            fontSize: 11,
          ),
        ),
        if (hasNote)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              note!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textTertiary,
                fontSize: 11,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
      ],
    );
  }
}
