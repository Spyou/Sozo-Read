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
  });

  final String title;
  final List<BookItem> books;
  final bool loading;
  final String? error;
  final void Function(BookItem book)? onTapBook;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(title, style: Theme.of(context).textTheme.headlineSmall),
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
        itemBuilder: (_, __) => const BookCardShimmer(),
        separatorBuilder: (_, __) => const SizedBox(width: 12),
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
      itemBuilder: (_, i) => BookCard(book: books[i], onTap: () => onTapBook?.call(books[i])),
      separatorBuilder: (_, __) => const SizedBox(width: 12),
      itemCount: books.length,
    );
  }
}
