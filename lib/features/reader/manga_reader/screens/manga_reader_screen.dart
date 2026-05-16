import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/di/injection.dart';
import '../../../../core/models/book_detail.dart';
import '../../../../core/repository/library_repository.dart';
import '../../../../core/repository/provider_repository.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widgets/state_views.dart';
import '../bloc/manga_reader_bloc.dart';
import '../bloc/manga_reader_event.dart';
import '../bloc/manga_reader_state.dart';
import '../widgets/page_image.dart';

class MangaReaderScreen extends StatelessWidget {
  const MangaReaderScreen({super.key, required this.book, required this.chapterIndex});

  final BookDetail book;
  final int chapterIndex;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => MangaReaderBloc(
        providerRepo: sl<ProviderRepository>(),
        libraryRepo: sl<LibraryRepository>(),
      )..add(MangaReaderStarted(book: book, chapterIndex: chapterIndex)),
      child: const _ReaderView(),
    );
  }
}

class _ReaderView extends StatefulWidget {
  const _ReaderView();
  @override
  State<_ReaderView> createState() => _ReaderViewState();
}

class _ReaderViewState extends State<_ReaderView> {
  bool _chromeVisible = true;
  final _scrollController = ScrollController();
  late final PageController _pageController = PageController();

  // Used to detect overscroll at end of chapter -> auto-advance.
  bool _autoAdvanceArmed = false;

  @override
  void initState() {
    super.initState();
    _applyImmersive();
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _scrollController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  void _applyImmersive() {
    SystemChrome.setEnabledSystemUIMode(
      _chromeVisible ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky,
    );
  }

  void _toggleChrome() {
    setState(() => _chromeVisible = !_chromeVisible);
    _applyImmersive();
  }

  void _jumpToPage(int target, ReaderMode mode) {
    final clamped = target.clamp(0, _maxPageIndex);
    if (mode == ReaderMode.vertical) {
      if (_scrollController.hasClients) {
        // No accurate per-page offset (variable image heights). Best effort:
        // estimate using fraction of total scroll extent.
        final max = _scrollController.position.maxScrollExtent;
        final total = _pageCount;
        if (max > 0 && total > 0) {
          final frac = clamped / (total - 1).clamp(1, double.infinity);
          _scrollController.animateTo(
            max * frac,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
          );
        }
      }
    } else {
      if (_pageController.hasClients) {
        _pageController.animateToPage(
          clamped,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
    }
  }

  int get _pageCount =>
      context.read<MangaReaderBloc>().state.pages.length;
  int get _maxPageIndex => (_pageCount - 1).clamp(0, _pageCount);

  Future<void> _openChapterSheet(BookDetail book, int currentIndex) async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.7,
            child: Column(
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 18, 20, 8),
                  child: Row(children: [
                    Text(
                      'Chapters',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ]),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: book.chapters.length,
                    itemBuilder: (_, i) {
                      final ch = book.chapters[i];
                      final selected = i == currentIndex;
                      return ListTile(
                        onTap: () {
                          Navigator.pop(ctx);
                          context.read<MangaReaderBloc>().add(MangaReaderChapterChanged(i));
                        },
                        dense: true,
                        title: Text(
                          ch.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: selected ? AppColors.primary : AppColors.textPrimary,
                            fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                          ),
                        ),
                        subtitle: ch.date != null && ch.date!.isNotEmpty
                            ? Text(
                                ch.date!,
                                style: const TextStyle(
                                  color: AppColors.textTertiary,
                                  fontSize: 11,
                                ),
                              )
                            : null,
                        trailing: selected
                            ? const Icon(Icons.play_circle,
                                color: AppColors.primary, size: 20)
                            : null,
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: BlocConsumer<MangaReaderBloc, MangaReaderState>(
        listenWhen: (a, b) => a.chapterIndex != b.chapterIndex,
        listener: (_, _) {
          if (_scrollController.hasClients) _scrollController.jumpTo(0);
          if (_pageController.hasClients) _pageController.jumpToPage(0);
        },
        builder: (context, state) {
          return Stack(
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggleChrome,
                child: _PageContent(
                  state: state,
                  scrollController: _scrollController,
                  pageController: _pageController,
                  onTapLeft: () =>
                      _jumpToPage(state.pageIndex - 1, state.mode),
                  onTapRight: () =>
                      _jumpToPage(state.pageIndex + 1, state.mode),
                  onTapCenter: _toggleChrome,
                  onArmAutoAdvance: () => _autoAdvanceArmed = true,
                  onTryAutoAdvance: () {
                    if (!_autoAdvanceArmed) return;
                    _autoAdvanceArmed = false;
                    // Next chapter (in user-facing direction: lower index = newer).
                    final book = state.book;
                    if (book == null) return;
                    final nextIdx = state.chapterIndex - 1;
                    if (nextIdx >= 0) {
                      context.read<MangaReaderBloc>().add(MangaReaderChapterChanged(nextIdx));
                    }
                  },
                ),
              ),

              // Brightness dimmer (semi-transparent black overlay).
              if (state.brightness > 0)
                IgnorePointer(
                  child: Container(
                    color: Colors.black.withValues(alpha: state.brightness),
                  ),
                ),

              if (_chromeVisible) ...[
                _TopBar(
                  state: state,
                  onBack: () => context.pop(),
                  onOpenChapters: () {
                    if (state.book != null) {
                      _openChapterSheet(state.book!, state.chapterIndex);
                    }
                  },
                  onOpenSettings: () => _openSettingsSheet(state),
                ),
                _BottomBar(
                  state: state,
                  onSliderChange: (v) => _jumpToPage(v.round(), state.mode),
                  onPrev: () => context
                      .read<MangaReaderBloc>()
                      .add(MangaReaderChapterChanged(state.chapterIndex + 1)),
                  onNext: () => context
                      .read<MangaReaderBloc>()
                      .add(MangaReaderChapterChanged(state.chapterIndex - 1)),
                ),
              ],

              if (state.autoAdvancing)
                Container(
                  color: Colors.black54,
                  alignment: Alignment.center,
                  child: const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 32,
                        height: 32,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.4,
                          color: AppColors.primary,
                        ),
                      ),
                      SizedBox(height: 12),
                      Text('Loading next chapter…',
                          style: TextStyle(color: Colors.white)),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _openSettingsSheet(MangaReaderState state) async {
    final bloc = context.read<MangaReaderBloc>();
    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return BlocBuilder<MangaReaderBloc, MangaReaderState>(
          bloc: bloc,
          builder: (_, s) => _ReaderSettingsSheet(state: s, bloc: bloc),
        );
      },
    );
  }
}

class _ReaderSettingsSheet extends StatelessWidget {
  const _ReaderSettingsSheet({required this.state, required this.bloc});
  final MangaReaderState state;
  final MangaReaderBloc bloc;

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
          child: Column(
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

              _SectionLabel('Layout'),
              const SizedBox(height: 8),
              _PillRow<ReaderMode>(
                value: state.mode,
                options: const [
                  ('Webtoon', Icons.view_day_rounded, ReaderMode.vertical),
                  ('Paged', Icons.view_carousel_rounded, ReaderMode.horizontal),
                ],
                onChanged: (v) => bloc.add(MangaReaderModeSet(v)),
              ),

              const SizedBox(height: 16),
              _SectionLabel('Direction'),
              const SizedBox(height: 8),
              _PillRow<ReadingDirection>(
                value: state.direction,
                options: const [
                  ('Left to Right', Icons.arrow_forward_rounded, ReadingDirection.ltr),
                  ('Right to Left', Icons.arrow_back_rounded, ReadingDirection.rtl),
                ],
                onChanged: (v) {
                  if (v != state.direction) {
                    bloc.add(const MangaReaderDirectionToggled());
                  }
                },
              ),

              const SizedBox(height: 18),
              _SectionLabel('Brightness'),
              const SizedBox(height: 4),
              Row(
                children: [
                  const Icon(Icons.brightness_low,
                      color: AppColors.textTertiary, size: 18),
                  const SizedBox(width: 6),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 3,
                        thumbColor: AppColors.primary,
                        activeTrackColor: AppColors.primary,
                        inactiveTrackColor: AppColors.card,
                        overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                      ),
                      child: Slider(
                        value: (1 - state.brightness / 0.85).clamp(0.15, 1.0),
                        min: 0.15,
                        max: 1.0,
                        onChanged: (v) {
                          final dim = ((1 - v) * 0.85).clamp(0.0, 0.85);
                          bloc.add(MangaReaderBrightnessChanged(dim));
                        },
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Icon(Icons.brightness_high,
                      color: AppColors.textTertiary, size: 18),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: AppColors.textSecondary,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

/// Full-width segmented pill row. Selected = filled red, unselected = subtle card.
class _PillRow<T> extends StatelessWidget {
  const _PillRow({
    required this.value,
    required this.options,
    required this.onChanged,
  });
  final T value;
  final List<(String, IconData, T)> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          for (final opt in options)
            Expanded(
              child: GestureDetector(
                onTap: () => onChanged(opt.$3),
                behavior: HitTestBehavior.opaque,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: value == opt.$3 ? AppColors.primary : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        opt.$2,
                        size: 16,
                        color: value == opt.$3 ? Colors.white : AppColors.textSecondary,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        opt.$1,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: value == opt.$3 ? Colors.white : AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _PageContent extends StatelessWidget {
  const _PageContent({
    required this.state,
    required this.scrollController,
    required this.pageController,
    required this.onTapLeft,
    required this.onTapRight,
    required this.onTapCenter,
    required this.onArmAutoAdvance,
    required this.onTryAutoAdvance,
  });
  final MangaReaderState state;
  final ScrollController scrollController;
  final PageController pageController;
  final VoidCallback onTapLeft;
  final VoidCallback onTapRight;
  final VoidCallback onTapCenter;
  final VoidCallback onArmAutoAdvance;
  final VoidCallback onTryAutoAdvance;

  @override
  Widget build(BuildContext context) {
    if (state.status == ReaderStatus.loading) return const LoadingView();
    if (state.status == ReaderStatus.error) {
      return ErrorView(
        message: state.error ?? 'Failed to load pages',
        onRetry: () => context
            .read<MangaReaderBloc>()
            .add(MangaReaderChapterChanged(state.chapterIndex)),
      );
    }
    if (state.pages.isEmpty) return const EmptyView(message: 'No pages');

    if (state.mode == ReaderMode.vertical) {
      return _VerticalReader(
        state: state,
        controller: scrollController,
        onArm: onArmAutoAdvance,
        onTryAdvance: onTryAutoAdvance,
      );
    }
    return _HorizontalReader(
      state: state,
      controller: pageController,
      onTapLeft: onTapLeft,
      onTapRight: onTapRight,
      onTapCenter: onTapCenter,
    );
  }
}

class _VerticalReader extends StatelessWidget {
  const _VerticalReader({
    required this.state,
    required this.controller,
    required this.onArm,
    required this.onTryAdvance,
  });
  final MangaReaderState state;
  final ScrollController controller;
  final VoidCallback onArm;
  final VoidCallback onTryAdvance;

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n is ScrollUpdateNotification) {
          final max = n.metrics.maxScrollExtent;
          final total = state.pages.length;
          if (max > 0 && total > 0) {
            final frac = (n.metrics.pixels / max).clamp(0.0, 1.0);
            final idx = (frac * (total - 1)).round();
            if (idx != state.pageIndex) {
              context.read<MangaReaderBloc>().add(MangaReaderPageChanged(idx));
            }
          }
        }
        if (n is OverscrollNotification && n.overscroll > 0) {
          onArm();
        }
        if (n is ScrollEndNotification &&
            n.metrics.pixels >= n.metrics.maxScrollExtent - 2) {
          onTryAdvance();
        }
        return false;
      },
      child: InteractiveViewer(
        minScale: 1,
        maxScale: 4,
        panEnabled: true,
        child: ListView.builder(
          controller: controller,
          cacheExtent: MediaQuery.of(context).size.height * 4,
          itemCount: state.pages.length,
          itemBuilder: (_, i) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PageImage(page: state.pages[i]),
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  color: Colors.black,
                  child: Text(
                    '${i + 1} / ${state.pages.length}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HorizontalReader extends StatelessWidget {
  const _HorizontalReader({
    required this.state,
    required this.controller,
    required this.onTapLeft,
    required this.onTapRight,
    required this.onTapCenter,
  });
  final MangaReaderState state;
  final PageController controller;
  final VoidCallback onTapLeft;
  final VoidCallback onTapRight;
  final VoidCallback onTapCenter;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    return Stack(
      children: [
        PageView.builder(
          controller: controller,
          itemCount: state.pages.length,
          reverse: state.direction == ReadingDirection.rtl,
          onPageChanged: (i) => context
              .read<MangaReaderBloc>()
              .add(MangaReaderPageChanged(i)),
          itemBuilder: (_, i) => InteractiveViewer(
            minScale: 1,
            maxScale: 4,
            panEnabled: true,
            child: Center(
              child: PageImage(page: state.pages[i], fit: BoxFit.contain),
            ),
          ),
        ),
        // Tap zones — overlay invisible regions on left/center/right.
        Row(
          children: [
            Expanded(
              flex: 3,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: state.direction == ReadingDirection.rtl ? onTapRight : onTapLeft,
              ),
            ),
            Expanded(
              flex: 4,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: onTapCenter,
              ),
            ),
            Expanded(
              flex: 3,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: state.direction == ReadingDirection.rtl ? onTapLeft : onTapRight,
              ),
            ),
          ],
        ),
        // Tiny edge hint while controls are hidden — show direction arrows
        // briefly on first page entry. Subtle; doesn't intrude.
        if (state.pageIndex == 0)
          Positioned(
            left: 8,
            top: 0,
            bottom: 0,
            child: Center(
              child: Icon(
                state.direction == ReadingDirection.rtl
                    ? Icons.chevron_right
                    : Icons.chevron_left,
                color: Colors.white24,
                size: width * 0.04,
              ),
            ),
          ),
      ],
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.state,
    required this.onBack,
    required this.onOpenChapters,
    required this.onOpenSettings,
  });
  final MangaReaderState state;
  final VoidCallback onBack;
  final VoidCallback onOpenChapters;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final book = state.book;
    final chapter = (book != null && book.chapters.isNotEmpty)
        ? book.chapters[state.chapterIndex].title
        : '';
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: Container(
            color: Colors.black.withValues(alpha: 0.45),
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      onPressed: onBack,
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            book?.title ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            chapter,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white70, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Chapters',
                      icon: const Icon(Icons.list, color: Colors.white),
                      onPressed: onOpenChapters,
                    ),
                    IconButton(
                      tooltip: 'Settings',
                      icon: const Icon(Icons.tune_rounded, color: Colors.white),
                      onPressed: onOpenSettings,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.state,
    required this.onSliderChange,
    required this.onPrev,
    required this.onNext,
  });
  final MangaReaderState state;
  final ValueChanged<double> onSliderChange;
  final VoidCallback onPrev;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final book = state.book;
    final canPrev = book != null && state.chapterIndex < book.chapters.length - 1;
    final canNext = state.chapterIndex > 0;
    final total = state.pages.length;
    final pageIndex = total > 0 ? state.pageIndex.clamp(0, total - 1) : 0;

    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: Container(
            color: Colors.black.withValues(alpha: 0.45),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (total > 1)
                      _PageSlider(
                        current: pageIndex,
                        total: total,
                        onChange: onSliderChange,
                      ),
                    Row(
                      children: [
                        IconButton(
                          tooltip: 'Previous chapter',
                          icon: const Icon(Icons.skip_previous, color: Colors.white),
                          onPressed: canPrev ? onPrev : null,
                          color: Colors.white,
                          disabledColor: Colors.white24,
                        ),
                        Expanded(
                          child: Center(
                            child: Text(
                              '${pageIndex + 1} / $total',
                              style: const TextStyle(color: Colors.white, fontSize: 13),
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Next chapter',
                          icon: const Icon(Icons.skip_next, color: Colors.white),
                          onPressed: canNext ? onNext : null,
                          color: Colors.white,
                          disabledColor: Colors.white24,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PageSlider extends StatelessWidget {
  const _PageSlider({
    required this.current,
    required this.total,
    required this.onChange,
  });
  final int current;
  final int total;
  final ValueChanged<double> onChange;

  @override
  Widget build(BuildContext context) {
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 3,
        thumbColor: AppColors.primary,
        activeTrackColor: AppColors.primary,
        inactiveTrackColor: Colors.white24,
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
      ),
      child: Slider(
        min: 0,
        max: (total - 1).toDouble(),
        value: current.toDouble().clamp(0, (total - 1).toDouble()),
        onChanged: onChange,
      ),
    );
  }
}
