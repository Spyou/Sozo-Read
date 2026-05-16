import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/di/injection.dart';
import '../../../../core/models/book_detail.dart';
import '../../../../core/repository/library_repository.dart';
import '../../../../core/repository/provider_repository.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widgets/state_views.dart';
import '../bloc/novel_reader_bloc.dart';
import '../bloc/novel_reader_event.dart';
import '../bloc/novel_reader_state.dart';

class NovelReaderScreen extends StatelessWidget {
  const NovelReaderScreen({super.key, required this.book, required this.chapterIndex});
  final BookDetail book;
  final int chapterIndex;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => NovelReaderBloc(
        providerRepo: sl<ProviderRepository>(),
        libraryRepo: sl<LibraryRepository>(),
      )..add(NovelReaderStarted(book: book, chapterIndex: chapterIndex)),
      child: const _NovelView(),
    );
  }
}

class _NovelView extends StatefulWidget {
  const _NovelView();
  @override
  State<_NovelView> createState() => _NovelViewState();
}

class _NovelViewState extends State<_NovelView> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => context.pop()),
        title: BlocBuilder<NovelReaderBloc, NovelReaderState>(
          builder: (_, s) => Text(
            s.book?.title ?? 'Reading',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.text_decrease),
            onPressed: () =>
                context.read<NovelReaderBloc>().add(const NovelReaderFontSizeChanged(-1)),
          ),
          IconButton(
            icon: const Icon(Icons.text_increase),
            onPressed: () =>
                context.read<NovelReaderBloc>().add(const NovelReaderFontSizeChanged(1)),
          ),
        ],
      ),
      body: BlocConsumer<NovelReaderBloc, NovelReaderState>(
        listenWhen: (a, b) => a.chapterIndex != b.chapterIndex,
        listener: (_, _) {
          if (_scroll.hasClients) _scroll.jumpTo(0);
        },
        builder: (context, state) {
          if (state.status == NovelReaderStatus.loading) return const LoadingView();
          if (state.status == NovelReaderStatus.error) {
            return ErrorView(
              message: state.error ?? 'Failed to load',
              onRetry: () => context
                  .read<NovelReaderBloc>()
                  .add(NovelReaderChapterChanged(state.chapterIndex)),
            );
          }
          final book = state.book;
          if (book == null) return const LoadingView();
          final chapter =
              book.chapters.isNotEmpty ? book.chapters[state.chapterIndex] : null;
          return Column(
            children: [
              Expanded(
                child: NotificationListener<ScrollUpdateNotification>(
                  onNotification: (n) {
                    if (n.metrics.maxScrollExtent > 0) {
                      final p = n.metrics.pixels / n.metrics.maxScrollExtent;
                      context
                          .read<NovelReaderBloc>()
                          .add(NovelReaderProgressUpdated(p.clamp(0.0, 1.0)));
                    }
                    return false;
                  },
                  child: SingleChildScrollView(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (chapter != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Text(chapter.title,
                                style: Theme.of(context).textTheme.headlineSmall),
                          ),
                        SelectableText(
                          state.text,
                          style: TextStyle(
                            fontSize: state.fontSize,
                            height: 1.65,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              _NovelNavBar(state: state),
            ],
          );
        },
      ),
    );
  }
}

class _NovelNavBar extends StatelessWidget {
  const _NovelNavBar({required this.state});
  final NovelReaderState state;

  @override
  Widget build(BuildContext context) {
    final book = state.book;
    final canPrev = state.chapterIndex > 0;
    final canNext = book != null && state.chapterIndex < book.chapters.length - 1;
    return SafeArea(
      top: false,
      child: Container(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.divider)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            TextButton.icon(
              onPressed: canPrev
                  ? () => context
                      .read<NovelReaderBloc>()
                      .add(NovelReaderChapterChanged(state.chapterIndex - 1))
                  : null,
              icon: const Icon(Icons.chevron_left),
              label: const Text('Prev'),
            ),
            Expanded(
              child: LinearProgressIndicator(
                value: state.progress,
                color: AppColors.primary,
                backgroundColor: AppColors.card,
                minHeight: 4,
              ),
            ),
            TextButton.icon(
              onPressed: canNext
                  ? () => context
                      .read<NovelReaderBloc>()
                      .add(NovelReaderChapterChanged(state.chapterIndex + 1))
                  : null,
              icon: const Icon(Icons.chevron_right),
              label: const Text('Next'),
            ),
          ],
        ),
      ),
    );
  }
}
