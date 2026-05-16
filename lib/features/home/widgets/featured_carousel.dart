import 'package:flutter/material.dart';

import '../../../core/models/book_detail.dart';
import '../../../core/models/book_item.dart';
import '../../../core/theme/app_colors.dart';
import 'featured_banner.dart';

/// Swipeable carousel of featured items with page indicators.
class FeaturedCarousel extends StatefulWidget {
  const FeaturedCarousel({
    super.key,
    required this.items,
    required this.detailsByBookId,
    required this.onTap,
  });

  final List<BookItem> items;
  final Map<String, BookDetail> detailsByBookId;
  final void Function(BookItem book) onTap;

  @override
  State<FeaturedCarousel> createState() => _FeaturedCarouselState();
}

class _FeaturedCarouselState extends State<FeaturedCarousel> {
  late final PageController _controller = PageController();
  int _index = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) return const SizedBox.shrink();
    final topPadding = MediaQuery.of(context).padding.top;
    final height = 540 + topPadding;
    return SizedBox(
      height: height,
      child: Stack(
        children: [
          PageView.builder(
            controller: _controller,
            itemCount: widget.items.length,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (_, i) {
              final b = widget.items[i];
              return FeaturedBanner(
                book: b,
                detail: widget.detailsByBookId[b.id],
                onTap: () => widget.onTap(b),
              );
            },
          ),
          // Page indicator dots — anchored above the section that follows.
          Positioned(
            left: 0,
            right: 0,
            bottom: 12,
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < widget.items.length; i++)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      width: i == _index ? 18 : 6,
                      height: 4,
                      decoration: BoxDecoration(
                        color: i == _index
                            ? AppColors.primary
                            : Colors.white.withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
