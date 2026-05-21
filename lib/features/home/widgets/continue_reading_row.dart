import 'package:flutter/material.dart';

import '../../../core/di/injection.dart';
import '../../../core/models/book_item.dart';
import '../../../core/repository/library_repository.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/app_snack.dart';
import '../../../core/widgets/book_card.dart';

/// "Continue Reading" horizontal row. Visually mirrors [SectionRow] but takes
/// [LibraryEntry] values so we can render an overlay progress bar on top of
/// each cover via [BookCard]'s `progress` param.
class ContinueReadingRow extends StatelessWidget {
  const ContinueReadingRow({
    super.key,
    required this.entries,
    required this.onTap,
  });

  final List<LibraryEntry> entries;
  final void Function(BookItem book) onTap;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(top: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Container(
                  width: 3,
                  height: 18,
                  decoration: BoxDecoration(
                    color: accent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 10),
                const Text(
                  'Continue Reading',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.2,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 244,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemBuilder: (_, i) {
                final e = entries[i];
                return BookCard(
                  book: e.book,
                  progress: e.lastChapterProgress,
                  onTap: () => onTap(e.book),
                  onLongPress: () => _showRemoveSheet(context, e),
                );
              },
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemCount: entries.length,
            ),
          ),
        ],
      ),
    );
  }

  /// Long-press action sheet — lets the user remove the book from the
  /// Continue Reading row without losing it from the library. We do this
  /// by flipping the entry's status from `reading` → `planning`; the
  /// row's source is `byStatus(LibraryStatus.reading)` so the card
  /// disappears on the next rebuild (the parent listens to the Hive box
  /// so the change is reflected immediately).
  Future<void> _showRemoveSheet(
    BuildContext context,
    LibraryEntry entry,
  ) async {
    final accent = Theme.of(context).colorScheme.primary;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.card,
      builder: (sheetCtx) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
              child: Text(
                entry.book.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const Divider(color: AppColors.divider, height: 1),
            ListTile(
              leading: Icon(Icons.playlist_remove_rounded, color: accent),
              title: const Text(
                'Remove from Continue Reading',
                style: TextStyle(color: AppColors.textPrimary),
              ),
              subtitle: const Text(
                'Keeps the book in your library.',
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
              ),
              onTap: () async {
                Navigator.pop(sheetCtx);
                final messenger = ScaffoldMessenger.of(context);
                final repo = sl<LibraryRepository>();
                final previousStatus = entry.status;
                await repo.setStatus(
                  entry.book.sourceId,
                  entry.book.id,
                  LibraryStatus.planning,
                );
                messenger.showAppSnack(
                  SnackBar(
                    content: Text(
                      'Removed "${entry.book.title}" from Continue Reading',
                    ),
                    duration: const Duration(seconds: 4),
                    action: SnackBarAction(
                      label: 'Undo',
                      onPressed: () => repo.setStatus(
                        entry.book.sourceId,
                        entry.book.id,
                        previousStatus,
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
