import 'dart:async';

import 'package:audio_service/audio_service.dart';
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
import '../../../../core/services/novel_tts_service.dart';
import '../../../../core/state/novel_prefs_cubit.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widgets/state_views.dart';
import '../../widgets/reading_bg_picker_sheet.dart';
import '../widgets/dictionary_popup.dart';
import '../widgets/draggable_auto_scroll_fab.dart';
import '../widgets/font_picker_sheet.dart';
import '../widgets/tts_control_sheet.dart';
import '../widgets/tts_mini_player.dart';
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

  // TTS auto-advance flag — set when the previous chapter ended via
  // TTS and we fired the next-chapter event. The bloc listener watches
  // for the matching status==success transition and re-loads the TTS
  // queue with the fresh body text, then resumes playback.
  bool _ttsAutoAdvancePending = false;
  int? _lastReaderChapterIndex;

  // Tracks the text snapshot we last handed to TTS, so the chapter-nav
  // listener can tell a stale "copyWith only updated chapterIndex"
  // emission apart from the eventual "loaded the new body" emission.
  // Without this, the listener fires on the first emission (old text,
  // new chapterIndex) and TTS reads the previous chapter.
  String? _ttsLoadedText;
  // Reason a TTS reload is pending. `null` = no pending reload.
  // `manual` = user tapped Prev/Next; preserve play/pause. `autoAdvance`
  // = TTS finished a chapter on its own; always resume playback.
  _TtsReloadReason? _pendingTtsReload;

  // Paragraph highlight state. The reader splits the chapter body into
  // paragraph widgets and keeps one GlobalKey per paragraph so the TTS
  // index subscription can scroll-into-view + tint the active one.
  StreamSubscription<int>? _ttsParagraphSub;
  int _ttsParagraphIndex = -1;
  List<String> _paragraphs = const [];
  List<GlobalKey> _paragraphKeys = const [];
  String? _splitForText;

  // Listens to MediaItem emissions so the UI rebuilds (showing or
  // hiding the FAB / pill) whenever a chapter is loaded into TTS or
  // the queue is cleared via `dismiss()`.
  StreamSubscription<MediaItem?>? _ttsMediaItemSub;
  // Shown when the active TTS paragraph is no longer in the scroll
  // viewport (user scrolled ahead / back while TTS plays). Tapping it
  // scrolls the active paragraph back into view.
  bool _showBackToParagraphPill = false;

  // Swipe-up-to-next-chapter accumulator. ScrollPhysics on Android
  // doesn't let the viewport scroll past the bottom, but it still
  // reports OverscrollNotification with the attempted pixel delta. We
  // sum those deltas; once they pass [_kOverscrollNextThreshold] the
  // bloc is told to advance to the next chapter. Reset on each
  // ScrollEndNotification so the user can do it again with a fresh
  // gesture rather than building infinite carry-over from prior pulls.
  double _overscrollAccumulated = 0.0;
  bool _overscrollNextFired = false;
  static const double _kOverscrollNextThreshold = 120.0;

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
    _ttsParagraphSub =
        sl<NovelTtsService>().paragraphIndexStream.listen((i) {
      if (!mounted) return;
      if (i == _ttsParagraphIndex) return;
      setState(() => _ttsParagraphIndex = i);
      // Defer to next frame so the rebuilt paragraph widget has a
      // RenderBox to scroll into view.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToParagraph(i);
      });
    });
    // Rebuild on TTS load/unload so the mini-player and FAB toggle
    // their visibility. Distinct-ish: we only flip state when the
    // loaded/unloaded boolean actually changes, not on every emission.
    _ttsMediaItemSub =
        sl<NovelTtsService>().mediaItem.listen((_) {
      if (!mounted) return;
      setState(() {});
    });
    // Watch scroll for the "Back to TTS Location" pill. We listen to
    // every scroll event but only call setState when the visibility
    // bool actually flips — viable for 60Hz drags without jank.
    _scroll.addListener(_updateBackToParagraphPill);
    _readerStateSub = readerBloc.stream.listen((s) {
      if (!mounted) return;
      // Chapter-nav -> TTS reload coordination.
      //
      // The bloc emits THREE times per chapter change:
      //   1. copyWith(chapterIndex: i)         — chapterIndex new, text OLD
      //   2. status=loading, text=''            — clearing old text
      //   3. status=success, text=<new body>    — new chapter ready
      //
      // We can't reload TTS on (1) because s.text still points at the
      // PREVIOUS chapter. So when chapterIndex flips we just remember
      // *why* a reload is needed; the actual reload runs on the first
      // (status==success && text != _ttsLoadedText) emission afterwards.
      if (s.book != null &&
          _lastReaderChapterIndex != null &&
          s.chapterIndex != _lastReaderChapterIndex &&
          _pendingTtsReload == null) {
        if (_ttsAutoAdvancePending) {
          _ttsAutoAdvancePending = false;
          _pendingTtsReload = _TtsReloadReason.autoAdvance;
        } else {
          // Only queue a reload when TTS is already loaded — no point
          // pre-loading a chapter the user hasn't asked to hear.
          final tts = sl<NovelTtsService>();
          if (tts.mediaItem.valueOrNull != null) {
            _pendingTtsReload = _TtsReloadReason.manual;
          }
        }
      }
      // Drain the pending reload once the new body text is actually
      // here. We also guard on `text != _ttsLoadedText` so we never
      // re-push the same text we already handed TTS.
      if (_pendingTtsReload != null &&
          s.status == NovelReaderStatus.success &&
          s.text.isNotEmpty &&
          s.text != _ttsLoadedText) {
        final reason = _pendingTtsReload!;
        _pendingTtsReload = null;
        if (reason == _TtsReloadReason.autoAdvance) {
          _loadTtsForCurrentChapter(s, autoPlay: true);
        } else {
          final wasPlaying = sl<NovelTtsService>().isPlaying;
          _loadTtsForCurrentChapter(s, autoPlay: wasPlaying);
        }
      }
      _lastReaderChapterIndex = s.chapterIndex;
      final key = s.book == null
          ? null
          : NovelPrefsCubit.bookKey(s.book!.sourceId, s.book!.id);
      if (key == _lastEvalBookKey) return;
      _lastEvalBookKey = key;
      _evaluateAutoScroll();
    });
  }

  /// Push the reader state's current chapter into the TTS service.
  /// `autoPlay=true` is used after an auto-advance so the chapter
  /// boundary doesn't pause speech.
  void _loadTtsForCurrentChapter(
    NovelReaderState s, {
    bool autoPlay = false,
    int startParagraph = 0,
  }) {
    final book = s.book;
    if (book == null || book.chapters.isEmpty) return;
    final chapter = book.chapters[s.chapterIndex];
    final tts = sl<NovelTtsService>();
    final prefsCubit = context.read<NovelPrefsCubit>();
    _ttsLoadedText = s.text;
    // Reapply the persisted rate every load — the previous chapter may
    // have used a different rate if the user dragged the slider mid-
    // playback (only an issue across cold restarts in practice).
    // ignore: discarded_futures
    tts.setRate(prefsCubit.resolveTtsRateFor(book.sourceId, book.id));
    // ignore: discarded_futures
    tts
        .loadChapter(
      bookTitle: book.title,
      chapterTitle: chapter.title,
      text: s.text,
      onChapterEnd: _onTtsChapterEnd,
      startParagraph: startParagraph,
    )
        .then((_) {
      if (autoPlay) {
        // ignore: discarded_futures
        tts.play();
      }
    });
  }

  /// Split the chapter body into paragraphs once per chapter swap and
  /// allocate one GlobalKey per paragraph. Mirrors the heuristic used
  /// by the TTS service so paragraph indices stay aligned.
  void _ensureParagraphsFor(String text) {
    if (_splitForText == text) return;
    _splitForText = text;
    _paragraphs = text
        .split(RegExp(r'\n\s*\n+'))
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList(growable: false);
    _paragraphKeys = List<GlobalKey>.generate(
      _paragraphs.length,
      (_) => GlobalKey(),
      growable: false,
    );
    _ttsParagraphIndex = -1;
  }

  /// Walks the paragraph render boxes and returns the first whose top
  /// edge is at or below the scroll viewport's current top. Used as the
  /// resume hint passed to `loadChapter(startParagraph:)`.
  int _firstVisibleParagraphIndex() {
    if (_paragraphKeys.isEmpty) return 0;
    if (!_scroll.hasClients) return 0;
    final viewportTop = _scroll.offset;
    for (var i = 0; i < _paragraphKeys.length; i++) {
      final ctx = _paragraphKeys[i].currentContext;
      if (ctx == null) continue;
      final box = ctx.findRenderObject();
      if (box is! RenderBox) continue;
      // Translate the paragraph's top into the scroll view's content
      // coordinate space by subtracting the viewport's screen origin.
      final paraTop = box.localToGlobal(Offset.zero).dy;
      final viewport = _scroll.position.context.notificationContext
              ?.findRenderObject();
      double anchor = 0;
      if (viewport is RenderBox) {
        anchor = viewport.localToGlobal(Offset.zero).dy;
      }
      final relative = paraTop - anchor + viewportTop;
      if (relative >= viewportTop - 1) return i;
    }
    return _paragraphKeys.length - 1;
  }

  /// Scrolls the paragraph at [i] into the upper third of the
  /// viewport with a 250ms ease.
  void _scrollToParagraph(int i) {
    if (i < 0 || i >= _paragraphKeys.length) return;
    final ctx = _paragraphKeys[i].currentContext;
    if (ctx == null) return;
    // ignore: discarded_futures
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
      alignment: 0.3,
    );
  }

  /// User-driven "swipe up past the end of the chapter" → next chapter.
  /// Different from `_onTtsChapterEnd`: that path also flips the TTS
  /// auto-advance flag so the next chapter starts speaking. Here the
  /// user is reading, not listening; we just hand the bloc the new
  /// chapter index and let it fetch + render.
  void _goToNextChapter() {
    final bloc = context.read<NovelReaderBloc>();
    final s = bloc.state;
    final book = s.book;
    if (book == null) return;
    final ascending = book.chapters.length >= 2 &&
        ((book.chapters.last.number ?? 0) >
            (book.chapters.first.number ?? 0));
    final delta = ascending ? 1 : -1;
    final next = s.chapterIndex + delta;
    if (next < 0 || next >= book.chapters.length) return;
    bloc.add(NovelReaderChapterChanged(next));
  }

  /// Fired by the TTS service after the last paragraph of the current
  /// chapter completes. Mirrors the ascending heuristic used by
  /// `_evaluateAutoScroll` so the next-chapter index lines up with the
  /// provider's ordering.
  void _onTtsChapterEnd() {
    if (!mounted) return;
    final bloc = context.read<NovelReaderBloc>();
    final s = bloc.state;
    final book = s.book;
    if (book == null) return;
    final ascending = book.chapters.length >= 2 &&
        ((book.chapters.last.number ?? 0) >
            (book.chapters.first.number ?? 0));
    final delta = ascending ? 1 : -1;
    final next = s.chapterIndex + delta;
    if (next < 0 || next >= book.chapters.length) return;
    _ttsAutoAdvancePending = true;
    bloc.add(NovelReaderChapterChanged(next));
  }

  /// Tap handler for the "Read aloud" row in the reader settings sheet
  /// AND the floating TTS button.
  ///
  /// Three cases:
  ///   1. TTS is already loaded with THIS book+chapter → just expand
  ///      the mini-player. Whatever state TTS is in (paused mid-
  ///      paragraph, ready at the start, etc.) is preserved.
  ///   2. TTS is idle OR loaded with a different chapter → call
  ///      loadChapter with the resume hint (first visible paragraph in
  ///      the viewport), then expand the mini-player.
  /// We do NOT auto-play; the bar's Play button is the user's
  /// affordance.
  Future<void> _onTtsTap(BuildContext context) async {
    final s = context.read<NovelReaderBloc>().state;
    final book = s.book;
    if (book == null || book.chapters.isEmpty || s.text.isEmpty) return;
    _lastReaderChapterIndex = s.chapterIndex;
    final tts = sl<NovelTtsService>();
    final chapter = book.chapters[s.chapterIndex];
    final wantedId = '${book.title}::${chapter.title}';
    final currentId = tts.mediaItem.valueOrNull?.id;
    final sameChapterAlreadyLoaded =
        currentId == wantedId && tts.paragraphCount > 0;
    if (!sameChapterAlreadyLoaded) {
      final start = _firstVisibleParagraphIndex();
      _loadTtsForCurrentChapter(s, autoPlay: false, startParagraph: start);
    }
    // No setState needed — the `_ttsMediaItemSub` listener triggered by
    // loadChapter will rebuild the Stack on the next tick, swapping the
    // FAB out for the pill.
  }

  /// Builds the TTS surface — either the bottom mini-player OR the
  /// floating circular button. The two are mutually exclusive: never
  /// both on screen at once. Returns an empty list when there's no
  /// book/chapter to read aloud (e.g. while the chapter body is still
  /// loading from the network).
  List<Widget> _buildTtsSurface(BuildContext context) {
    final s = context.read<NovelReaderBloc>().state;
    final book = s.book;
    if (book == null || book.chapters.isEmpty || s.text.isEmpty) {
      return const [];
    }
    final tts = sl<NovelTtsService>();
    final loaded = tts.mediaItem.valueOrNull != null;
    // TTS loaded → Samsung-style pill at the bottom-center. The pill's
    // own close (×) clears the MediaItem, which re-routes this method
    // through the not-loaded branch and brings the FAB back.
    if (loaded) {
      return [
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Center(
            child: TtsMiniPlayer(
              onTapPill: () => TtsControlSheet.show(context),
              onDismiss: () {
                // ignore: discarded_futures
                tts.dismiss();
              },
            ),
          ),
        ),
      ];
    }
    final showFab =
        context.read<NovelPrefsCubit>().state.showFloatingTts;
    if (!showFab) return const [];
    return [
      Positioned(
        right: 16,
        bottom: 20,
        child: TtsFloatingButton(
          onTap: () {
            // ignore: discarded_futures
            _onTtsTap(context);
          },
        ),
      ),
    ];
  }

  @override
  void dispose() {
    _prefsSub?.cancel();
    _readerStateSub?.cancel();
    _ttsParagraphSub?.cancel();
    _ttsMediaItemSub?.cancel();
    _autoScrollTicker?.dispose();
    _scroll.removeListener(_updateBackToParagraphPill);
    _scroll.dispose();
    super.dispose();
  }

  /// Recomputes pill visibility on each scroll event. The active
  /// paragraph is considered "visible" when ANY part of its render box
  /// vertically overlaps the scroll viewport — flexible enough to
  /// handle partially-visible paragraphs at the viewport edges.
  void _updateBackToParagraphPill() {
    if (!mounted) return;
    final desired = _shouldShowBackToParagraphPill();
    if (desired == _showBackToParagraphPill) return;
    setState(() => _showBackToParagraphPill = desired);
  }

  bool _shouldShowBackToParagraphPill() {
    // No pill when TTS isn't loaded or no active paragraph is tracked.
    if (sl<NovelTtsService>().mediaItem.valueOrNull == null) return false;
    final i = _ttsParagraphIndex;
    if (i < 0 || i >= _paragraphKeys.length) return false;
    final ctx = _paragraphKeys[i].currentContext;
    if (ctx == null) return false;
    final paraBox = ctx.findRenderObject();
    if (paraBox is! RenderBox) return false;
    if (!_scroll.hasClients) return false;
    final viewportObj = _scroll.position.context.notificationContext
        ?.findRenderObject();
    if (viewportObj is! RenderBox) return false;
    final paraTop = paraBox.localToGlobal(Offset.zero).dy;
    final paraBottom = paraTop + paraBox.size.height;
    final vTop = viewportObj.localToGlobal(Offset.zero).dy;
    final vBottom = vTop + viewportObj.size.height;
    // Visible = any vertical overlap. Inverse = paragraph fully above
    // OR fully below the viewport.
    final visible = paraBottom > vTop && paraTop < vBottom;
    return !visible;
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
    final outerContext = context;
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
            // The reader settings sheet doesn't sit inside the
            // NovelReaderBloc's provider scope; route TTS through this
            // callback so the sheet doesn't need to look up the bloc.
            onLaunchTts: () => _onTtsTap(outerContext),
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
          // TTS lives in the Reader Settings sheet — see the "Read
          // aloud" row inside _NovelSettingsSheet. Kept here as a
          // comment so future readers don't try to add it back without
          // checking the sheet.
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
          // TTS surface — bar OR FAB, mutually exclusive. The bar is
          // pinned to the bottom; the FAB sits bottom-right and either
          // starts TTS (when no MediaItem) or re-expands the bar (when
          // loaded and collapsed).
          ..._buildTtsSurface(context),
          // "Back to TTS Location" pill — appears at the top when the
          // active paragraph is scrolled out of view. Tap = scroll the
          // paragraph back into the upper third of the viewport.
          if (_showBackToParagraphPill)
            Positioned(
              top: 8,
              left: 0,
              right: 0,
              child: Center(
                child: Material(
                  elevation: 4,
                  color: AppColors.surface,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                    side: BorderSide(
                      color: AppColors.primary.withValues(alpha: 0.4),
                    ),
                  ),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: () {
                      if (_ttsParagraphIndex >= 0) {
                        _scrollToParagraph(_ttsParagraphIndex);
                      }
                    },
                    child: const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.headphones_rounded,
                            size: 16,
                            color: AppColors.primary,
                          ),
                          SizedBox(width: 6),
                          Text(
                            'Back to TTS Location',
                            style: TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
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
                child: NotificationListener<ScrollNotification>(
                  onNotification: (n) {
                    // Scroll-progress mirror for the reader-state bloc
                    // (also drives the floating progress bar in the
                    // mini-player).
                    if (n is ScrollUpdateNotification &&
                        n.metrics.maxScrollExtent > 0) {
                      final p =
                          n.metrics.pixels / n.metrics.maxScrollExtent;
                      context
                          .read<NovelReaderBloc>()
                          .add(NovelReaderProgressUpdated(
                              p.clamp(0.0, 1.0)));
                    }
                    // Swipe-up-past-end gesture: detect overscroll at
                    // the bottom edge and advance the chapter once the
                    // user has pulled `_kOverscrollNextThreshold` pixels
                    // beyond the content. Only counts positive
                    // overscroll (past the end of the chapter), not
                    // top-edge overscroll.
                    if (n is OverscrollNotification &&
                        n.overscroll > 0 &&
                        !_overscrollNextFired) {
                      _overscrollAccumulated += n.overscroll;
                      if (_overscrollAccumulated >=
                          _kOverscrollNextThreshold) {
                        _overscrollNextFired = true;
                        _overscrollAccumulated = 0;
                        _goToNextChapter();
                      }
                    }
                    if (n is ScrollEndNotification) {
                      _overscrollAccumulated = 0;
                      _overscrollNextFired = false;
                    }
                    return false;
                  },
                  child: BlocBuilder<NovelPrefsCubit, NovelPrefs>(
                    builder: (context, prefs) {
                      _ensureParagraphsFor(state.text);
                      final textStyle = NovelPrefsCubit.applyFontLabel(
                        context
                            .read<NovelPrefsCubit>()
                            .resolveFontFor(book.sourceId, book.id),
                        TextStyle(
                          fontSize: prefs.fontSize,
                          height: prefs.lineHeight,
                          color: fg,
                        ),
                      );
                      // Add bottom padding so the chapter's last paragraph
                      // can scroll above the floating TTS cluster (pill +
                      // progress bar + title) instead of being hidden
                      // behind it. The cluster is ~80 px tall after the
                      // safe-area tightening; 100 leaves a small breathing
                      // gap. FAB-only state keeps the default 32 px.
                      final pillVisible =
                          sl<NovelTtsService>().mediaItem.valueOrNull !=
                              null;
                      final bottomPad = pillVisible ? 100.0 : 32.0;
                      return SingleChildScrollView(
                        controller: _scroll,
                        padding: EdgeInsets.fromLTRB(
                          prefs.horizontalMargin,
                          8,
                          prefs.horizontalMargin,
                          bottomPad,
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
                            for (var i = 0; i < _paragraphs.length; i++)
                              _ParagraphView(
                                key: _paragraphKeys[i],
                                text: _paragraphs[i],
                                style: textStyle,
                                highlighted: i == _ttsParagraphIndex,
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

/// Single paragraph widget rendered in the novel body. Keeps its own
/// `SelectableText` so long-press dictionary lookup keeps working, and
/// tints itself when [highlighted] (driven by the TTS paragraph index).
class _ParagraphView extends StatelessWidget {
  const _ParagraphView({
    super.key,
    required this.text,
    required this.style,
    required this.highlighted,
  });

  final String text;
  final TextStyle style;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final bg = highlighted
        ? AppColors.primary.withValues(alpha: 0.15)
        : Colors.transparent;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
        border: Border(
          left: BorderSide(
            color: highlighted ? AppColors.primary : Colors.transparent,
            width: 3,
          ),
        ),
      ),
      child: SelectableText(
        text,
        style: style,
        contextMenuBuilder: (ctx, editableState) {
          final entries = <ContextMenuButtonItem>[];
          final selected = editableState.textEditingValue.selection
              .textInside(text)
              .trim();
          if (selected.isNotEmpty && selected.length <= 60) {
            entries.add(ContextMenuButtonItem(
              label: 'Look up',
              onPressed: () {
                ContextMenuController.removeAny();
                showDictionaryPopup(ctx, selected);
              },
            ));
          }
          entries.addAll(editableState.contextMenuButtonItems);
          return AdaptiveTextSelectionToolbar.buttonItems(
            anchors: editableState.contextMenuAnchors,
            buttonItems: entries,
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
            // Hide the chapter-scroll progress bar when TTS is active.
            // The floating mini-player already shows a TTS paragraph
            // progress bar, and two stacked bars at the bottom of the
            // screen looked redundant + confusing. Falls back to the
            // chapter-scroll bar as soon as TTS is dismissed.
            Expanded(
              child: StreamBuilder<MediaItem?>(
                stream: sl<NovelTtsService>().mediaItem,
                builder: (_, snap) {
                  if (snap.data != null) return const SizedBox.shrink();
                  return LinearProgressIndicator(
                    value: state.progress,
                    color: theme.colorScheme.primary,
                    backgroundColor:
                        theme.cardTheme.color ?? AppColors.card,
                    minHeight: 4,
                  );
                },
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
  const _NovelSettingsSheet({
    this.sourceId,
    this.bookId,
    this.onLaunchTts,
  });
  final String? sourceId;
  final String? bookId;
  final VoidCallback? onLaunchTts;

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
                  // Read-aloud (TTS). Tapping closes this sheet, kicks
                  // off TTS for the current chapter, and opens the
                  // dedicated TTS Control sheet (play/pause + paragraph
                  // skip + speed lives in the OS notification too).
                  if (_hasBook)
                    StreamBuilder<PlaybackState>(
                      stream: sl<NovelTtsService>().playbackState,
                      builder: (_, snap) {
                        final playing = snap.data?.playing ?? false;
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            playing
                                ? Icons.headphones
                                : Icons.headphones_outlined,
                            color: playing
                                ? AppColors.primary
                                : AppColors.textSecondary,
                          ),
                          title: const Text(
                            'Read aloud',
                            style: TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: Text(
                            playing
                                ? 'Playing — tap for controls'
                                : 'Text-to-speech this chapter',
                            style: const TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                          trailing: const Icon(
                            Icons.chevron_right_rounded,
                            color: AppColors.textTertiary,
                          ),
                          onTap: onLaunchTts == null
                              ? null
                              : () {
                                  // Close the settings sheet first so
                                  // the TTS Control sheet replaces it
                                  // cleanly.
                                  Navigator.of(context).pop();
                                  onLaunchTts!.call();
                                },
                        );
                      },
                    ),
                  // Toggle the bottom-right FAB. When off, the user has
                  // to enter TTS via this Read aloud row instead — the
                  // mini-player pill still appears once TTS is loaded.
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    secondary: const Icon(
                      Icons.headphones_outlined,
                      color: AppColors.textSecondary,
                    ),
                    title: const Text(
                      'Show floating Read aloud button',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: const Text(
                      'Bottom-right shortcut to start TTS',
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                    value: prefs.showFloatingTts,
                    activeTrackColor: AppColors.primary,
                    onChanged: (v) => cubit.setShowFloatingTts(v),
                  ),
                  // Voice & language picker. Subtitle shows the
                  // resolved voice or "Default" when no override is set.
                  // Neural engine: per-book overrides aren't supported, so
                  // tapping the row jumps straight to the global voice
                  // manager (download / pick / preview live there).
                  if (_hasBook)
                    Builder(builder: (rowCtx) {
                      final isNeural =
                          cubit.state.ttsEngine == TtsEngine.neural;
                      final voice = cubit
                          .resolveTtsVoiceFor(sourceId!, bookId!)
                          .trim();
                      final subtitle = voice.isNotEmpty
                          ? voice
                          : (isNeural
                              ? 'No voice downloaded yet'
                              : 'Default');
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(
                          Icons.record_voice_over_outlined,
                          color: AppColors.textSecondary,
                        ),
                        title: const Text(
                          'Voice & language',
                          style: TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(
                          subtitle,
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                        trailing: const Icon(
                          Icons.chevron_right_rounded,
                          color: AppColors.textTertiary,
                        ),
                        onTap: () {
                          if (isNeural) {
                            // Close the settings sheet so the manager
                            // takes the foreground cleanly.
                            Navigator.of(rowCtx).pop();
                            rowCtx.push('/settings/tts/voices');
                            return;
                          }
                          _NovelVoicePickerSheet.show(
                            rowCtx,
                            sourceId: sourceId!,
                            bookId: bookId!,
                          );
                        },
                      );
                    }),
                  // Bridge to the full TTS section in global settings —
                  // pitch / volume / paragraph pause / pronunciations /
                  // stop-at-chapter-end / skip-markup live there.
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(
                      Icons.tune_rounded,
                      color: AppColors.textSecondary,
                    ),
                    title: const Text(
                      'More TTS settings',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: const Text(
                      'Pitch, volume, pronunciations, pauses',
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                    trailing: const Icon(
                      Icons.chevron_right_rounded,
                      color: AppColors.textTertiary,
                    ),
                    onTap: () {
                      Navigator.of(context).pop();
                      context.push('/settings/reading');
                    },
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

/// Minimal inline voice picker bottom sheet. Lists the device's
/// available voices grouped by locale; tapping one writes the override
/// via `setTtsVoiceForBook`. "Default" clears the per-book override.
class _NovelVoicePickerSheet extends StatefulWidget {
  const _NovelVoicePickerSheet({
    required this.sourceId,
    required this.bookId,
  });

  final String sourceId;
  final String bookId;

  static Future<void> show(
    BuildContext context, {
    required String sourceId,
    required String bookId,
  }) {
    final prefsCubit = context.read<NovelPrefsCubit>();
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => BlocProvider.value(
        value: prefsCubit,
        child: _NovelVoicePickerSheet(
          sourceId: sourceId,
          bookId: bookId,
        ),
      ),
    );
  }

  @override
  State<_NovelVoicePickerSheet> createState() =>
      _NovelVoicePickerSheetState();
}

class _NovelVoicePickerSheetState extends State<_NovelVoicePickerSheet> {
  Future<List<Map<String, String>>>? _voicesFuture;

  @override
  void initState() {
    super.initState();
    _voicesFuture = sl<NovelTtsService>().availableVoices();
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<NovelPrefsCubit, NovelPrefs>(
      builder: (context, prefs) {
        final cubit = context.read<NovelPrefsCubit>();
        final selected =
            cubit.resolveTtsVoiceFor(widget.sourceId, widget.bookId);
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          maxChildSize: 0.9,
          minChildSize: 0.4,
          expand: false,
          builder: (_, scrollController) => Container(
            decoration: const BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: SafeArea(
              top: false,
              child: Column(
                children: [
                  const SizedBox(height: 10),
                  Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.textTertiary.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(20, 12, 20, 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Voice for this book',
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: FutureBuilder<List<Map<String, String>>>(
                      future: _voicesFuture,
                      builder: (_, snap) {
                        if (snap.connectionState != ConnectionState.done) {
                          return const Center(
                            child: CircularProgressIndicator(
                                color: AppColors.primary),
                          );
                        }
                        final voices = snap.data ?? const [];
                        return ListView.builder(
                          controller: scrollController,
                          itemCount: voices.length + 1,
                          itemBuilder: (_, i) {
                            if (i == 0) {
                              final isDefault = selected.isEmpty;
                              return ListTile(
                                leading: Icon(
                                  isDefault
                                      ? Icons.radio_button_checked
                                      : Icons.radio_button_unchecked,
                                  color: isDefault
                                      ? AppColors.primary
                                      : AppColors.textSecondary,
                                ),
                                title: const Text(
                                  'Default',
                                  style: TextStyle(
                                    color: AppColors.textPrimary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                subtitle: const Text(
                                  'Use the global voice',
                                  style: TextStyle(
                                    color: AppColors.textSecondary,
                                    fontSize: 12,
                                  ),
                                ),
                                onTap: () {
                                  cubit.setTtsVoiceForBook(
                                    widget.sourceId,
                                    widget.bookId,
                                    null,
                                  );
                                  Navigator.pop(context);
                                },
                              );
                            }
                            final v = voices[i - 1];
                            final name = v['name'] ?? '';
                            final locale = v['locale'] ?? '';
                            final isSel = selected == name;
                            return ListTile(
                              leading: Icon(
                                isSel
                                    ? Icons.radio_button_checked
                                    : Icons.radio_button_unchecked,
                                color: isSel
                                    ? AppColors.primary
                                    : AppColors.textSecondary,
                              ),
                              title: Text(
                                name,
                                style: const TextStyle(
                                  color: AppColors.textPrimary,
                                ),
                              ),
                              subtitle: Text(
                                locale,
                                style: const TextStyle(
                                  color: AppColors.textSecondary,
                                  fontSize: 12,
                                ),
                              ),
                              onTap: () async {
                                cubit.setTtsVoiceForBook(
                                  widget.sourceId,
                                  widget.bookId,
                                  name,
                                );
                                // Push the override into the engine
                                // immediately so the next paragraph
                                // uses it without waiting for a chapter
                                // reload.
                                await sl<NovelTtsService>().setVoice(v);
                                if (context.mounted) Navigator.pop(context);
                              },
                            );
                          },
                        );
                      },
                    ),
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

/// Why a TTS reload is queued — drives the autoPlay decision when the
/// new chapter's body text finally arrives.
enum _TtsReloadReason { manual, autoAdvance }
