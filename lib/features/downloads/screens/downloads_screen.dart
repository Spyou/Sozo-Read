import 'package:flutter/material.dart';
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
  const _ChapterRow({required this.entry, required this.onDelete});

  final DownloadEntry entry;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final statusLabel = switch (entry.status) {
      DownloadStatus.queued => 'Queued',
      DownloadStatus.downloading =>
        'Downloading ${entry.completed}/${entry.total}',
      DownloadStatus.done => '${entry.total} pages',
      DownloadStatus.failed => 'Failed',
    };
    return ListTile(
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
