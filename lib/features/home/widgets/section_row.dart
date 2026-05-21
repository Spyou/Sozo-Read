import 'package:flutter/material.dart';

import '../../../core/models/book_item.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/book_card.dart';

class SectionRow extends StatelessWidget {
  const SectionRow({
    super.key,
    required this.title,
    required this.books,
    this.loading = false,
    this.error,
    this.onTapBook,
    this.onLongPressBook,
  });

  final String title;
  final List<BookItem> books;
  final bool loading;
  final String? error;
  final void Function(BookItem book)? onTapBook;
  final void Function(BookItem book)? onLongPressBook;

  @override
  Widget build(BuildContext context) {
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
                    color: AppColors.primary,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  title,
                  style: const TextStyle(
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
            child: _buildBody(context),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (loading && books.isEmpty) {
      return ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemBuilder: (_, _) => const BookCardShimmer(),
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemCount: 6,
      );
    }
    if (error != null && books.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text(
          error!,
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
        ),
      );
    }
    if (books.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16),
        child: Text('No items.', style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
      );
    }
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemBuilder: (_, i) => BookCard(
        book: books[i],
        onTap: () => onTapBook?.call(books[i]),
        onLongPress: onLongPressBook == null
            ? null
            : () => onLongPressBook!(books[i]),
      ),
      separatorBuilder: (_, _) => const SizedBox(width: 12),
      itemCount: books.length,
    );
  }
}
