import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

import '../../../core/theme/app_colors.dart';

/// Full-height shimmer placeholder that mirrors [FeaturedCarousel]'s vertical
/// footprint (540 + top safe area) so home content below doesn't shift when
/// the real carousel paints.
class FeaturedCarouselSkeleton extends StatelessWidget {
  const FeaturedCarouselSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;
    final height = 540 + topPadding;
    return SizedBox(
      height: height,
      child: Shimmer.fromColors(
        baseColor: AppColors.shimmerBase,
        highlightColor: AppColors.shimmerHighlight,
        child: Container(color: AppColors.card),
      ),
    );
  }
}
