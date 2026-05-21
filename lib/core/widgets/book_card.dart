import 'package:cached_network_image/cached_network_image.dart';
import '../services/image_cache_manager.dart';
import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

import '../models/book_item.dart';
import '../theme/app_colors.dart';

class BookCard extends StatelessWidget {
  const BookCard({
    super.key,
    required this.book,
    this.onTap,
    this.onLongPress,
    this.width = 124,
    this.progress,
    this.subtitle,
  });

  final BookItem book;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double width;
  final double? progress;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 2 / 3,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: book.cover != null
                        ? CachedNetworkImage(
                            cacheManager: appImageCacheManager,
                            imageUrl: book.cover!,
                            httpHeaders: book.coverHeaders,
                            fit: BoxFit.cover,
                            placeholder: (_, _) => _CoverPlaceholder(),
                            errorWidget: (_, _, _) => _CoverError(),
                          )
                        : _CoverError(),
                  ),
                  if (progress != null && progress! > 0)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: ClipRRect(
                        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(10)),
                        child: LinearProgressIndicator(
                          minHeight: 3,
                          value: progress!.clamp(0.0, 1.0),
                          backgroundColor: Colors.black54,
                          valueColor: const AlwaysStoppedAnimation(AppColors.primary),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            // `Flexible` lets the title (2 lines max) shrink to whatever
            // space the grid leaves after the cover. Long titles
            // ("Shin Sekai Builders! ~Class 24…") otherwise overflow the
            // card by ~10px when the parent's height constraint is tight.
            Flexible(
              child: Text(
                book.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(height: 1.15),
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 2),
              Text(
                subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.textSecondary,
                      fontSize: 11,
                    ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CoverPlaceholder extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: AppColors.shimmerBase,
      highlightColor: AppColors.shimmerHighlight,
      child: Container(color: AppColors.card),
    );
  }
}

class _CoverError extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.card,
      child: const Center(
        child: Icon(Icons.broken_image_outlined, color: AppColors.textTertiary, size: 32),
      ),
    );
  }
}

class BookCardShimmer extends StatelessWidget {
  const BookCardShimmer({super.key, this.width = 124});
  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 2 / 3,
            child: Shimmer.fromColors(
              baseColor: AppColors.shimmerBase,
              highlightColor: AppColors.shimmerHighlight,
              child: Container(
                decoration: BoxDecoration(
                  color: AppColors.card,
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Shimmer.fromColors(
            baseColor: AppColors.shimmerBase,
            highlightColor: AppColors.shimmerHighlight,
            child: Container(
              height: 12,
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
