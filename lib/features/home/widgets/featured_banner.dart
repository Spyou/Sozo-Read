import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../core/models/book_item.dart';
import '../../../core/theme/app_colors.dart';

/// Sozo-style hero: single full-bleed cover with a dark gradient fading into
/// the background, title + CTA pinned to the bottom. No backdrop blur.
class FeaturedBanner extends StatelessWidget {
  const FeaturedBanner({super.key, required this.book, this.onTap});

  final BookItem book;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cover = book.cover;
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        height: 420,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (cover != null)
              CachedNetworkImage(
                imageUrl: cover,
                httpHeaders: book.coverHeaders,
                fit: BoxFit.cover,
                alignment: Alignment.topCenter,
                placeholder: (_, _) => Container(color: AppColors.card),
                errorWidget: (_, _, _) => Container(color: AppColors.card),
              )
            else
              Container(color: AppColors.card),

            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0x00000000),
                    Color(0x44000000),
                    Color(0xCC0A0A0A),
                    AppColors.background,
                  ],
                  stops: [0.0, 0.45, 0.8, 1.0],
                ),
              ),
            ),

            Positioned(
              left: 20,
              right: 20,
              bottom: 24,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    book.title.toUpperCase(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                      height: 1.1,
                      shadows: [Shadow(blurRadius: 8, color: Colors.black87)],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      ElevatedButton.icon(
                        onPressed: onTap,
                        icon: const Icon(Icons.play_arrow, size: 22),
                        label: const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 4),
                          child: Text('View'),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                        ),
                      ),
                      const SizedBox(width: 10),
                      OutlinedButton.icon(
                        onPressed: onTap,
                        icon: const Icon(Icons.info_outline, size: 18),
                        label: const Text('Info'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.textPrimary,
                          side: const BorderSide(color: Colors.white24),
                          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
