import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/di/injection.dart';
import '../../../core/models/book_item.dart';
import '../../../core/state/active_source_cubit.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/source_picker.dart';
import '../../../core/widgets/state_views.dart';
import '../bloc/home_bloc.dart';
import '../bloc/home_event.dart';
import '../bloc/home_state.dart';
import '../widgets/continue_reading_row.dart';
import '../widgets/featured_carousel.dart';
import '../widgets/featured_carousel_skeleton.dart';
import '../widgets/section_row.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final activeCubit = sl<ActiveSourceCubit>();
    // HomeBloc is a singleton — the splash screen has typically already
    // dispatched HomeSourceChanged by the time we get here, so sections may
    // already be loaded when this widget mounts (no second spinner).
    return BlocProvider.value(
      value: sl<HomeBloc>(),
      child: BlocListener<ActiveSourceCubit, String?>(
        bloc: activeCubit,
        listener: (ctx, src) {
          if (src != null) ctx.read<HomeBloc>().add(HomeSourceChanged(src));
        },
        child: Builder(builder: (ctx) {
          // If splash skipped (e.g. hot-restart lands directly on /home) and
          // no source has been pushed yet, kick the bloc off now.
          final bloc = ctx.read<HomeBloc>();
          activeCubit.initializeIfNeeded();
          final src = activeCubit.state;
          if (src != null && bloc.state.sourceId == null) {
            bloc.add(HomeSourceChanged(src));
          }
          return const _HomeView();
        }),
      ),
    );
  }
}

class _HomeView extends StatefulWidget {
  const _HomeView();
  @override
  State<_HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends State<_HomeView> {
  /// True once the user has scrolled enough that the header should "frost" in.
  /// Snapping between two stable states (transparent vs glass) avoids weird
  /// intermediate colors that the continuous lerp produced.
  bool _scrolled = false;

  bool _onScroll(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    final next = n.metrics.pixels > 30;
    if (next != _scrolled) {
      setState(() => _scrolled = next);
    }
    return false;
  }

  void _openDetail(BuildContext context, BookItem book) {
    context.pushNamed(
      'detail',
      pathParameters: {'sourceId': book.sourceId, 'bookId': book.id},
      extra: book,
    );
  }

  /// Picks a random book from currently-loaded HomeBloc state. We intentionally
  /// do NOT trigger a network fetch — if nothing is loaded yet we just nudge
  /// the user with a SnackBar.
  void _openRandom(BuildContext context) {
    final state = context.read<HomeBloc>().state;
    final pool = <String, BookItem>{};
    for (final b in state.featured) {
      pool[b.id] = b;
    }
    for (final s in state.sections) {
      for (final b in s.books) {
        pool[b.id] = b;
      }
    }
    if (pool.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Loading content — try again in a moment')),
      );
      return;
    }
    final list = pool.values.toList();
    final pick = list[Random().nextInt(list.length)];
    _openDetail(context, pick);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: BlocBuilder<HomeBloc, HomeState>(
        builder: (context, state) {
          if (state.sourceId == null) {
            return _NoSourceView();
          }
          if (state.status == HomeStatus.initial ||
              (state.status == HomeStatus.loading && state.sections.isEmpty)) {
            return const LoadingView();
          }
          if (state.status == HomeStatus.empty) {
            return ErrorView(
              message: 'No content available from ${state.sourceId}.',
              onRetry: () => context.read<HomeBloc>().add(const HomeRefreshed()),
            );
          }
          return RefreshIndicator(
            color: AppColors.primary,
            backgroundColor: AppColors.surface,
            onRefresh: () async => context.read<HomeBloc>().add(const HomeRefreshed()),
            child: Stack(
              children: [
                NotificationListener<ScrollNotification>(
                  onNotification: _onScroll,
                  child: CustomScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      if (state.featured.isNotEmpty)
                        SliverToBoxAdapter(
                          child: FeaturedCarousel(
                            items: state.featured,
                            detailsByBookId: state.featuredDetails,
                            onTap: (b) => _openDetail(context, b),
                          ),
                        )
                      else if (state.status == HomeStatus.loading)
                        const SliverToBoxAdapter(child: FeaturedCarouselSkeleton()),
                      if (state.continueReading.isNotEmpty)
                        SliverToBoxAdapter(
                          child: ContinueReadingRow(
                            entries: state.continueReading,
                            onTap: (b) => _openDetail(context, b),
                          ),
                        ),
                      for (final s in state.sections)
                        SliverToBoxAdapter(
                          child: SectionRow(
                            title: s.title,
                            books: s.books,
                            loading: s.loading,
                            error: s.error,
                            onTapBook: (b) => _openDetail(context, b),
                          ),
                        ),
                      const SliverToBoxAdapter(child: SizedBox(height: 40)),
                    ],
                  ),
                ),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: _GlassHeader(
                    scrolled: _scrolled,
                    onPickSource: () => showSourcePicker(context),
                    onRandom: () => _openRandom(context),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Two-state header: transparent (with a soft top gradient for legibility)
/// when at the top of the banner, frosted-glass once scrolled. The transition
/// is animated so it doesn't snap.
class _GlassHeader extends StatelessWidget {
  const _GlassHeader({
    required this.scrolled,
    required this.onPickSource,
    required this.onRandom,
  });
  final bool scrolled;
  final VoidCallback onPickSource;
  final VoidCallback onRandom;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: BackdropFilter(
        // Strong blur kicks in only when scrolled — at the top we use blur=0
        // so the cover stays sharp behind the brand text.
        filter: ImageFilter.blur(
          sigmaX: scrolled ? 18 : 0,
          sigmaY: scrolled ? 18 : 0,
        ),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            color: scrolled
                ? AppColors.background.withValues(alpha: 0.72)
                : Colors.transparent,
            border: scrolled
                ? const Border(
                    bottom: BorderSide(color: AppColors.divider, width: 0.4),
                  )
                : null,
            gradient: scrolled
                ? null
                : const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x55000000), Color(0x00000000)],
                  ),
          ),
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  const _BrandTitle(),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.casino_rounded, color: Colors.white),
                    tooltip: 'Random manga',
                    onPressed: onRandom,
                  ),
                  IconButton(
                    icon: const Icon(Icons.swap_horiz_rounded, color: Colors.white),
                    tooltip: 'Change source',
                    onPressed: onPickSource,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BrandTitle extends StatelessWidget {
  const _BrandTitle();
  @override
  Widget build(BuildContext context) {
    return BlocBuilder<HomeBloc, HomeState>(
      buildWhen: (a, b) => a.sourceId != b.sourceId,
      builder: (context, state) => Row(
        children: [
          RichText(
            text: const TextSpan(
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.2,
                height: 1,
              ),
              children: [
                TextSpan(text: 'SOZO', style: TextStyle(color: AppColors.primary)),
                TextSpan(text: '-', style: TextStyle(color: AppColors.textTertiary)),
                TextSpan(text: 'READ', style: TextStyle(color: AppColors.textPrimary)),
              ],
            ),
          ),
          if (state.sourceId != null) ...[
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                state.sourceId!,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _NoSourceView extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.collections_bookmark_outlined,
                color: AppColors.textTertiary, size: 56),
            const SizedBox(height: 16),
            const Text('No source selected',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                )),
            const SizedBox(height: 8),
            const Text(
              'Pick a source in Settings to see manga.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              icon: const Icon(Icons.settings),
              label: const Text('Open Settings'),
              onPressed: () => context.go('/settings'),
            ),
          ],
        ),
      ),
    );
  }
}
