import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/di/injection.dart';
import '../../../core/repository/library_repository.dart';
import '../../../core/sync/library_sync_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/book_card.dart';
import '../../../core/widgets/state_views.dart';
import '../../../core/widgets/sync_status_badge.dart';
import '../bloc/library_bloc.dart';
import '../bloc/library_event.dart';
import '../bloc/library_state.dart';
import '../widgets/library_search_bar.dart';
import '../widgets/library_sort_sheet.dart';

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
      appBar: AppBar(
        title: const Text('Library'),
        actions: [
          const SyncStatusBadge(),
          Builder(
            builder: (ctx) => IconButton(
              tooltip: 'Sort',
              icon: const Icon(Icons.sort_rounded),
              onPressed: () {
                final bloc = ctx.read<LibraryBloc>();
                LibrarySortSheet.show(
                  ctx,
                  current: bloc.state.sort,
                  onSelected: (s) => bloc.add(LibrarySortChanged(s)),
                );
              },
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          BlocBuilder<LibraryBloc, LibraryState>(
            buildWhen: (a, b) => false,
            builder: (context, state) => LibrarySearchBar(
              initial: state.query,
              onChanged: (v) =>
                  context.read<LibraryBloc>().add(LibrarySearchChanged(v)),
            ),
          ),
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
                // Pull-to-refresh fires LibrarySyncService.refresh() which
                // pulls latest rows from Supabase + flushes any local
                // writes that haven't been pushed yet. No-op if not signed
                // in or Supabase is unreachable.
                return RefreshIndicator(
                  onRefresh: () async {
                    try {
                      await sl<LibrarySyncService>().refresh();
                    } catch (_) {/* sync handles its own errors */}
                  },
                  child: items.isEmpty
                      ? _EmptyLibrary(
                          hasQuery: state.query.trim().isNotEmpty,
                          query: state.query,
                        )
                      : GridView.builder(
                          // Always-scrollable physics so the gesture is
                          // registered even when the grid fits in one
                          // screen (otherwise short lists can't trigger
                          // the refresh).
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding:
                              const EdgeInsets.fromLTRB(12, 0, 12, 24),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            childAspectRatio: 0.52,
                            crossAxisSpacing: 10,
                            mainAxisSpacing: 14,
                          ),
                          itemCount: items.length,
                          itemBuilder: (_, i) {
                            final e = items[i];
                            final isReadingTab =
                                state.tab == LibraryStatus.reading;
                            final hasProgress = e.lastChapterProgress != null;
                            return BookCard(
                              book: e.book,
                              progress: e.lastChapterProgress,
                              subtitle: (isReadingTab && hasProgress)
                                  ? 'Ch. ${e.lastChapterIndex + 1}'
                                  : null,
                              onTap: () => context.pushNamed(
                                'detail',
                                pathParameters: {
                                  'sourceId': e.book.sourceId,
                                  'bookId': e.book.id,
                                },
                                extra: e.book,
                              ),
                            );
                          },
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

/// Empty / no-results state. Wrapped in a scrollable so a pull-to-refresh
/// gesture still works when the library is empty (otherwise nothing in
/// the viewport is draggable).
class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary({required this.hasQuery, required this.query});

  final bool hasQuery;
  final String query;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: c.maxHeight),
          child: EmptyView(
            message: hasQuery
                ? "No matches for '${query.trim()}'"
                : 'No saved books yet',
            icon: hasQuery ? Icons.search_off_rounded : Icons.bookmark_outline,
          ),
        ),
      ),
    );
  }
}
