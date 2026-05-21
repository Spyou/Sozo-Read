import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/di/injection.dart';
import '../../../core/models/book_item.dart';
import '../../../core/repository/provider_repository.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/book_card.dart';
import '../../../core/widgets/state_views.dart' show EmptyView, ErrorView;
import '../../home/screens/home_screen.dart' show pickRandomFromHome;
import '../bloc/search_bloc.dart';
import '../bloc/search_event.dart';
import '../bloc/search_state.dart';
import '../widgets/search_genre_sheet.dart';
import '../widgets/search_sort_sheet.dart';

class SearchScreen extends StatelessWidget {
  const SearchScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => SearchBloc(repository: sl<ProviderRepository>()),
      child: const _SearchView(),
    );
  }
}

class _SearchView extends StatefulWidget {
  const _SearchView();
  @override
  State<_SearchView> createState() => _SearchViewState();
}

class _SearchViewState extends State<_SearchView> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _openDetail(BookItem book) {
    context.pushNamed(
      'detail',
      pathParameters: {'sourceId': book.sourceId, 'bookId': book.id},
      extra: book,
    );
  }

  void _openGenreSheet() {
    final bloc = context.read<SearchBloc>();
    SearchGenreSheet.show(
      context,
      current: bloc.state.genre,
      onSelected: (g) => bloc.add(SearchGenreChanged(g)),
    );
  }

  void _openSortSheet() {
    final bloc = context.read<SearchBloc>();
    SearchSortSheet.show(
      context,
      current: bloc.state.sort,
      onSelected: (s) => bloc.add(SearchSortChanged(s)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final providers = sl<ProviderRepository>().providers;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          focusNode: _focus,
          autocorrect: false,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: 'Search manga or novels...',
            border: InputBorder.none,
            filled: false,
          ),
          onChanged: (v) => context.read<SearchBloc>().add(SearchQueryChanged(v)),
          onSubmitted: (_) => context.read<SearchBloc>().add(const SearchSubmitted()),
        ),
      ),
      body: Column(
        children: [
          // Source + Genre chips row, plus Sort icon button on the right.
          SizedBox(
            height: 44,
            child: BlocBuilder<SearchBloc, SearchState>(
              buildWhen: (a, b) =>
                  a.sourceId != b.sourceId ||
                  a.genre != b.genre ||
                  a.query != b.query,
              builder: (context, state) {
                final hasQuery = state.query.trim().isNotEmpty;
                return Row(
                  children: [
                    Expanded(
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        children: [
                          _SourceChip(
                            label: 'All',
                            selected: state.sourceId == null,
                            onTap: () =>
                                context.read<SearchBloc>().add(const SearchSourceChanged(null)),
                          ),
                          ...providers.map((p) => _SourceChip(
                                label: p.sourceId,
                                selected: state.sourceId == p.sourceId,
                                onTap: () => context
                                    .read<SearchBloc>()
                                    .add(SearchSourceChanged(p.sourceId)),
                              )),
                          if (hasQuery)
                            _GenreFilterChip(
                              genre: state.genre,
                              onTap: _openGenreSheet,
                              accent: cs.primary,
                            ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: IconButton(
                        tooltip: 'Sort',
                        icon: const Icon(Icons.sort_rounded, color: AppColors.textPrimary),
                        onPressed: _openSortSheet,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),

          // Active genre pill (only when a genre is selected).
          BlocBuilder<SearchBloc, SearchState>(
            buildWhen: (a, b) => a.genre != b.genre,
            builder: (context, state) {
              if (state.genre == null) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: _ActiveGenrePill(
                    label: state.genre!,
                    accent: cs.primary,
                    onClear: () =>
                        context.read<SearchBloc>().add(const SearchGenreChanged(null)),
                  ),
                ),
              );
            },
          ),

          Expanded(
            child: BlocBuilder<SearchBloc, SearchState>(
              builder: (context, state) {
                if (state.status == SearchStatus.idle) {
                  return const _SearchIdleView();
                }
                if (state.status == SearchStatus.error) {
                  return ErrorView(
                    message: state.error ?? 'Search failed',
                    onRetry: () =>
                        context.read<SearchBloc>().add(const SearchSubmitted()),
                  );
                }
                // Loading with no results yet — full shimmer grid.
                if (state.status == SearchStatus.loading) {
                  return const _SearchShimmerGrid();
                }
                final results = state.sortedResults;
                final stillSearching = state.isStillSearching;
                if (results.isEmpty && !stillSearching) {
                  // All sources reported in and nothing matched.
                  return _EmptyResultsView(
                    failedSources: state.failedSources,
                  );
                }
                return _SearchResultsGrid(
                  results: results,
                  state: state,
                  onTap: _openDetail,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Shimmer placeholder grid shown while no source has returned results yet.
/// Matches the result grid's geometry so the transition is seamless.
/// Idle state — shown before the user has typed anything. Hosts the
/// "Type to search" hint plus a Random pick button so users who don't
/// know what to look for have a way to discover something.
class _SearchIdleView extends StatelessWidget {
  const _SearchIdleView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.search,
              size: 48,
              color: AppColors.textTertiary,
            ),
            const SizedBox(height: 12),
            const Text(
              'Type to search',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'or',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textTertiary,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 12),
            // Random pick — pulls from whatever Home has currently
            // loaded (featured carousel + section grids). Doesn't
            // trigger a network fetch; users see a "try again in a
            // moment" snackbar if Home isn't warm yet.
            OutlinedButton.icon(
              icon: const Icon(Icons.casino_rounded),
              label: const Text('Random pick'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.primary,
                side: BorderSide(
                  color: AppColors.primary.withValues(alpha: 0.6),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 10,
                ),
              ),
              onPressed: () => pickRandomFromHome(context),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchShimmerGrid extends StatelessWidget {
  const _SearchShimmerGrid();

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: 0.52,
        crossAxisSpacing: 10,
        mainAxisSpacing: 14,
      ),
      itemCount: 12,
      itemBuilder: (_, _) => const BookCardShimmer(width: double.infinity),
    );
  }
}

/// Grid with progressive results. While more sources are still pending,
/// a small progress footer + a row of shimmer cards is appended so the user
/// can see that more hits may still arrive.
class _SearchResultsGrid extends StatelessWidget {
  const _SearchResultsGrid({
    required this.results,
    required this.state,
    required this.onTap,
  });
  final List<BookItem> results;
  final SearchState state;
  final ValueChanged<BookItem> onTap;

  @override
  Widget build(BuildContext context) {
    final stillSearching = state.isStillSearching;
    final hasFailures = state.failedSources.isNotEmpty &&
        !stillSearching; // Surface failures only once we're done.

    // Use CustomScrollView so we can stack: optional warning banner ->
    // results grid -> optional "still searching" footer.
    return CustomScrollView(
      slivers: [
        if (hasFailures)
          SliverToBoxAdapter(
            child: _PartialFailureBanner(
              failedSources: state.failedSources,
            ),
          ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
          sliver: SliverGrid.builder(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              childAspectRatio: 0.52,
              crossAxisSpacing: 10,
              mainAxisSpacing: 14,
            ),
            itemCount: results.length,
            itemBuilder: (_, i) => BookCard(
              book: results[i],
              onTap: () => onTap(results[i]),
            ),
          ),
        ),
        if (stillSearching) ...[
          SliverToBoxAdapter(
            child: _SearchingFooter(
              completed: state.completedSources.length,
              total: state.totalSources,
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
            sliver: SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                childAspectRatio: 0.52,
                crossAxisSpacing: 10,
                mainAxisSpacing: 14,
              ),
              itemCount: 3,
              itemBuilder: (_, _) =>
                  const BookCardShimmer(width: double.infinity),
            ),
          ),
        ],
      ],
    );
  }
}

/// Small inline progress chip shown beneath partial results while the
/// remaining sources are still fetching.
class _SearchingFooter extends StatelessWidget {
  const _SearchingFooter({required this.completed, required this.total});
  final int completed;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.primary,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            'Searching… ($completed of $total sources)',
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

/// Soft warning banner shown above the result grid when one or more
/// sources failed but at least one returned hits. Click to dismiss.
class _PartialFailureBanner extends StatefulWidget {
  const _PartialFailureBanner({required this.failedSources});
  final Set<String> failedSources;

  @override
  State<_PartialFailureBanner> createState() => _PartialFailureBannerState();
}

class _PartialFailureBannerState extends State<_PartialFailureBanner> {
  bool _dismissed = false;
  @override
  Widget build(BuildContext context) {
    if (_dismissed || widget.failedSources.isEmpty) {
      return const SizedBox.shrink();
    }
    final names = widget.failedSources.toList()..sort();
    final label = names.length == 1
        ? "Couldn't reach ${names.first}"
        : "Couldn't reach ${names.join(', ')}";
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Material(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
          child: Row(
            children: [
              const Icon(Icons.cloud_off_outlined,
                  size: 16, color: AppColors.textSecondary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Dismiss',
                icon: const Icon(Icons.close_rounded,
                    size: 16, color: AppColors.textTertiary),
                onPressed: () => setState(() => _dismissed = true),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "No results" state. If some sources failed, mention them so the user
/// knows the empty result wasn't necessarily authoritative.
class _EmptyResultsView extends StatelessWidget {
  const _EmptyResultsView({required this.failedSources});
  final Set<String> failedSources;

  @override
  Widget build(BuildContext context) {
    if (failedSources.isEmpty) {
      return const EmptyView(message: 'No results.');
    }
    final names = failedSources.toList()..sort();
    final hint = names.length == 1
        ? 'Also couldn\'t reach ${names.first}.'
        : 'Also couldn\'t reach: ${names.join(', ')}.';
    return EmptyView(message: 'No results.\n$hint');
  }
}

class _SourceChip extends StatelessWidget {
  const _SourceChip({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
      ),
    );
  }
}

class _GenreFilterChip extends StatelessWidget {
  const _GenreFilterChip({
    required this.genre,
    required this.onTap,
    required this.accent,
  });

  final String? genre;
  final VoidCallback onTap;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final active = genre != null;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: active ? accent : AppColors.card,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.tune_rounded,
                  size: 16,
                  color: active ? AppColors.textPrimary : AppColors.textSecondary,
                ),
                const SizedBox(width: 6),
                Text(
                  active ? genre! : 'Genre',
                  style: TextStyle(
                    color: active ? AppColors.textPrimary : AppColors.textSecondary,
                    fontSize: 13,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
                Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 16,
                  color: active ? AppColors.textPrimary : AppColors.textSecondary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ActiveGenrePill extends StatelessWidget {
  const _ActiveGenrePill({
    required this.label,
    required this.accent,
    required this.onClear,
  });

  final String label;
  final Color accent;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: accent.withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onClear,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.local_offer_rounded, size: 14, color: accent),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: accent,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.close_rounded, size: 16, color: accent),
            ],
          ),
        ),
      ),
    );
  }
}
