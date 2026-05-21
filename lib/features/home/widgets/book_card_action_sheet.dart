import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/di/injection.dart';
import '../../../core/models/book_item.dart';
import '../../../core/repository/library_repository.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/app_snack.dart';

/// Bottom-sheet quick-action menu surfaced by long-pressing a book card.
/// Lets the user jump to the details screen, toggle library membership,
/// or share a `sozoread://` deep link without first opening the book.
Future<void> showBookCardActionSheet(
  BuildContext context,
  BookItem book,
) async {
  final accent = Theme.of(context).colorScheme.primary;
  final library = sl<LibraryRepository>();
  final inLibrary = library.get(book.sourceId, book.id) != null;

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
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    book.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(color: AppColors.divider, height: 1),
          ListTile(
            leading: Icon(Icons.info_outline, color: accent),
            title: const Text(
              'View details',
              style: TextStyle(color: AppColors.textPrimary),
            ),
            onTap: () {
              Navigator.pop(sheetCtx);
              context.pushNamed(
                'detail',
                pathParameters: {
                  'sourceId': book.sourceId,
                  'bookId': book.id,
                },
                extra: book,
              );
            },
          ),
          ListTile(
            leading: Icon(
              inLibrary
                  ? Icons.bookmark_remove_outlined
                  : Icons.bookmark_add_outlined,
              color: accent,
            ),
            title: Text(
              inLibrary ? 'Remove from library' : 'Add to library',
              style: const TextStyle(color: AppColors.textPrimary),
            ),
            onTap: () async {
              Navigator.pop(sheetCtx);
              final messenger = ScaffoldMessenger.of(context);
              if (inLibrary) {
                await library.remove(book.sourceId, book.id);
                messenger.showAppSnack(
                  SnackBar(
                    content: Text('Removed "${book.title}" from library'),
                    duration: const Duration(seconds: 3),
                    action: SnackBarAction(
                      label: 'Undo',
                      onPressed: () => library.add(book),
                    ),
                  ),
                );
              } else {
                await library.add(book);
                messenger.showAppSnack(
                  SnackBar(
                    content: Text('Added "${book.title}" to library'),
                    duration: const Duration(seconds: 3),
                    action: SnackBarAction(
                      label: 'Undo',
                      onPressed: () =>
                          library.remove(book.sourceId, book.id),
                    ),
                  ),
                );
              }
            },
          ),
          ListTile(
            leading: Icon(Icons.share_outlined, color: accent),
            title: const Text(
              'Share',
              style: TextStyle(color: AppColors.textPrimary),
            ),
            onTap: () async {
              Navigator.pop(sheetCtx);
              final link =
                  'sozoread://manga/${Uri.encodeComponent(book.sourceId)}/${Uri.encodeComponent(book.id)}'
                  '?url=${Uri.encodeQueryComponent(book.url)}';
              final shareText = '${book.title} on Sozo Read\n$link';
              await Share.share(shareText, subject: book.title);
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}
