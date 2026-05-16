import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../../core/models/page_content.dart';
import '../../../../core/theme/app_colors.dart';

class PageImage extends StatelessWidget {
  const PageImage({super.key, required this.page, this.fit = BoxFit.fitWidth});

  final PageContent page;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    return CachedNetworkImage(
      imageUrl: page.url,
      fit: fit,
      httpHeaders: page.headers,
      // Eager fade so partial images don't feel stuck.
      fadeInDuration: const Duration(milliseconds: 100),
      fadeOutDuration: Duration.zero,
      placeholder: (_, _) => AspectRatio(
        aspectRatio: 2 / 3,
        child: Container(
          color: AppColors.card,
          alignment: Alignment.center,
          child: const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
          ),
        ),
      ),
      errorWidget: (_, url, err) => AspectRatio(
        aspectRatio: 2 / 3,
        child: Container(
          color: AppColors.card,
          padding: const EdgeInsets.all(20),
          alignment: Alignment.center,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.broken_image, color: AppColors.textTertiary, size: 36),
              const SizedBox(height: 8),
              Text(
                'Page failed to load',
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
              ),
              const SizedBox(height: 4),
              Text(
                err.toString(),
                maxLines: 3,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: AppColors.textTertiary, fontSize: 10),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
