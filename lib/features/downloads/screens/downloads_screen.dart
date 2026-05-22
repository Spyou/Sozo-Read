import 'package:cached_network_image/cached_network_image.dart';
import '../../../core/services/image_cache_manager.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../../core/di/injection.dart';
import '../../../core/repository/downloads_repository.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/app_snack.dart';
import '../../../core/widgets/state_views.dart';

/// Top-level downloads screen.
///
/// Groups every in-flight, completed, or failed download by series so
/// the user can scan their queue book-by-book. Per-row controls switch
/// on `entry.status`:
///
///   * queued      → spinner + label
///   * downloading → progress bar + Pause button
///   * paused      → "Paused" label + Resume button
///   * done        → green check
///   * failed      → error + Retry button
///
/// Plus a top-bar overflow with Pause-all / Resume-all / Clear-completed
/// for bulk control. Live updates come straight from the Hive box's
/// `listenable()` — the repository writes every state change there, so
/// any incoming event triggers a rebuild without an extra stream layer.
class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  final DownloadsRepository _repo = sl<DownloadsRepository>();
  // Collapsed-group state keyed by `sourceId::bookId`. Survives Hive
  // updates so user-driven collapses don't pop open on every progress
  // tick.
  final Set<String> _collapsed = {};

  /// Opens a downloaded chapter directly in the reader. Relies on the
  /// book snapshot stashed at download time so this works fully offline.
  /// The snapshot may be missing for very old downloads from before the
  /// feature shipped; in that case we fall back to navigating to the
  /// detail screen so the user can tap from there.
  void _openReader(BuildContext context, DownloadEntry entry) {
    final book = _repo.getBookSnapshot(entry.sourceId, entry.bookId);
    if (book == null) {
      context.pushNamed(
        'detail',
        pathParameters: {'sourceId': entry.sourceId, 'bookId': entry.bookId},
        queryParameters: {'url': entry.chapterUrl},
      );
      return;
    }
    final chapterIndex =
        book.chapters.indexWhere((c) => c.id == entry.chapterId);
    if (chapterIndex < 0) {
      ScaffoldMessenger.of(context).showAppSnack(
        const SnackBar(content: Text('Chapter no longer in the book.')),
      );
      return;
    }
    final routeName = entry.isNovel ? 'novel-reader' : 'manga-reader';
    context.pushNamed(
      routeName,
      pathParameters: {'sourceId': book.sourceId, 'bookId': book.id},
      extra: <String, dynamic>{
        'book': book,
        'chapterIndex': chapterIndex,
      },
    );
  }

  Future<void> _delete(DownloadEntry e) async {
    await _repo.delete(e.sourceId, e.bookId, e.chapterId);
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _pauseAll(List<DownloadEntry> entries) async {
    final messenger = ScaffoldMessenger.of(context);
    var n = 0;
    for (final e in entries) {
      if (e.status == DownloadStatus.downloading ||
          e.status == DownloadStatus.queued) {
        try {
          await _repo.pause(e.sourceId, e.bookId, e.chapterId);
          n++;
        } catch (_) {
          // Per-entry failure shouldn't kill the bulk op.
        }
      }
    }
    if (!mounted) return;
    messenger.showAppSnack(
      SnackBar(content: Text('Paused $n download${n == 1 ? '' : 's'}')),
    );
  }

  Future<void> _resumeAll(List<DownloadEntry> entries) async {
    final messenger = ScaffoldMessenger.of(context);
    var n = 0;
    for (final e in entries) {
      if (e.status == DownloadStatus.paused ||
          e.status == DownloadStatus.failed) {
        try {
          if (e.status == DownloadStatus.failed) {
            await _repo.retry(e.sourceId, e.bookId, e.chapterId);
          } else {
            await _repo.resume(e.sourceId, e.bookId, e.chapterId);
          }
          n++;
        } catch (_) {}
      }
    }
    if (!mounted) return;
    messenger.showAppSnack(
      SnackBar(content: Text('Resumed $n download${n == 1 ? '' : 's'}')),
    );
  }

  Future<void> _clearCompleted(List<DownloadEntry> entries) async {
    final completed =
        entries.where((e) => e.status == DownloadStatus.done).toList();
    if (completed.isEmpty) {
      ScaffoldMessenger.of(context).showAppSnack(
        const SnackBar(content: Text('No completed downloads to clear.')),
      );
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        title: const Text(
          'Clear completed downloads',
          style: TextStyle(color: AppColors.textPrimary),
        ),
        content: Text(
          'Delete ${completed.length} downloaded chapter${completed.length == 1 ? '' : 's'} from this device?',
          style: const TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              'Delete',
              style: TextStyle(color: AppColors.primary),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    for (final e in completed) {
      try {
        await _repo.delete(e.sourceId, e.bookId, e.chapterId);
      } catch (_) {}
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showAppSnack(
      SnackBar(
        content: Text(
          'Cleared ${completed.length} download${completed.length == 1 ? '' : 's'}',
        ),
      ),
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('Downloads'),
        actions: [
          ValueListenableBuilder<Box<Map>>(
            valueListenable:
                Hive.box<Map>(DownloadsRepository.boxName).listenable(),
            // We need the entries here too so the overflow menu can act
            // on the current snapshot. ValueListenableBuilder is cheap
            // — only the icon button rebuilds, not the list body below.
            builder: (context, _, _) {
              final entries = _repo.all();
              return PopupMenuButton<String>(
                tooltip: 'Bulk actions',
                icon: const Icon(Icons.more_vert_rounded),
                onSelected: (v) {
                  switch (v) {
                    case 'pause_all':
                      _pauseAll(entries);
                      break;
                    case 'resume_all':
                      _resumeAll(entries);
                      break;
                    case 'clear_completed':
                      _clearCompleted(entries);
                      break;
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem<String>(
                    value: 'pause_all',
                    child: Row(
                      children: [
                        Icon(Icons.pause_rounded, size: 18),
                        SizedBox(width: 12),
                        Text('Pause all'),
                      ],
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'resume_all',
                    child: Row(
                      children: [
                        Icon(Icons.play_arrow_rounded, size: 18),
                        SizedBox(width: 12),
                        Text('Resume all'),
                      ],
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'clear_completed',
                    child: Row(
                      children: [
                        Icon(Icons.delete_sweep_outlined,
                            size: 18, color: AppColors.primary),
                        SizedBox(width: 12),
                        Text(
                          'Clear completed',
                          style: TextStyle(color: AppColors.primary),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
      body: ValueListenableBuilder<Box<Map>>(
        valueListenable:
            Hive.box<Map>(DownloadsRepository.boxName).listenable(),
        builder: (context, _, _) {
          final entries = _repo.all();
          if (entries.isEmpty) {
            return const EmptyView(
              icon: Icons.download_done_outlined,
              message: 'No downloads yet.',
            );
          }
          // Group by sourceId::bookId. Order: most-recently-updated book
          // first (matches `entries` which is already sorted by updatedAt
          // descending in the repo).
          final groups = <String, List<DownloadEntry>>{};
          for (final e in entries) {
            final key = '${e.sourceId}::${e.bookId}';
            groups.putIfAbsent(key, () => []).add(e);
          }
          final keys = groups.keys.toList();
          return ListView.builder(
            padding: const EdgeInsets.only(bottom: 16),
            itemCount: keys.length,
            itemBuilder: (_, gi) {
              final groupKey = keys[gi];
              final groupEntries = groups[groupKey]!;
              final first = groupEntries.first;
              final collapsed = _collapsed.contains(groupKey);
              final doneCount = groupEntries
                  .where((e) => e.status == DownloadStatus.done)
                  .length;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _SeriesHeader(
                    sourceId: first.sourceId,
                    bookId: first.bookId,
                    title: first.bookTitle,
                    totalCount: groupEntries.length,
                    doneCount: doneCount,
                    collapsed: collapsed,
                    onToggle: () => setState(() {
                      if (collapsed) {
                        _collapsed.remove(groupKey);
                      } else {
                        _collapsed.add(groupKey);
                      }
                    }),
                  ),
                  if (!collapsed)
                    ...groupEntries.map((e) => _ChapterRow(
                          entry: e,
                          repo: _repo,
                          onOpen: () => _openReader(context, e),
                          onDelete: () => _delete(e),
                        )),
                  const Divider(height: 1),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

/// Header card sitting above each book's chapter rows. Shows the cover
/// thumb (from the cached book snapshot if available), the book title,
/// and a "N of M" downloaded count. Tapping expands/collapses the
/// group beneath it.
class _SeriesHeader extends StatelessWidget {
  const _SeriesHeader({
    required this.sourceId,
    required this.bookId,
    required this.title,
    required this.totalCount,
    required this.doneCount,
    required this.collapsed,
    required this.onToggle,
  });

  final String sourceId;
  final String bookId;
  final String title;
  final int totalCount;
  final int doneCount;
  final bool collapsed;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final book = sl<DownloadsRepository>().getBookSnapshot(sourceId, bookId);
    final cover = book?.cover;
    final coverHeaders = book?.coverHeaders;
    return InkWell(
      onTap: onToggle,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        color: AppColors.card.withValues(alpha: 0.5),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 40,
                height: 56,
                child: cover != null
                    ? CachedNetworkImage(
                        cacheManager: sozoCacheManagerFor(context),
                        imageUrl: cover,
                        httpHeaders: coverHeaders,
                        fit: BoxFit.cover,
                        placeholder: (_, _) =>
                            Container(color: AppColors.card),
                        errorWidget: (_, _, _) =>
                            Container(color: AppColors.card),
                      )
                    : Container(
                        color: AppColors.card,
                        alignment: Alignment.center,
                        child: const Icon(
                          Icons.menu_book_outlined,
                          color: AppColors.textTertiary,
                          size: 20,
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$doneCount / $totalCount downloaded',
                    style: const TextStyle(
                      color: AppColors.textTertiary,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              collapsed ? Icons.expand_more : Icons.expand_less,
              color: AppColors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}

/// One downloaded-chapter row. The trailing icon set varies per status
/// per the spec (spinner / progress + Pause / Resume / check / Retry).
/// The 3-dot trailing menu surfaces the "open chapter" + "delete"
/// actions without bloating the inline control set.
class _ChapterRow extends StatelessWidget {
  const _ChapterRow({
    required this.entry,
    required this.repo,
    required this.onOpen,
    required this.onDelete,
  });

  final DownloadEntry entry;
  final DownloadsRepository repo;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  Future<void> _pause() =>
      repo.pause(entry.sourceId, entry.bookId, entry.chapterId);
  Future<void> _resume() =>
      repo.resume(entry.sourceId, entry.bookId, entry.chapterId);
  Future<void> _retry() =>
      repo.retry(entry.sourceId, entry.bookId, entry.chapterId);

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final readyToOpen = entry.status == DownloadStatus.done;
    final isFailed = entry.status == DownloadStatus.failed;

    final statusLabel = switch (entry.status) {
      DownloadStatus.queued => 'Queued',
      DownloadStatus.downloading =>
        'Downloading ${entry.completed}/${entry.total}',
      DownloadStatus.paused => 'Paused · ${entry.completed}/${entry.total}',
      DownloadStatus.done =>
        entry.isNovel ? 'Saved' : '${entry.total} pages',
      DownloadStatus.failed => 'Failed',
    };
    final progress = entry.total == 0 ? null : entry.completed / entry.total;

    // Subtitle layered text: chapter date (if known) · status · error.
    // Error appears only on failed rows so the visual hierarchy nudges
    // the eye toward Retry.
    final subtitleParts = <String>[
      if (entry.chapterDate != null) entry.chapterDate!,
      statusLabel,
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: ListTile(
        // Done downloads are always tappable; others are no-ops to avoid
        // the user expecting an open action on something incomplete.
        onTap: readyToOpen ? onOpen : null,
        dense: true,
        contentPadding: const EdgeInsets.only(left: 56, right: 4),
        title: Text(
          entry.chapterTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: AppColors.textPrimary),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              subtitleParts.join(' · '),
              style: const TextStyle(
                color: AppColors.textTertiary,
                fontSize: 11,
              ),
            ),
            // Progress bar only shows while a job is actively in
            // flight or paused — keeps the row compact for queued /
            // done / failed rows where there's no useful percentage
            // to show.
            if (entry.status == DownloadStatus.downloading ||
                entry.status == DownloadStatus.paused)
              Padding(
                padding: const EdgeInsets.only(top: 4, right: 8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 3,
                    backgroundColor: AppColors.card,
                    valueColor: AlwaysStoppedAnimation<Color>(accent),
                  ),
                ),
              ),
            if (isFailed &&
                entry.error != null &&
                entry.error != '__deleted__')
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  entry.error!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: accent.withValues(alpha: 0.85),
                    fontSize: 10,
                  ),
                ),
              ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _statusControl(context, accent),
            PopupMenuButton<String>(
              tooltip: 'More',
              icon: const Icon(
                Icons.more_vert_rounded,
                color: AppColors.textSecondary,
                size: 20,
              ),
              onSelected: (v) {
                switch (v) {
                  case 'open':
                    onOpen();
                    break;
                  case 'delete':
                    onDelete();
                    break;
                }
              },
              itemBuilder: (_) => [
                if (readyToOpen)
                  const PopupMenuItem<String>(
                    value: 'open',
                    child: Row(
                      children: [
                        Icon(Icons.menu_book_outlined, size: 18),
                        SizedBox(width: 12),
                        Text('Open chapter'),
                      ],
                    ),
                  ),
                const PopupMenuItem<String>(
                  value: 'delete',
                  child: Row(
                    children: [
                      Icon(Icons.delete_outline_rounded,
                          size: 18, color: AppColors.primary),
                      SizedBox(width: 12),
                      Text(
                        'Delete download',
                        style: TextStyle(color: AppColors.primary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Per-status trailing widget. Returns either a passive indicator
  /// (spinner, check) or an actionable IconButton (pause / resume /
  /// retry). Keep this small and stateless so the parent's
  /// ValueListenableBuilder can rebuild it freely on Hive writes.
  Widget _statusControl(BuildContext context, Color accent) {
    switch (entry.status) {
      case DownloadStatus.queued:
        return const SizedBox(
          width: 36,
          height: 36,
          child: Center(
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        );
      case DownloadStatus.downloading:
        return IconButton(
          tooltip: 'Pause',
          icon: Icon(Icons.pause_circle_outline_rounded,
              color: accent, size: 22),
          onPressed: _pause,
        );
      case DownloadStatus.paused:
        return IconButton(
          tooltip: 'Resume',
          icon: Icon(Icons.play_circle_outline_rounded,
              color: accent, size: 22),
          onPressed: _resume,
        );
      case DownloadStatus.done:
        return Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(Icons.check_circle, color: accent, size: 20),
        );
      case DownloadStatus.failed:
        return IconButton(
          tooltip: 'Retry',
          icon: const Icon(Icons.refresh_rounded,
              color: AppColors.warning, size: 22),
          onPressed: _retry,
        );
    }
  }
}
