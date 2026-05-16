import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/di/injection.dart';
import '../../../core/models/book_detail.dart';
import '../../../core/models/book_item.dart';
import '../../../core/models/chapter.dart';
import '../../../core/repository/library_repository.dart';
import '../../../core/repository/provider_repository.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/book_card.dart';
import '../../../core/widgets/state_views.dart';
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
      )..add(DetailLoaded(sourceId: sourceId, url: url)),
      child: _DetailView(placeholder: placeholder),
    );
  }
}

class _DetailView extends StatelessWidget {
  const _DetailView({this.placeholder});
  final BookItem? placeholder;

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
            similar: state.similar,
            similarLoading: state.similarStatus == SimilarStatus.loading,
            onToggleLibrary: () => context.read<DetailBloc>().add(const DetailLibraryToggled()),
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
    required this.similar,
    required this.similarLoading,
    required this.onToggleLibrary,
    required this.onOpenChapter,
  });

  final BookDetail book;
  final bool inLibrary;
  final int lastChapterIndex;
  final List<BookItem> similar;
  final bool similarLoading;
  final VoidCallback onToggleLibrary;
  final void Function(int chapterIndex) onOpenChapter;

  @override
  State<_DetailBody> createState() => _DetailBodyState();
}

class _DetailBodyState extends State<_DetailBody> with SingleTickerProviderStateMixin {
  late final TabController _tabController = TabController(length: 3, vsync: this);

  static const double _expandedHeight = 340;
  // Show the app-bar title once the user has scrolled past the cover.
  bool _showAppBarTitle = false;

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
                      lastChapterIndex > 0 && lastChapterIndex < book.chapters.length
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
          ListView.separated(
            padding: EdgeInsets.zero,
            itemCount: book.chapters.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final Chapter ch = book.chapters[i];
              final read = i < lastChapterIndex;
              return ListTile(
                dense: true,
                onTap: () => onOpenChapter(i),
                title: Text(
                  ch.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: read ? AppColors.textTertiary : AppColors.textPrimary,
                    fontWeight:
                        i == lastChapterIndex ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
                subtitle: ch.date != null
                    ? Text(ch.date!,
                        style: const TextStyle(color: AppColors.textTertiary, fontSize: 11))
                    : null,
                trailing: i == lastChapterIndex
                    ? const Icon(Icons.play_circle, color: AppColors.primary, size: 20)
                    : null,
              );
            },
          ),
          // ---- More like this ----
          _SimilarTab(
            similar: similar,
            loading: similarLoading,
            onOpen: (b) => _openSimilar(context, b),
            hasGenres: book.genres.isNotEmpty,
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
      return const Center(
        child: Padding(
          padding: EdgeInsets.only(top: 32),
          child: SizedBox(
            width: 24, height: 24,
            child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
          ),
        ),
      );
    }
    if (!hasGenres) {
      return const EmptyView(
        message: 'No genres found for this book — nothing to compare against.',
        icon: Icons.label_outline,
      );
    }
    if (similar.isEmpty) {
      return const EmptyView(message: 'No similar books found.');
    }
    return GridView.builder(
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
    return Column(
      children: [
        SizedBox(
          height: 340,
          child: placeholder?.cover != null
              ? Stack(
                  fit: StackFit.expand,
                  children: [
                    CachedNetworkImage(
                      imageUrl: placeholder!.cover!,
                      httpHeaders: placeholder!.coverHeaders,
                      fit: BoxFit.cover,
                    ),
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0x66000000), AppColors.background],
                          stops: [0.5, 1.0],
                        ),
                      ),
                    ),
                  ],
                )
              : Container(color: AppColors.card),
        ),
        const Expanded(child: LoadingView()),
      ],
    );
  }
}
