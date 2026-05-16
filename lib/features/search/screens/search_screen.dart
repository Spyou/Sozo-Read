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

  @override
  Widget build(BuildContext context) {
    final providers = sl<ProviderRepository>().providers;
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
          // Source filter chips
          SizedBox(
            height: 44,
            child: BlocBuilder<SearchBloc, SearchState>(
              buildWhen: (a, b) => a.sourceId != b.sourceId,
              builder: (context, state) {
                return ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  children: [
                    _SourceChip(
                      label: 'All',
                      selected: state.sourceId == null,
                      onTap: () => context.read<SearchBloc>().add(const SearchSourceChanged(null)),
                    ),
                    ...providers.map((p) => _SourceChip(
                          label: p.sourceId,
                          selected: state.sourceId == p.sourceId,
                          onTap: () =>
                              context.read<SearchBloc>().add(SearchSourceChanged(p.sourceId)),
                        )),
                  ],
                );
              },
            ),
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
                if (state.results.isEmpty) {
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
                  itemCount: state.results.length,
                  itemBuilder: (_, i) => BookCard(
                    book: state.results[i],
                    onTap: () => _openDetail(state.results[i]),
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
