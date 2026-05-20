import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hive/hive.dart';

import '../../../core/di/injection.dart';
import '../../../core/repository/book_detail_cache.dart';
import '../../../core/repository/chapter_bookmarks_repository.dart';
import '../../../core/repository/chapter_thumbnails_repository.dart';
import '../../../core/repository/library_repository.dart';
import '../../../core/repository/page_bookmarks_repository.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/state_views.dart';

/// Global Bookmarks screen — lists every chapter and page bookmark the
/// user has saved, across all series, interleaved by recency. The user
/// can filter to a single series via the chip row at the top.
///
/// Subscribes to both bookmark repos so removals reflect immediately
/// without a manual refresh.
class BookmarksScreen extends StatefulWidget {
  const BookmarksScreen({super.key});

  @override
  State<BookmarksScreen> createState() => _BookmarksScreenState();
}

/// Sentinel used by the filter row to represent "show everything".
const String _allFilter = '__all__';

class _BookmarksScreenState extends State<BookmarksScreen> {
  StreamSubscription<BoxEvent>? _chapterSub;
  StreamSubscription<BoxEvent>? _pageSub;

  /// `sourceId::bookId` of the currently selected series filter, or
  /// [_allFilter] when no filter is applied.
  String _selectedFilter = _allFilter;

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

  /// Pulls the human-readable title for a (sourceId, bookId) pair —
  /// preferring the cached `BookDetail`, falling back to the library
  /// entry, and finally to the composite key when neither is available.
  String _titleForBook(String sourceId, String bookId) {
    final cached = sl<BookDetailCache>().get(sourceId, bookId);
    if (cached != null && cached.title.isNotEmpty) return cached.title;
    final lib = sl<LibraryRepository>().get(sourceId, bookId);
    if (lib != null && lib.book.title.isNotEmpty) return lib.book.title;
    return '$sourceId::$bookId';
  }

  /// Looks up the chapter title from the cached [BookDetail] for this
  /// series. Returns the chapter id when no detail is cached (which
  /// happens when the user bookmarks from a series they haven't opened
  /// the detail screen of on this device).
  String _chapterTitle(String sourceId, String bookId, String chapterId) {
    final detail = sl<BookDetailCache>().get(sourceId, bookId);
    if (detail == null) return chapterId;
    for (final c in detail.chapters) {
      if (c.id == chapterId) return c.title;
    }
    return chapterId;
  }

  /// Short date formatter matching the one in detail_screen's bookmark
  /// tab. Inlined here so this screen has no dependency on detail.
  String _formatDate(DateTime dt) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final local = dt.toLocal();
    return '${months[local.month - 1]} ${local.day}';
  }

  Future<void> _removeChapter(ChapterBookmark b) async {
    final repo = sl<ChapterBookmarksRepository>();
    final messenger = ScaffoldMessenger.of(context);
    await repo.remove(b.sourceId, b.bookId, b.chapterId);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: const Text('Bookmark removed'),
        duration: const Duration(seconds: 3),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () =>
              repo.add(b.sourceId, b.bookId, b.chapterId, note: b.note),
        ),
      ),
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
    messenger.showSnackBar(
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

  void _openDetail(String sourceId, String bookId) {
    context.pushNamed(
      'detail',
      pathParameters: {'sourceId': sourceId, 'bookId': bookId},
    );
  }

  @override
  Widget build(BuildContext context) {
    final chapterBookmarks = sl<ChapterBookmarksRepository>().getAll();
    final pageBookmarks = sl<PageBookmarksRepository>().getAll();

    // Build the unique (sourceId, bookId) set across both kinds so the
    // chip row exposes every series the user has at least one bookmark
    // in, regardless of which kind it is.
    final seriesKeys = <String>{
      for (final b in chapterBookmarks) '${b.sourceId}::${b.bookId}',
      for (final b in pageBookmarks) '${b.sourceId}::${b.bookId}',
    };

    // Apply the active filter (if any) to both lists before merging.
    final filteredChapters = _selectedFilter == _allFilter
        ? chapterBookmarks
        : chapterBookmarks
            .where(
              (b) => '${b.sourceId}::${b.bookId}' == _selectedFilter,
            )
            .toList();
    final filteredPages = _selectedFilter == _allFilter
        ? pageBookmarks
        : pageBookmarks
            .where(
              (b) => '${b.sourceId}::${b.bookId}' == _selectedFilter,
            )
            .toList();

    // Merge the two lists into a single timeline ordered by addedAt
    // descending. Wrapping each entry in an `_Item` lets the merged
    // list be a single ListView.builder.
    final merged = <_Item>[
      for (final b in filteredChapters) _Item.chapter(b),
      for (final b in filteredPages) _Item.page(b),
    ]..sort((a, b) => b.addedAt.compareTo(a.addedAt));

    final hasAnyBookmarks =
        chapterBookmarks.isNotEmpty || pageBookmarks.isNotEmpty;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('Bookmarks')),
      body: !hasAnyBookmarks
          ? const EmptyView(
              icon: Icons.bookmark_border,
              message: 'No bookmarks yet.\n'
                  'Long-press a chapter or page to save it.',
            )
          : Column(
              children: [
                _FilterChipsRow(
                  seriesKeys: seriesKeys.toList()..sort(),
                  selected: _selectedFilter,
                  titleFor: _titleForBook,
                  onSelected: (key) => setState(() => _selectedFilter = key),
                ),
                const Divider(height: 1, color: AppColors.divider),
                Expanded(
                  child: merged.isEmpty
                      ? const EmptyView(
                          icon: Icons.filter_alt_outlined,
                          message: 'No bookmarks for this series.',
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          itemCount: merged.length,
                          itemBuilder: (context, i) {
                            final item = merged[i];
                            return item.when(
                              chapter: (b) => _ChapterRow(
                                bookmark: b,
                                title: _chapterTitle(
                                    b.sourceId, b.bookId, b.chapterId),
                                seriesTitle:
                                    _titleForBook(b.sourceId, b.bookId),
                                dateLabel: _formatDate(b.addedAt),
                                onTap: () =>
                                    _openDetail(b.sourceId, b.bookId),
                                onRemove: () => _removeChapter(b),
                              ),
                              page: (b) => _PageRow(
                                bookmark: b,
                                chapterTitle: _chapterTitle(
                                    b.sourceId, b.bookId, b.chapterId),
                                seriesTitle:
                                    _titleForBook(b.sourceId, b.bookId),
                                dateLabel: _formatDate(b.addedAt),
                                onTap: () =>
                                    _openDetail(b.sourceId, b.bookId),
                                onRemove: () => _removePage(b),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}

/// Tagged union so the merged list can carry chapter + page bookmarks
/// without the renderer having to type-switch on the raw class.
class _Item {
  _Item.chapter(ChapterBookmark this.chapter)
      : page = null,
        addedAt = chapter.addedAt;
  _Item.page(PageBookmark this.page)
      : chapter = null,
        addedAt = page.addedAt;

  final ChapterBookmark? chapter;
  final PageBookmark? page;
  final DateTime addedAt;

  T when<T>({
    required T Function(ChapterBookmark b) chapter,
    required T Function(PageBookmark b) page,
  }) {
    final c = this.chapter;
    if (c != null) return chapter(c);
    return page(this.page!);
  }
}

class _FilterChipsRow extends StatelessWidget {
  const _FilterChipsRow({
    required this.seriesKeys,
    required this.selected,
    required this.titleFor,
    required this.onSelected,
  });

  final List<String> seriesKeys;
  final String selected;
  final String Function(String sourceId, String bookId) titleFor;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            _Chip(
              label: 'All',
              selected: selected == _allFilter,
              onTap: () => onSelected(_allFilter),
            ),
            for (final key in seriesKeys)
              Builder(builder: (context) {
                final parts = key.split('::');
                // Defensive: skip malformed keys rather than crash.
                if (parts.length < 2) return const SizedBox.shrink();
                final sourceId = parts[0];
                final bookId = parts.sublist(1).join('::');
                return _Chip(
                  label: titleFor(sourceId, bookId),
                  selected: selected == key,
                  onTap: () => onSelected(key),
                );
              }),
          ],
        ),
      ),
    );
  }
}

/// Visual chip — mirrors the `_SourceChip` pattern from search_screen
/// (a `ChoiceChip` wrapped in horizontal padding).
class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        selected: selected,
        onSelected: (_) => onTap(),
      ),
    );
  }
}

class _ChapterRow extends StatelessWidget {
  const _ChapterRow({
    required this.bookmark,
    required this.title,
    required this.seriesTitle,
    required this.dateLabel,
    required this.onTap,
    required this.onRemove,
  });

  final ChapterBookmark bookmark;
  final String title;
  final String seriesTitle;
  final String dateLabel;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final thumbUrl = sl<ChapterThumbnailsRepository>()
        .get(bookmark.sourceId, bookmark.bookId, bookmark.chapterId);
    final cover =
        sl<BookDetailCache>().get(bookmark.sourceId, bookmark.bookId)?.cover;
    return ListTile(
      dense: true,
      leading: _Thumb(url: thumbUrl, fallbackUrl: cover),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: AppColors.textPrimary),
      ),
      subtitle: Text(
        '$seriesTitle  ·  $dateLabel',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: AppColors.textTertiary,
          fontSize: 11,
        ),
      ),
      trailing: IconButton(
        tooltip: 'Remove bookmark',
        icon: const Icon(
          Icons.close,
          color: AppColors.textSecondary,
          size: 18,
        ),
        visualDensity: VisualDensity.compact,
        onPressed: onRemove,
      ),
      onTap: onTap,
    );
  }
}

class _PageRow extends StatelessWidget {
  const _PageRow({
    required this.bookmark,
    required this.chapterTitle,
    required this.seriesTitle,
    required this.dateLabel,
    required this.onTap,
    required this.onRemove,
  });

  final PageBookmark bookmark;
  final String chapterTitle;
  final String seriesTitle;
  final String dateLabel;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final cover =
        sl<BookDetailCache>().get(bookmark.sourceId, bookmark.bookId)?.cover;
    return ListTile(
      dense: true,
      leading: _Thumb(url: bookmark.pageUrl, fallbackUrl: cover),
      title: Text(
        'Page ${bookmark.pageIndex + 1} of $chapterTitle',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: AppColors.textPrimary),
      ),
      subtitle: Text(
        '$seriesTitle  ·  $dateLabel',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: AppColors.textTertiary,
          fontSize: 11,
        ),
      ),
      trailing: IconButton(
        tooltip: 'Remove bookmark',
        icon: const Icon(
          Icons.close,
          color: AppColors.textSecondary,
          size: 18,
        ),
        visualDensity: VisualDensity.compact,
        onPressed: onRemove,
      ),
      onTap: onTap,
    );
  }
}

/// 48x64 thumbnail with a uniform placeholder so both row variants
/// align visually. Falls back to [fallbackUrl] (the series cover) when
/// the primary [url] is missing — so a row never renders as an empty
/// grey card just because the user hasn't opened that chapter yet.
class _Thumb extends StatelessWidget {
  const _Thumb({required this.url, this.fallbackUrl});
  final String? url;
  final String? fallbackUrl;

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      color: AppColors.card,
      alignment: Alignment.center,
      child: const Icon(
        Icons.image_outlined,
        size: 18,
        color: AppColors.textTertiary,
      ),
    );
    final String? src = (url != null && url!.isNotEmpty)
        ? url
        : (fallbackUrl != null && fallbackUrl!.isNotEmpty
            ? fallbackUrl
            : null);
    return SizedBox(
      width: 48,
      height: 64,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: src != null
            ? CachedNetworkImage(
                imageUrl: src,
                fit: BoxFit.cover,
                placeholder: (_, _) => Container(color: AppColors.card),
                errorWidget: (_, _, _) => placeholder,
              )
            : placeholder,
      ),
    );
  }
}
