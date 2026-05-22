import 'dart:async';

import 'package:flutter/material.dart';
import '../../../../core/widgets/app_snack.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/scheduler.dart';
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
import '../widgets/dictionary_popup.dart';
import '../widgets/draggable_auto_scroll_fab.dart';
import '../widgets/font_picker_sheet.dart';
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

class _NovelViewState extends State<_NovelView>
    with SingleTickerProviderStateMixin {
  final _scroll = ScrollController();

  // Auto-scroll ticker — drives `_scroll` at a constant px/sec while
  // the current book is opted in. Lazily created on first activation;
  // SingleTickerProviderStateMixin only allows `createTicker` once per
  // State so we stop/start instead of disposing on every toggle.
  Ticker? _autoScrollTicker;
  Duration _lastAutoTick = Duration.zero;
  bool _autoScrollEnabled = false;
  double _autoScrollPxPerSec = 0;
  String? _lastEvalBookKey;
  StreamSubscription<NovelPrefs>? _prefsSub;
  StreamSubscription<NovelReaderState>? _readerStateSub;

  @override
  void initState() {
    super.initState();
    final prefsCubit = context.read<NovelPrefsCubit>();
    final readerBloc = context.read<NovelReaderBloc>();
    _evaluateAutoScroll();
    _prefsSub = prefsCubit.stream.listen((_) {
      if (!mounted) return;
      _evaluateAutoScroll();
    });
    _readerStateSub = readerBloc.stream.listen((s) {
      if (!mounted) return;
      final key = s.book == null
          ? null
          : NovelPrefsCubit.bookKey(s.book!.sourceId, s.book!.id);
      if (key == _lastEvalBookKey) return;
      _lastEvalBookKey = key;
      _evaluateAutoScroll();
    });
  }

  @override
  void dispose() {
    _prefsSub?.cancel();
    _readerStateSub?.cancel();
    _autoScrollTicker?.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Map 0..1 slider value to a px/sec rate. Novels move slower than
  /// manga panels — readable text needs about 15..120 px/sec.
  double _autoScrollPxPerSecFromFraction(double f) {
    return 15.0 + 105.0 * f.clamp(0.0, 1.0);
  }

  /// Reads the current book + prefs and starts/stops the ticker.
  /// Called from both subscriptions so changes from either side
  /// (toggle, slider drag, book load) take effect immediately.
  void _evaluateAutoScroll() {
    if (!mounted) return;
    final prefs = context.read<NovelPrefsCubit>().state;
    final book = context.read<NovelReaderBloc>().state.book;
    final enabled = book != null &&
        prefs.autoScrollEnabledBooks
            .contains(NovelPrefsCubit.bookKey(book.sourceId, book.id));
    _autoScrollPxPerSec =
        enabled ? _autoScrollPxPerSecFromFraction(prefs.autoScrollSpeed) : 0;
    if (enabled == _autoScrollEnabled) return;
    _autoScrollEnabled = enabled;
    if (!enabled) {
      _autoScrollTicker?.stop();
      return;
    }
    _autoScrollTicker ??= createTicker(_onAutoScrollTick);
    _lastAutoTick = Duration.zero;
    if (!_autoScrollTicker!.isActive) {
      _autoScrollTicker!.start();
    }
  }

  void _onAutoScrollTick(Duration elapsed) {
    if (!_scroll.hasClients) {
      _lastAutoTick = elapsed;
      return;
    }
    final pos = _scroll.position;
    // Pause while the user is actively dragging — yanking them back
    // would feel awful. Resume cleanly by resetting the time baseline.
    if (pos.userScrollDirection != ScrollDirection.idle) {
      _lastAutoTick = elapsed;
      return;
    }
    final dtSec = (elapsed - _lastAutoTick).inMicroseconds / 1000000.0;
    _lastAutoTick = elapsed;
    if (dtSec <= 0) return;
    if (pos.maxScrollExtent <= 0) return;
    if (pos.pixels >= pos.maxScrollExtent - 1) {
      // Reached the bottom — advance to the next chapter. The novel
      // bloc reuses the same ScrollController; the resume mechanism
      // jumps back to 0 on chapter load.
      final bloc = context.read<NovelReaderBloc>();
      final s = bloc.state;
      final book = s.book;
      if (book == null) return;
      final ascending = book.chapters.length >= 2 &&
          ((book.chapters.last.number ?? 0) >
              (book.chapters.first.number ?? 0));
      final delta = ascending ? 1 : -1;
      final next = s.chapterIndex + delta;
      if (next >= 0 && next < book.chapters.length) {
        bloc.add(NovelReaderChapterChanged(next));
      }
      return;
    }
    final target = (pos.pixels + _autoScrollPxPerSec * dtSec)
        .clamp(0.0, pos.maxScrollExtent);
    _scroll.jumpTo(target);
  }

  Future<void> _openAutoScrollSheet(BuildContext context) async {
    final prefsCubit = context.read<NovelPrefsCubit>();
    final book = context.read<NovelReaderBloc>().state.book;
    if (book == null) return;
    final sourceId = book.sourceId;
    final bookId = book.id;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return BlocProvider.value(
          value: prefsCubit,
          child: _NovelAutoScrollSheet(sourceId: sourceId, bookId: bookId),
        );
      },
    );
  }

  Future<void> _openSettings(BuildContext context) async {
    final prefsCubit = context.read<NovelPrefsCubit>();
    final book = context.read<NovelReaderBloc>().state.book;
    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return BlocProvider.value(
          value: prefsCubit,
          child: _NovelSettingsSheet(
            sourceId: book?.sourceId,
            bookId: book?.id,
          ),
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
    final prefsCubit = context.watch<NovelPrefsCubit>();
    // Per-book background override falls back to the global mode when
    // the user hasn't set one, or while the book is still loading
    // (state.book is null on cold start).
    final book = context.select<NovelReaderBloc, BookDetail?>(
      (b) => b.state.book,
    );
    final bgMode = book == null
        ? prefsCubit.state.backgroundMode
        : prefsCubit.resolveBackgroundFor(book.sourceId, book.id);
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
      body: Stack(
        children: [
          Positioned.fill(
            child: _bodyContent(context, theme: theme, bg: bg, fg: fg),
          ),
          // Floating auto-scroll control. Shows whenever auto-scroll
          // is enabled for the current book AND the user hasn't hidden
          // the floating button globally.
          if (_autoScrollEnabled && prefsCubit.state.showFloatingAutoScroll)
            Positioned.fill(
              child: DraggableNovelAutoScrollFab(
                onTap: () => _openAutoScrollSheet(context),
              ),
            ),
        ],
      ),
    );
  }

  Widget _bodyContent(
    BuildContext context, {
    required ThemeData theme,
    required Color bg,
    required Color fg,
  }) {
    return BlocConsumer<NovelReaderBloc, NovelReaderState>(
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
                              style: NovelPrefsCubit.applyFontLabel(
                                context
                                    .read<NovelPrefsCubit>()
                                    .resolveFontFor(
                                        book.sourceId, book.id),
                                TextStyle(
                                  fontSize: prefs.fontSize,
                                  height: prefs.lineHeight,
                                  color: fg,
                                ),
                              ),
                              // Inject a "Look up" item as the FIRST
                              // entry in the long-press context menu so
                              // it doesn't get pushed into Android's
                              // 3-dot overflow on narrow screens.
                              // Falls through to the default copy /
                              // share menu when nothing is selected.
                              contextMenuBuilder: (ctx, editableState) {
                                final entries = <ContextMenuButtonItem>[];
                                final selected = editableState
                                    .textEditingValue.selection
                                    .textInside(state.text)
                                    .trim();
                                if (selected.isNotEmpty &&
                                    selected.length <= 60) {
                                  entries.add(ContextMenuButtonItem(
                                    label: 'Look up',
                                    onPressed: () {
                                      ContextMenuController
                                          .removeAny();
                                      showDictionaryPopup(ctx, selected);
                                    },
                                  ));
                                }
                                entries.addAll(
                                    editableState.contextMenuButtonItems);
                                return AdaptiveTextSelectionToolbar
                                    .buttonItems(
                                  anchors:
                                      editableState.contextMenuAnchors,
                                  buttonItems: entries,
                                );
                              },
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

/// Bottom sheet opened from the draggable auto-scroll FAB. Enables /
/// disables auto-scroll for the current book, exposes the global speed
/// slider, and the global "show floating control" toggle (kept here
/// for symmetry with the manga sheet — hiding the FAB from anywhere
/// is fine because the toggle also lives in the main settings sheet).
class _NovelAutoScrollSheet extends StatelessWidget {
  const _NovelAutoScrollSheet({
    required this.sourceId,
    required this.bookId,
  });
  final String sourceId;
  final String bookId;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<NovelPrefsCubit, NovelPrefs>(
      builder: (context, prefs) {
        final cubit = context.read<NovelPrefsCubit>();
        final enabled = prefs.autoScrollEnabledBooks.contains(
            NovelPrefsCubit.bookKey(sourceId, bookId));
        return Container(
          decoration: const BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 12, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Automatic scroll',
                          style: TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded,
                            color: AppColors.textSecondary),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Enable',
                          style: TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Switch.adaptive(
                        value: enabled,
                        activeTrackColor: AppColors.primary,
                        onChanged: (v) => cubit.setAutoScrollForBook(
                          sourceId,
                          bookId,
                          v,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'Speed',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      thumbColor: AppColors.primary,
                      activeTrackColor: AppColors.primary,
                      inactiveTrackColor: AppColors.card,
                      overlayShape:
                          const RoundSliderOverlayShape(overlayRadius: 14),
                      thumbShape:
                          const RoundSliderThumbShape(enabledThumbRadius: 9),
                      trackHeight: 4,
                    ),
                    child: Slider(
                      min: 0,
                      max: 1,
                      value: prefs.autoScrollSpeed,
                      onChanged: enabled
                          ? (v) => cubit.setAutoScrollSpeed(v)
                          : null,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Show floating control button',
                          style: TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Checkbox.adaptive(
                        value: prefs.showFloatingAutoScroll,
                        activeColor: AppColors.primary,
                        onChanged: (v) =>
                            cubit.setShowFloatingAutoScroll(v ?? true),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _NovelSettingsSheet extends StatelessWidget {
  const _NovelSettingsSheet({this.sourceId, this.bookId});
  final String? sourceId;
  final String? bookId;

  bool get _hasBook =>
      sourceId != null && bookId != null && sourceId!.isNotEmpty;

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
                  Row(
                    children: [
                      const Text('Background',
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          )),
                      if (_hasBook &&
                          prefs.perBookBackgroundMode.containsKey(
                              NovelPrefsCubit.bookKey(sourceId!, bookId!))) ...[
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: () => cubit.setBackgroundForBook(
                            sourceId!,
                            bookId!,
                            null,
                          ),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 0),
                            minimumSize: const Size(0, 24),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: const Text('Use global',
                              style: TextStyle(fontSize: 11)),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 8),
                  ReadingBgPicker(
                    // Show the effective mode for this book — either the
                    // per-book override or the global default.
                    value: _hasBook
                        ? cubit.resolveBackgroundFor(sourceId!, bookId!)
                        : prefs.backgroundMode,
                    onChanged: (mode) {
                      if (_hasBook) {
                        cubit.setBackgroundForBook(sourceId!, bookId!, mode);
                      } else {
                        cubit.setBackgroundMode(mode);
                      }
                    },
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
                  const Text('Line spacing',
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      )),
                  Slider(
                    value: prefs.lineHeight.clamp(1.0, 2.5),
                    min: 1.0,
                    max: 2.5,
                    divisions: 15,
                    label: prefs.lineHeight.toStringAsFixed(2),
                    onChanged: cubit.setLineHeight,
                  ),
                  const SizedBox(height: 14),
                  if (_hasBook)
                    Builder(builder: (rowCtx) {
                      final label = cubit.resolveFontFor(
                          sourceId!, bookId!);
                      final isOverride = prefs.perBookFontFamily
                          .containsKey(NovelPrefsCubit.bookKey(
                              sourceId!, bookId!));
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(
                          Icons.text_fields_rounded,
                          color: AppColors.textSecondary,
                        ),
                        title: const Text(
                          'Font',
                          style: TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(
                          isOverride
                              ? '$label (per book)'
                              : '$label (global)',
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                        trailing: const Icon(
                          Icons.chevron_right_rounded,
                          color: AppColors.textTertiary,
                        ),
                        onTap: () => FontPickerSheet.show(
                          rowCtx,
                          sourceId: sourceId!,
                          bookId: bookId!,
                        ),
                      );
                    }),
                  // Per-book auto-scroll toggle. Speed and floating-
                  // control visibility stay global and live in the
                  // dedicated auto-scroll sheet (opened via the
                  // floating FAB).
                  if (_hasBook)
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        'Auto-scroll',
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      secondary: const Icon(
                        Icons.play_circle_outline_rounded,
                        color: AppColors.textSecondary,
                      ),
                      value: cubit.isAutoScrollEnabledFor(
                          sourceId!, bookId!),
                      activeTrackColor: AppColors.primary,
                      onChanged: (v) => cubit.setAutoScrollForBook(
                        sourceId!,
                        bookId!,
                        v,
                      ),
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
