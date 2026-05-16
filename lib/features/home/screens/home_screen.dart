import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/di/injection.dart';
import '../../../core/models/book_item.dart';
import '../../../core/repository/provider_repository.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/book_card.dart';
import '../../../core/widgets/state_views.dart';
import '../bloc/home_bloc.dart';
import '../bloc/home_event.dart';
import '../bloc/home_state.dart';
import '../widgets/featured_banner.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => HomeBloc(repository: sl<ProviderRepository>())..add(const HomeStarted()),
      child: const _HomeView(),
    );
  }
}

class _HomeView extends StatelessWidget {
  const _HomeView();

  void _openDetail(BuildContext context, BookItem book) {
    context.pushNamed(
      'detail',
      pathParameters: {'sourceId': book.sourceId, 'bookId': book.id},
      extra: book,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: BlocBuilder<HomeBloc, HomeState>(
        builder: (context, state) {
          if (state.status == HomeStatus.initial) {
            return const LoadingView();
          }
          if (state.status == HomeStatus.error && state.popular.isEmpty) {
            return ErrorView(
              message: state.error ?? 'Failed to load',
              onRetry: () => context.read<HomeBloc>().add(const HomeRefreshed()),
            );
          }
          return RefreshIndicator(
            color: AppColors.primary,
            backgroundColor: AppColors.surface,
            onRefresh: () async => context.read<HomeBloc>().add(const HomeRefreshed()),
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverAppBar(
                  pinned: false,
                  floating: true,
                  backgroundColor: AppColors.background,
                  elevation: 0,
                  titleSpacing: 16,
                  title: const Text(
                    'AizenRead',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.4,
                      color: AppColors.primary,
                    ),
                  ),
                  actions: [
                    IconButton(
                      icon: const Icon(Icons.search),
                      onPressed: () => context.pushNamed('search'),
                    ),
                  ],
                ),
                SliverPersistentHeader(
                  pinned: true,
                  delegate: _SourceTabsDelegate(
                    sourceIds: state.sourceIds,
                    activeId: state.activeSourceId,
                    onTap: (id) => context.read<HomeBloc>().add(HomeSourceChanged(id)),
                  ),
                ),
                if (state.featured != null)
                  SliverToBoxAdapter(
                    child: FeaturedBanner(
                      book: state.featured!,
                      onTap: () => _openDetail(context, state.featured!),
                    ),
                  ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  sliver: SliverToBoxAdapter(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Popular',
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        if (state.loadingPopular)
                          const SizedBox(
                            height: 14,
                            width: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.primary,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (state.popular.isEmpty && state.loadingPopular)
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    sliver: SliverGrid.builder(
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        childAspectRatio: 0.5,
                        crossAxisSpacing: 10,
                        mainAxisSpacing: 14,
                      ),
                      itemCount: 9,
                      itemBuilder: (_, _) => const BookCardShimmer(),
                    ),
                  )
                else if (state.popular.isEmpty && state.error != null)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: ErrorView(
                      message: state.error!,
                      onRetry: () => context.read<HomeBloc>().add(const HomeRefreshed()),
                    ),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    sliver: SliverGrid.builder(
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        childAspectRatio: 0.5,
                        crossAxisSpacing: 10,
                        mainAxisSpacing: 14,
                      ),
                      itemCount: state.popular.length,
                      itemBuilder: (_, i) => BookCard(
                        book: state.popular[i],
                        onTap: () => _openDetail(context, state.popular[i]),
                      ),
                    ),
                  ),
                const SliverToBoxAdapter(child: SizedBox(height: 32)),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SourceTabsDelegate extends SliverPersistentHeaderDelegate {
  _SourceTabsDelegate({
    required this.sourceIds,
    required this.activeId,
    required this.onTap,
  });
  final List<String> sourceIds;
  final String? activeId;
  final void Function(String) onTap;

  @override
  double get minExtent => 48;
  @override
  double get maxExtent => 48;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Container(
      color: AppColors.background,
      alignment: Alignment.centerLeft,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        itemCount: sourceIds.length,
        separatorBuilder: (_, _) => const SizedBox(width: 18),
        itemBuilder: (_, i) {
          final id = sourceIds[i];
          final selected = id == activeId;
          return _SourcePill(label: id, selected: selected, onTap: () => onTap(id));
        },
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _SourceTabsDelegate oldDelegate) =>
      sourceIds != oldDelegate.sourceIds || activeId != oldDelegate.activeId;
}

class _SourcePill extends StatelessWidget {
  const _SourcePill({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? AppColors.textPrimary : AppColors.textTertiary,
                letterSpacing: 0.2,
              ),
            ),
          ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            height: 2,
            width: selected ? 24 : 0,
            decoration: BoxDecoration(
              color: AppColors.primary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ],
      ),
    );
  }
}
