import 'package:cached_network_image/cached_network_image.dart';
import '../../../core/services/image_cache_manager.dart';
import 'package:flutter/material.dart';

import '../../../core/models/book_detail.dart';
import '../../../core/models/book_item.dart';
import '../../../core/theme/app_colors.dart';

/// Sozo-style hero: full-bleed cover extending behind the status bar and
/// AppBar, dark gradient blending the bottom of the image into the page
/// background, with title + description + metadata + CTAs overlayed.
class FeaturedBanner extends StatelessWidget {
  const FeaturedBanner({
    super.key,
    required this.book,
    this.detail,
    this.onTap,
  });

  final BookItem book;
  final BookDetail? detail;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cover = book.cover;
    final topPadding = MediaQuery.of(context).padding.top;
    final genres = detail?.genres ?? const <String>[];
    final description = detail?.description;
    final status = detail?.status;

    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        height: 540 + topPadding,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (cover != null)
              CachedNetworkImage(
                cacheManager: sozoCacheManagerFor(context),
                imageUrl: cover,
                httpHeaders: book.coverHeaders,
                fit: BoxFit.cover,
                alignment: Alignment.topCenter,
                placeholder: (_, _) => Container(color: AppColors.card),
                errorWidget: (_, _, _) => Container(color: AppColors.card),
              )
            else
              Container(color: AppColors.card),

            // Top-to-bottom gradient: protect the AppBar contrast at top, fade
            // the image into the background near the bottom.
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0x880A0A0A),
                    Color(0x000A0A0A),
                    Color(0x550A0A0A),
                    Color(0xDD0A0A0A),
                    AppColors.background,
                  ],
                  stops: [0.0, 0.18, 0.50, 0.82, 1.0],
                ),
              ),
            ),

            Positioned(
              left: 20,
              right: 20,
              bottom: 28,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (status != null) _StatusPill(status: status),
                  if (status != null) const SizedBox(height: 10),
                  Text(
                    book.title.toUpperCase(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 28,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.4,
                      height: 1.05,
                      shadows: [Shadow(blurRadius: 10, color: Colors.black87)],
                    ),
                  ),
                  if (genres.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    _GenreLine(genres: genres.take(4).toList()),
                  ],
                  if (description != null && description.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      description,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xCCFFFFFF),
                        fontSize: 13,
                        height: 1.4,
                        shadows: [Shadow(blurRadius: 4, color: Colors.black87)],
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      _SlimButton(
                        icon: Icons.play_arrow_rounded,
                        label: 'Read',
                        filled: true,
                        onTap: onTap,
                      ),
                      const SizedBox(width: 8),
                      _SlimButton(
                        icon: Icons.info_outline_rounded,
                        label: 'Info',
                        filled: false,
                        onTap: onTap,
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

class _SlimButton extends StatelessWidget {
  const _SlimButton({
    required this.icon,
    required this.label,
    required this.filled,
    this.onTap,
  });
  final IconData icon;
  final String label;
  final bool filled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final bg = filled ? Colors.white : Colors.white.withValues(alpha: 0.14);
    final fg = filled ? Colors.black : Colors.white;
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: fg, size: 18),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: fg,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.status});
  final BookStatus status;
  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      BookStatus.ongoing => ('ONGOING', AppColors.success),
      BookStatus.completed => ('COMPLETED', AppColors.primary),
      BookStatus.hiatus => ('HIATUS', AppColors.warning),
      BookStatus.cancelled => ('CANCELLED', AppColors.textTertiary),
      BookStatus.unknown => ('UNKNOWN', AppColors.textTertiary),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        border: Border.all(color: color.withValues(alpha: 0.6), width: 0.8),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.0,
        ),
      ),
    );
  }
}

class _GenreLine extends StatelessWidget {
  const _GenreLine({required this.genres});
  final List<String> genres;
  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (var i = 0; i < genres.length; i++) {
      if (i > 0) {
        children.add(const _Dot());
      }
      children.add(Text(
        genres[i],
        style: const TextStyle(
          color: Color(0xDDFFFFFF),
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
          shadows: [Shadow(blurRadius: 4, color: Colors.black87)],
        ),
      ));
    }
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 6,
      runSpacing: 4,
      children: children,
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot();
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 3,
      height: 3,
      decoration: BoxDecoration(
        color: AppColors.primary,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}
