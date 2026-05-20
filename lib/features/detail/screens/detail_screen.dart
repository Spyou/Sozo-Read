import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shimmer/shimmer.dart';

import 'package:dio/dio.dart';

import '../../../core/di/injection.dart';
import '../../../core/models/book_detail.dart';
import '../../../core/models/book_item.dart';
import '../../../core/models/chapter.dart';
import '../../../core/models/provider_info.dart';
import '../../../core/repository/book_detail_cache.dart';
import '../../../core/repository/downloads_repository.dart';
import '../../../core/repository/library_repository.dart';
import '../../../core/repository/provider_repository.dart';
import '../../../core/repository/read_chapters_repository.dart';
import '../../../core/state/auth_service.dart';
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
      )..add(DetailLoaded(
          sourceId: sourceId,
          url: url,
          // Threaded through so the bloc can do a cache lookup without
          // waiting for the network — see DetailBloc._fetch.
          bookId: placeholder?.id,
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
      ScaffoldMessenger.of(context).showSnackBar(
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

  void _openReader(BuildContext context, BookDetail book, int chapterIndex) {
    final isManga = book.type.name != 'novel';
    context.pushNamed(
      isManga ? 'manga-reader' : 'novel-reader',
      pathParameters: {'sourceId': book.sourceId, 'bookId': book.id},
      extra: {
        'book': book,
        'chapterIndex': chapterIndex,
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: BlocBuilder<DetailBloc, DetailState>(
        builder: (context, state) {
          if (state.status == DetailStatus.loading && state.book == null) {
            return _SkeletonDetail(placeholder: placeholder);
          }
          if (state.status == DetailStatus.error && state.book == null) {
            return ErrorView(
              message: state.error ?? 'Failed to load',
              onRetry: () => context.read<DetailBloc>().add(const DetailReloaded()),
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
          );
        },
      ),
    );
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

  @override
  State<_DetailBody> createState() => _DetailBodyState();
}

class _DetailBodyState extends State<_DetailBody> with SingleTickerProviderStateMixin {
  late final TabController _tabController = TabController(length: 3, vsync: this);

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
  List<({int originalIndex, Chapter chapter})> _buildChapterDisplay(
    BookDetail book,
    bool ascending,
  ) {
    final indexed = List.generate(
      book.chapters.length,
      (i) => (originalIndex: i, chapter: book.chapters[i]),
    );
    // Source returns chapters newest-first. Ascending = oldest-first, so
    // we reverse the list. Descending keeps the source order.
    final ordered =
        ascending ? indexed.reversed.toList() : indexed;
    final q = _chapterSearchQuery.trim().toLowerCase();
    if (q.isEmpty) return ordered;
    return ordered.where((e) {
      final title = e.chapter.title.toLowerCase();
      if (title.contains(q)) return true;
      // Number-only match as a fallback (titles vary widely between
      // sources; some don't include the chapter number at all).
      final num = e.chapter.number;
      if (num != null && num.toString().contains(q)) return true;
      return false;
    }).toList();
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

    return NotificationListener<ScrollNotification>(
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
              ],
            ),
          ),
        ),
        SliverPersistentHeader(
          pinned: true,
          delegate: _TabBarDelegate(
            TabBar(
              controller: _tabController,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              labelPadding: const EdgeInsets.symmetric(horizontal: 14),
              labelColor: Theme.of(context).colorScheme.primary,
              unselectedLabelColor: AppColors.textTertiary,
              indicatorSize: TabBarIndicatorSize.label,
              indicator: UnderlineTabIndicator(
                borderSide: BorderSide(
                  color: Theme.of(context).colorScheme.primary,
                  width: 2,
                ),
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
                Tab(text: 'Chapters (${book.chapters.length})'),
                const Tab(text: 'More like this'),
                const Tab(text: 'Details'),
              ],
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
                                      return ListTile(
                                        dense: true,
                                        onTap: () => onOpenChapter(i),
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
                                                    color:
                                                        AppColors.textTertiary,
                                                    fontSize: 11,
                                                  ),
                                                ),
                                              )
                                            : null,
                                        trailing: SizedBox(
                                          width: 64,
                                          child: Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.end,
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              if (i == lastChapterIndex)
                                                const Padding(
                                                  padding: EdgeInsets.only(
                                                      right: 4),
                                                  child: Icon(
                                                      Icons.play_circle,
                                                      color:
                                                          AppColors.primary,
                                                      size: 20),
                                                ),
                                              _ChapterDownloadButton(
                                                  book: book, chapter: ch),
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
        ],
      ),
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
  final TabBar tabBar;

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

class _ChapterDownloadButton extends StatelessWidget {
  const _ChapterDownloadButton({required this.book, required this.chapter});

  final BookDetail book;
  final Chapter chapter;

  Future<void> _start(BuildContext context) async {
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
        (f) => messenger.showSnackBar(
          SnackBar(content: Text('Download failed: ${f.message}')),
        ),
        (content) async {
          if (content.text.trim().isEmpty) {
            messenger.showSnackBar(
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
          messenger.showSnackBar(
            SnackBar(content: Text('Saved ${chapter.title} for offline')),
          );
        },
      );
      return;
    }

    // Manga path — fetch image URLs then stream each one to disk.
    final pagesRes = await providerRepo.pages(book.sourceId, chapter.url);
    pagesRes.fold(
      (f) => messenger.showSnackBar(
        SnackBar(content: Text('Failed to fetch pages: ${f.message}')),
      ),
      (pages) {
        if (pages.isEmpty) {
          messenger.showSnackBar(
            const SnackBar(content: Text('No pages to download')),
          );
          return;
        }
        // Fire-and-forget; the repo emits via watch().
        // ignore: discarded_futures
        repo.enqueue(book, chapter, pages, dio);
        messenger.showSnackBar(
          SnackBar(content: Text('Downloading ${chapter.title}…')),
        );
      },
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final repo = sl<DownloadsRepository>();
    await repo.delete(book.sourceId, book.id, chapter.id);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Download deleted')),
    );
  }

  Future<void> _cancel(BuildContext context) async {
    final repo = sl<DownloadsRepository>();
    await repo.cancel(book.sourceId, book.id, chapter.id);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Download cancelled')),
    );
  }

  Future<void> _doneMenu(BuildContext context) async {
    final accent = Theme.of(context).colorScheme.primary;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.delete_outline, color: accent),
              title: const Text('Delete download'),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
            ListTile(
              leading: Icon(Icons.refresh, color: accent),
              title: const Text('Re-download'),
              onTap: () => Navigator.pop(ctx, 'redownload'),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    if (action == 'delete') {
      await _confirmDelete(context);
    } else if (action == 'redownload') {
      await _confirmDelete(context);
      if (!context.mounted) return;
      await _start(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final repo = sl<DownloadsRepository>();
    final accent = Theme.of(context).colorScheme.primary;

    return StreamBuilder<DownloadEntry>(
      stream: repo.watch(book.sourceId, book.id, chapter.id),
      builder: (context, snap) {
        final entry = snap.data ?? repo.get(book.sourceId, book.id, chapter.id);
        final isDeleted = entry?.error == '__deleted__';
        final effective = isDeleted ? null : entry;

        if (effective == null) {
          return IconButton(
            tooltip: 'Download',
            icon: const Icon(Icons.download_outlined,
                color: AppColors.textTertiary, size: 20),
            visualDensity: VisualDensity.compact,
            onPressed: () => _start(context),
          );
        }
        switch (effective.status) {
          case DownloadStatus.queued:
          case DownloadStatus.downloading:
            final progress = effective.total == 0
                ? null
                : effective.completed / effective.total;
            return GestureDetector(
              onLongPress: () => _cancel(context),
              onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    'Downloading… ${effective.completed}/${effective.total}',
                  ),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    value: progress,
                    color: accent,
                  ),
                ),
              ),
            );
          case DownloadStatus.done:
            return GestureDetector(
              onLongPress: () => _doneMenu(context),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Icon(Icons.check_circle, color: accent, size: 20),
              ),
            );
          case DownloadStatus.failed:
            return IconButton(
              tooltip: 'Retry download',
              icon: const Icon(Icons.error_outline,
                  color: AppColors.warning, size: 20),
              visualDensity: VisualDensity.compact,
              onPressed: () => _start(context),
            );
        }
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
