import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/di/injection.dart';
import '../../../core/repository/library_repository.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/book_card.dart';
import '../../../core/widgets/state_views.dart';
import '../bloc/library_bloc.dart';
import '../bloc/library_event.dart';
import '../bloc/library_state.dart';

class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) =>
          LibraryBloc(repository: sl<LibraryRepository>())..add(const LibraryStarted()),
      child: const _LibraryView(),
    );
  }
}

class _LibraryView extends StatelessWidget {
  const _LibraryView();

  static const _tabs = [
    (LibraryStatus.reading, 'Reading'),
    (LibraryStatus.completed, 'Completed'),
    (LibraryStatus.onHold, 'On Hold'),
    (LibraryStatus.planning, 'Planning'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('Library')),
      body: Column(
        children: [
          SizedBox(
            height: 48,
            child: BlocBuilder<LibraryBloc, LibraryState>(
              buildWhen: (a, b) => a.tab != b.tab,
              builder: (context, state) => ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                children: _tabs.map((t) {
                  final selected = state.tab == t.$1;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(t.$2),
                      selected: selected,
                      onSelected: (_) =>
                          context.read<LibraryBloc>().add(LibraryTabChanged(t.$1)),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
          Expanded(
            child: BlocBuilder<LibraryBloc, LibraryState>(
              builder: (context, state) {
                final items = state.filtered;
                if (items.isEmpty) {
                  return const EmptyView(
                    message: 'Nothing here yet.\nAdd books from the detail screen.',
                    icon: Icons.bookmark_outline,
                  );
                }
                return GridView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    childAspectRatio: 0.52,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 14,
                  ),
                  itemCount: items.length,
                  itemBuilder: (_, i) {
                    final e = items[i];
                    return BookCard(
                      book: e.book,
                      progress: e.lastChapterProgress,
                      onTap: () => context.pushNamed(
                        'detail',
                        pathParameters: {'sourceId': e.book.sourceId, 'bookId': e.book.id},
                        extra: e.book,
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
