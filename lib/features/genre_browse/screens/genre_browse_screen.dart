import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/di/injection.dart';
import '../../../core/models/book_item.dart';
import '../../../core/repository/provider_repository.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/book_card.dart';
import '../../../core/widgets/state_views.dart';
import '../bloc/genre_browse_cubit.dart';

class GenreBrowseScreen extends StatelessWidget {
  const GenreBrowseScreen({super.key, required this.sourceId, required this.genre});

  final String sourceId;
  final String genre;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => GenreBrowseCubit(
        repository: sl<ProviderRepository>(),
        sourceId: sourceId,
        genre: genre,
      )..load(),
      child: _GenreBrowseView(genre: genre),
    );
  }
}

class _GenreBrowseView extends StatelessWidget {
  const _GenreBrowseView({required this.genre});
  final String genre;

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
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(genre),
      ),
      body: BlocBuilder<GenreBrowseCubit, GenreBrowseState>(
        builder: (context, state) {
          if (state.status == GenreBrowseStatus.loading && state.results.isEmpty) {
            return const LoadingView();
          }
          if (state.status == GenreBrowseStatus.error && state.results.isEmpty) {
            return ErrorView(
              message: state.error ?? 'Failed to load',
              onRetry: () => context.read<GenreBrowseCubit>().load(),
            );
          }
          if (state.results.isEmpty) {
            return const EmptyView(message: 'No results.');
          }
          return RefreshIndicator(
            color: AppColors.primary,
            backgroundColor: Theme.of(context).colorScheme.surface,
            onRefresh: () => context.read<GenreBrowseCubit>().refresh(),
            child: GridView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                childAspectRatio: 0.5,
                crossAxisSpacing: 10,
                mainAxisSpacing: 14,
              ),
              itemCount: state.results.length,
              itemBuilder: (_, i) => BookCard(
                book: state.results[i],
                onTap: () => _openDetail(context, state.results[i]),
              ),
            ),
          );
        },
      ),
    );
  }
}
