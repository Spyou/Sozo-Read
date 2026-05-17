import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/di/injection.dart';
import '../../../core/models/book_item.dart';
import '../../../core/repository/provider_repository.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/book_card.dart';
import '../../../core/widgets/state_views.dart';
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
                  return const EmptyView(message: 'Type to search', icon: Icons.search);
                }
                if (state.status == SearchStatus.loading) return const LoadingView();
                if (state.status == SearchStatus.error) {
                  return ErrorView(
                    message: state.error ?? 'Search failed',
                    onRetry: () => context.read<SearchBloc>().add(const SearchSubmitted()),
                  );
                }
                final results = state.sortedResults;
                if (results.isEmpty) {
                  return const EmptyView(message: 'No results.');
                }
                return GridView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    childAspectRatio: 0.52,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 14,
                  ),
                  itemCount: results.length,
                  itemBuilder: (_, i) => BookCard(
                    book: results[i],
                    onTap: () => _openDetail(results[i]),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
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
