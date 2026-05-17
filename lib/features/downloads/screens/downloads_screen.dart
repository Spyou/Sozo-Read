import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../../core/di/injection.dart';
import '../../../core/repository/downloads_repository.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/state_views.dart';

class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  final DownloadsRepository _repo = sl<DownloadsRepository>();
  final Set<String> _collapsed = {};

  /// Open a downloaded chapter directly in the reader. We rely on the
  /// book snapshot stashed at download time so this works fully offline —
  /// no provider round-trip. The snapshot may be missing for very old
  /// downloads from before the feature shipped; in that case we fall back
  /// to navigating to the detail screen so the user can tap from there.
  void _openReader(BuildContext context, DownloadEntry entry) {
    final book = _repo.getBookSnapshot(entry.sourceId, entry.bookId);
    if (book == null) {
      // Legacy entry without snapshot — bounce to detail.
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
      ScaffoldMessenger.of(context).showSnackBar(
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(title: const Text('Downloads')),
      body: ValueListenableBuilder<Box<Map>>(
        valueListenable: Hive.box<Map>(DownloadsRepository.boxName).listenable(),
        builder: (context, _, _) {
          final entries = _repo.all();
          if (entries.isEmpty) {
            return const EmptyView(
              icon: Icons.download_done_outlined,
              message: 'No downloads yet.',
            );
          }
          // Group by sourceId::bookId.
          final groups = <String, List<DownloadEntry>>{};
          for (final e in entries) {
            final key = '${e.sourceId}::${e.bookId}';
            groups.putIfAbsent(key, () => []).add(e);
          }
          final keys = groups.keys.toList();
          return ListView.builder(
            itemCount: keys.length,
            itemBuilder: (_, gi) {
              final groupKey = keys[gi];
              final groupEntries = groups[groupKey]!;
              final title = groupEntries.first.bookTitle;
              final collapsed = _collapsed.contains(groupKey);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ListTile(
                    onTap: () => setState(() {
                      if (collapsed) {
                        _collapsed.remove(groupKey);
                      } else {
                        _collapsed.add(groupKey);
                      }
                    }),
                    leading: Icon(
                      collapsed ? Icons.chevron_right : Icons.expand_more,
                      color: theme.colorScheme.primary,
                    ),
                    title: Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${groupEntries.length} chapter${groupEntries.length == 1 ? '' : 's'}',
                      style: const TextStyle(
                        color: AppColors.textTertiary,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  if (!collapsed)
                    ...groupEntries.map((e) => _ChapterRow(
                          entry: e,
                          onTap: () => _openReader(context, e),
                          onDelete: () async {
                            await _repo.delete(e.sourceId, e.bookId, e.chapterId);
                            if (!context.mounted) return;
                            setState(() {});
                          },
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

class _ChapterRow extends StatelessWidget {
  const _ChapterRow({
    required this.entry,
    required this.onTap,
    required this.onDelete,
  });

  final DownloadEntry entry;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final readyToOpen = entry.status == DownloadStatus.done;
    final statusLabel = switch (entry.status) {
      DownloadStatus.queued => 'Queued',
      DownloadStatus.downloading =>
        'Downloading ${entry.completed}/${entry.total}',
      DownloadStatus.done =>
        entry.isNovel ? 'Saved' : '${entry.total} pages',
      DownloadStatus.failed => 'Failed',
    };
    return ListTile(
      // Disable the tap when nothing is openable yet (queued / failed)
      // so the user gets no-op confusion. Done downloads + downloading
      // ones (so they can preview the partial) are tappable.
      onTap: readyToOpen ? onTap : null,
      dense: true,
      contentPadding: const EdgeInsets.only(left: 48, right: 8),
      title: Text(
        entry.chapterTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        [
          if (entry.chapterDate != null) entry.chapterDate!,
          statusLabel,
        ].join(' · '),
        style: const TextStyle(
          color: AppColors.textTertiary,
          fontSize: 11,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (entry.status == DownloadStatus.done)
            Icon(Icons.check_circle, color: accent, size: 18)
          else if (entry.status == DownloadStatus.downloading ||
              entry.status == DownloadStatus.queued)
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                value: entry.total == 0
                    ? null
                    : entry.completed / entry.total,
                color: accent,
              ),
            ),
          IconButton(
            tooltip: 'Delete',
            icon: const Icon(Icons.delete_outline,
                color: AppColors.textSecondary, size: 20),
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}
