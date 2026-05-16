import 'package:flutter/material.dart';

import '../../../core/models/book_item.dart';
import '../../../core/repository/library_repository.dart';
import '../../../core/theme/app_colors.dart';
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
}
