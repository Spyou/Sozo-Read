import 'package:flutter/material.dart';
import '../../../../core/widgets/app_snack.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/di/injection.dart';
import '../../../../core/models/book_detail.dart';
import '../../../../core/repository/library_repository.dart';
import '../../../../core/repository/provider_repository.dart';
import '../../../../core/state/novel_prefs_cubit.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widgets/state_views.dart';
import '../../widgets/reading_bg_picker_sheet.dart';
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
      child: BlocProvider.value(
        value: sl<NovelPrefsCubit>(),
        child: const _NovelView(),
      ),
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

  Future<void> _openSettings(BuildContext context) async {
    final prefsCubit = context.read<NovelPrefsCubit>();
    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return BlocProvider.value(
          value: prefsCubit,
          child: const _NovelSettingsSheet(),
        );
      },
    );
  }

  /// Marks the current book as Completed and bounces back to the detail
  /// screen. Single-tap with Undo in the snackbar — no confirmation
  /// dialog (fewer taps; the undo affordance is a safety net).
  Future<void> _markCompleted(BuildContext context) async {
    final book = context.read<NovelReaderBloc>().state.book;
    if (book == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final library = sl<LibraryRepository>();
    final prev = library.get(book.sourceId, book.id)?.status;
    await library.setStatus(
      book.sourceId,
      book.id,
      LibraryStatus.completed,
    );
    if (!context.mounted) return;
    messenger.showAppSnack(
      SnackBar(
        content: const Text('Marked as completed'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            await library.setStatus(
              book.sourceId,
              book.id,
              prev ?? LibraryStatus.reading,
            );
          },
        ),
      ),
    );
    // Pop back to detail so the user sees the new "Completed" state in
    // the chapter list immediately.
    if (context.canPop()) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bgMode = context.watch<NovelPrefsCubit>().state.backgroundMode;
    final bg = ReadingBg.backgroundFor(bgMode, context) ??
        theme.scaffoldBackgroundColor;
    final fg = ReadingBg.textFor(bgMode, context);

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        foregroundColor: fg,
        leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            color: fg,
            onPressed: () => context.pop()),
        title: BlocBuilder<NovelReaderBloc, NovelReaderState>(
          builder: (_, s) => Text(
            s.book?.title ?? 'Reading',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: fg),
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.task_alt_rounded),
            color: fg,
            tooltip: 'Mark as completed',
            onPressed: () => _markCompleted(context),
          ),
          IconButton(
            icon: const Icon(Icons.text_decrease),
            color: fg,
            onPressed: () => context.read<NovelPrefsCubit>().bumpFontSize(-1),
          ),
          IconButton(
            icon: const Icon(Icons.text_increase),
            color: fg,
            onPressed: () => context.read<NovelPrefsCubit>().bumpFontSize(1),
          ),
          IconButton(
            icon: const Icon(Icons.tune_rounded),
            color: fg,
            tooltip: 'Reader settings',
            onPressed: () => _openSettings(context),
          ),
        ],
      ),
      body: BlocConsumer<NovelReaderBloc, NovelReaderState>(
        listenWhen: (a, b) =>
            a.chapterIndex != b.chapterIndex ||
            a.status != b.status ||
            a.pendingResumeProgress != b.pendingResumeProgress,
        listener: (ctx, state) {
          if (state.status == NovelReaderStatus.loading) {
            if (_scroll.hasClients) _scroll.jumpTo(0);
          }
          if (state.status == NovelReaderStatus.success &&
              state.pendingResumeProgress != null) {
            final frac = state.pendingResumeProgress!.clamp(0.0, 1.0);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              if (_scroll.hasClients) {
                final max = _scroll.position.maxScrollExtent;
                if (max > 0) {
                  _scroll.jumpTo(max * frac);
                }
              }
              ctx
                  .read<NovelReaderBloc>()
                  .add(const NovelReaderResumeConsumed());
            });
          }
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
                  child: BlocBuilder<NovelPrefsCubit, NovelPrefs>(
                    builder: (context, prefs) {
                      return SingleChildScrollView(
                        controller: _scroll,
                        padding: EdgeInsets.fromLTRB(
                          prefs.horizontalMargin,
                          8,
                          prefs.horizontalMargin,
                          32,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (chapter != null)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: Text(chapter.title,
                                    style: theme.textTheme.headlineSmall
                                        ?.copyWith(color: fg)),
                              ),
                            SelectableText(
                              state.text,
                              style: TextStyle(
                                fontSize: prefs.fontSize,
                                height: prefs.lineHeight,
                                fontFamily: NovelPrefsCubit.resolveFamily(
                                    prefs.fontFamily),
                                color: fg,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
              _NovelNavBar(state: state, bg: bg, fg: fg),
            ],
          );
        },
      ),
    );
  }
}

class _NovelNavBar extends StatelessWidget {
  const _NovelNavBar({required this.state, required this.bg, required this.fg});
  final NovelReaderState state;
  final Color bg;
  final Color fg;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final book = state.book;
    // Auto-detect the chapter list ordering. Manga providers return
    // chapters newest-first (descending); novel providers return them
    // oldest-first (ascending). Walking the list in either direction
    // needs the right delta or the prev/next buttons feel inverted.
    final ascending = book != null &&
        book.chapters.length >= 2 &&
        ((book.chapters.last.number ?? 0) >
            (book.chapters.first.number ?? 0));
    final prevDelta = ascending ? -1 : 1;
    final nextDelta = ascending ? 1 : -1;
    final i = state.chapterIndex;
    final n = book?.chapters.length ?? 0;
    final canPrev = book != null && i + prevDelta >= 0 && i + prevDelta < n;
    final canNext = book != null && i + nextDelta >= 0 && i + nextDelta < n;
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: bg,
          border: Border(top: BorderSide(color: theme.dividerColor)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: fg),
              onPressed: canPrev
                  ? () => context
                      .read<NovelReaderBloc>()
                      .add(NovelReaderChapterChanged(i + prevDelta))
                  : null,
              icon: const Icon(Icons.chevron_left),
              label: const Text('Prev'),
            ),
            Expanded(
              child: LinearProgressIndicator(
                value: state.progress,
                color: theme.colorScheme.primary,
                backgroundColor: theme.cardTheme.color ?? AppColors.card,
                minHeight: 4,
              ),
            ),
            TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: fg),
              onPressed: canNext
                  ? () => context
                      .read<NovelReaderBloc>()
                      .add(NovelReaderChapterChanged(i + nextDelta))
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

class _NovelSettingsSheet extends StatelessWidget {
  const _NovelSettingsSheet();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 18),
          child: BlocBuilder<NovelPrefsCubit, NovelPrefs>(
            builder: (context, prefs) {
              final cubit = context.read<NovelPrefsCubit>();
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: AppColors.textTertiary.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  const Text('Background',
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      )),
                  const SizedBox(height: 8),
                  ReadingBgPicker(
                    value: prefs.backgroundMode,
                    onChanged: cubit.setBackgroundMode,
                  ),
                  const SizedBox(height: 18),
                  const Text('Font size',
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      )),
                  Slider(
                    value: prefs.fontSize.clamp(12.0, 28.0),
                    min: 12,
                    max: 28,
                    divisions: 16,
                    label: prefs.fontSize.toStringAsFixed(0),
                    onChanged: cubit.setFontSize,
                  ),
                  const SizedBox(height: 4),
                  const Text('Line height',
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      )),
                  Slider(
                    value: prefs.lineHeight.clamp(1.2, 2.2),
                    min: 1.2,
                    max: 2.2,
                    divisions: 10,
                    label: prefs.lineHeight.toStringAsFixed(2),
                    onChanged: cubit.setLineHeight,
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
