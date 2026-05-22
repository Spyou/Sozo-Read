import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import '../../../../core/widgets/app_snack.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:go_router/go_router.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../../../core/di/injection.dart';
import '../../../../core/models/book_detail.dart';
import '../../../../core/models/chapter.dart';
import '../../../../core/repository/downloads_repository.dart';
import '../../../../core/repository/library_repository.dart';
import '../../../../core/repository/provider_repository.dart';
import '../../../../core/state/manga_prefs_cubit.dart';
import '../../../../core/state/novel_prefs_cubit.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widgets/state_views.dart';
import '../../../settings/widgets/settings_dialogs.dart'
    show
        openMangaColorFilterSheet,
        openMangaImageQualitySheet,
        openMangaOrientationLockSheet,
        colorFilterLabel,
        imageQualityLabel,
        orientationLockLabel;
import '../../widgets/reading_bg_picker_sheet.dart';
import '../bloc/manga_reader_bloc.dart';
import '../bloc/manga_reader_event.dart';
import '../bloc/manga_reader_state.dart';
import '../widgets/page_image.dart';

class MangaReaderScreen extends StatelessWidget {
  const MangaReaderScreen({
    super.key,
    required this.book,
    required this.chapterIndex,
    this.initialPageIndex,
  });

  final BookDetail book;
  final int chapterIndex;

  /// Optional — when navigating from a page bookmark, the reader jumps
  /// to this page after the first pages-fetch completes. Overrides the
  /// library's last-progress resume.
  final int? initialPageIndex;

  @override
  Widget build(BuildContext context) {
    // Seed the reader's layout from the persisted MangaPrefs so the user's
    // global choice is honoured on every open. The in-reader pill row can
    // still override it for the current session.
    final mangaPrefs = sl<MangaPrefsCubit>().state;
    final initialMode = mangaPrefs.readingDirection == MangaReadingDirection.vertical
        ? ReaderMode.vertical
        : ReaderMode.horizontal;
    final initialDirection =
        mangaPrefs.readingDirection == MangaReadingDirection.horizontalRtl
            ? ReadingDirection.rtl
            : ReadingDirection.ltr;
    return MultiBlocProvider(
      providers: [
        BlocProvider.value(value: sl<NovelPrefsCubit>()),
        BlocProvider.value(value: sl<MangaPrefsCubit>()),
        BlocProvider(
          create: (_) => MangaReaderBloc(
            providerRepo: sl<ProviderRepository>(),
            libraryRepo: sl<LibraryRepository>(),
          )..add(MangaReaderStarted(
              book: book,
              chapterIndex: chapterIndex,
              initialMode: initialMode,
              initialDirection: initialDirection,
              initialPageIndex: initialPageIndex,
            )),
        ),
      ],
      child: const _ReaderView(),
    );
  }
}

class _ReaderView extends StatefulWidget {
  const _ReaderView();
  @override
  State<_ReaderView> createState() => _ReaderViewState();
}

class _ReaderViewState extends State<_ReaderView>
    with SingleTickerProviderStateMixin {
  bool _chromeVisible = true;
  final _scrollController = ScrollController();
  late final PageController _pageController = PageController();

  // Auto-scroll ticker — drives the vertical ScrollController at a constant
  // pixels-per-second rate while autoScroll != off. Null when disabled.
  Ticker? _autoScrollTicker;
  Duration _lastAutoTick = Duration.zero;
  MangaAutoScroll _autoScrollMode = MangaAutoScroll.off;

  // Reactive speed read by the persistent ticker callback. Changing this
  // while the ticker is running takes effect on the next frame.
  double _autoScrollPxPerSec = 0;
  // Counts consecutive frames where auto-scroll is stuck at maxScrollExtent.
  // After ~0.5s, fires the chapter advance.
  int _autoScrollEndFrames = 0;

  // Used to detect overscroll at end of chapter -> auto-advance.
  bool _autoAdvanceArmed = false;

  // Hardware volume-key navigation.
  bool _volumeListenerActive = false;
  double? _baselineVolume;
  bool _suppressNextVolumeEvent = false;
  StreamSubscription<NovelPrefs>? _prefsSub;
  StreamSubscription<MangaPrefs>? _mangaPrefsSub;
  StreamSubscription<MangaReaderState>? _readerStateSub;

  /// Last `sourceId::bookId` we evaluated auto-scroll for. Lets us
  /// detect when the bloc emits a new book (e.g. on initial load or a
  /// chapter-driven book swap) so we can re-look-up the per-book
  /// auto-scroll preference.
  String? _lastAutoScrollBookKey;

  // InteractiveViewer transformation controllers — one for vertical, one
  // for horizontal mode. Used to drive programmatic double-tap zoom.
  final _verticalTransform = TransformationController();
  final _horizontalTransform = TransformationController();
  Offset? _doubleTapPosition;

  // Page indicator overlay — visible briefly after each page change, even
  // when chrome is hidden. Acts as an "I'm not lost" affordance.
  bool _pageIndicatorVisible = false;
  Timer? _pageIndicatorTimer;
  int _lastIndicatedPage = -1;

  // Tracks the last-applied orientation lock so we can detect transitions.
  MangaOrientationLock? _appliedOrientation;
  bool _wakelockEnabled = false;

  @override
  void initState() {
    super.initState();
    _applyImmersive();
    final prefs = context.read<NovelPrefsCubit>();
    if (prefs.state.useVolumeButtons) {
      _installVolumeListener();
    }
    _prefsSub = prefs.stream.listen((p) {
      if (!mounted) return;
      if (p.useVolumeButtons && !_volumeListenerActive) {
        _installVolumeListener();
      } else if (!p.useVolumeButtons && _volumeListenerActive) {
        _uninstallVolumeListener();
      }
    });

    // Apply MangaPrefs side-effects (wakelock, orientation lock) once on
    // mount and keep them in sync as the user toggles in settings.
    final mangaPrefs = context.read<MangaPrefsCubit>();
    _applyKeepScreenOn(mangaPrefs.state.keepScreenOn);
    _applyOrientationLock(mangaPrefs.state.orientationLock);
    _applyAutoScroll(mangaPrefs.state);
    _mangaPrefsSub = mangaPrefs.stream.listen((p) {
      if (!mounted) return;
      _applyKeepScreenOn(p.keepScreenOn);
      _applyOrientationLock(p.orientationLock);
      _applyAutoScroll(p);
    });

    // Auto-scroll is per-book — when the bloc emits a new book (cold
    // load, or a chapter swap that crosses series boundaries), look up
    // its per-book preference and start/stop the ticker accordingly.
    final readerBloc = context.read<MangaReaderBloc>();
    _readerStateSub = readerBloc.stream.listen((s) {
      if (!mounted) return;
      final key = _bookKeyFromState(s);
      if (key == _lastAutoScrollBookKey) return;
      _lastAutoScrollBookKey = key;
      _applyAutoScroll(context.read<MangaPrefsCubit>().state);
    });
  }

  String? _bookKeyFromState(MangaReaderState s) {
    final b = s.book;
    if (b == null) return null;
    return MangaPrefsCubit.bookKey(b.sourceId, b.id);
  }

  @override
  void dispose() {
    _prefsSub?.cancel();
    _mangaPrefsSub?.cancel();
    _readerStateSub?.cancel();
    _pageIndicatorTimer?.cancel();
    _uninstallVolumeListener();
    // Always release the wakelock and restore default orientation so the
    // setting only applies while the reader is mounted.
    if (_wakelockEnabled) {
      // ignore: discarded_futures
      WakelockPlus.disable().catchError((_) {});
    }
    _autoScrollTicker?.dispose();
    SystemChrome.setPreferredOrientations(const []);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _scrollController.dispose();
    _pageController.dispose();
    _verticalTransform.dispose();
    _horizontalTransform.dispose();
    super.dispose();
  }

  Future<void> _applyKeepScreenOn(bool on) async {
    if (on == _wakelockEnabled) return;
    _wakelockEnabled = on;
    try {
      if (on) {
        await WakelockPlus.enable();
      } else {
        await WakelockPlus.disable();
      }
    } catch (_) {
      // Wakelock unsupported on this platform — no-op.
    }
  }

  /// Maps the continuous 0..1 [MangaPrefs.autoScrollSpeed] slider to a
  /// pixels-per-second value. 0 → ~15 px/s (very slow), 1 → ~300 px/s
  /// (fast). Used whenever auto-scroll is enabled, regardless of which
  /// preset bucket [MangaPrefs.autoScroll] sits in.
  double _autoScrollPxPerSecFromFraction(double f) {
    return 15.0 + 285.0 * f.clamp(0.0, 1.0);
  }

  /// Read the per-book auto-scroll opt-in for the bloc's current book.
  /// Returns false when no book has loaded yet so the ticker stays
  /// stopped during the cold-start window.
  bool _autoScrollEnabledForCurrentBook(MangaPrefs prefs) {
    final book = context.read<MangaReaderBloc>().state.book;
    if (book == null) return false;
    return prefs.autoScrollEnabledBooks
        .contains(MangaPrefsCubit.bookKey(book.sourceId, book.id));
  }

  /// Apply the current book's auto-scroll opt-in + the live speed
  /// slider. Listens to both the prefs stream and the bloc state stream
  /// so changes from either side (user toggling, or a new book loading)
  /// take effect immediately.
  void _applyAutoScroll(MangaPrefs prefs) {
    final enabled = _autoScrollEnabledForCurrentBook(prefs);
    // Live speed — picked up by the running ticker on every frame.
    _autoScrollPxPerSec =
        enabled ? _autoScrollPxPerSecFromFraction(prefs.autoScrollSpeed) : 0;

    // Map the per-book bool back onto the local preset enum so the rest
    // of the screen (FAB visibility, mode comparisons) keeps working
    // unchanged.
    final desiredMode = enabled ? MangaAutoScroll.medium : MangaAutoScroll.off;
    if (desiredMode == _autoScrollMode) return;
    _autoScrollMode = desiredMode;
    _autoScrollEndFrames = 0;
    if (!enabled) {
      _autoScrollTicker?.stop();
      return;
    }
    // SingleTickerProviderStateMixin only allows createTicker() to be called
    // ONCE per State — disposing and re-creating throws. So we lazy-create
    // once, then stop/start the same Ticker on every toggle.
    _autoScrollTicker ??= createTicker(_onAutoScrollTick);
    _lastAutoTick = Duration.zero;
    if (!_autoScrollTicker!.isActive) {
      _autoScrollTicker!.start();
    }
  }

  void _onAutoScrollTick(Duration elapsed) {
    // Paged/horizontal reader uses PageController, not ScrollController —
    // auto-scroll only makes sense for vertical/webtoon. The ScrollController
    // won't have clients there; we no-op those frames silently.
    if (!_scrollController.hasClients) {
      _lastAutoTick = elapsed;
      return;
    }
    final pos = _scrollController.position;

    // Pause while the user is actively dragging — otherwise the next frame
    // would yank them back. Reset the time baseline so when they release,
    // we resume from the current position without a giant catch-up jump.
    if (pos.userScrollDirection != ScrollDirection.idle) {
      _lastAutoTick = elapsed;
      _autoScrollEndFrames = 0;
      return;
    }

    if (pos.maxScrollExtent <= 0) {
      _lastAutoTick = elapsed;
      return;
    }

    final dtSec = (elapsed - _lastAutoTick).inMicroseconds / 1000000.0;
    _lastAutoTick = elapsed;
    if (dtSec <= 0) return;

    // If we're already pinned at the bottom, count frames — after ~0.5s
    // stuck, fire the chapter advance. Don't stop the ticker; once the
    // new chapter loads, ListView resets to 0 and ticker keeps going.
    if (pos.pixels >= pos.maxScrollExtent - 1) {
      _autoScrollEndFrames++;
      if (_autoScrollEndFrames >= 30) {
        _autoScrollEndFrames = 0;
        _autoScrollAdvanceChapter();
      }
      return;
    }
    _autoScrollEndFrames = 0;

    // Lazy-build means maxScrollExtent grows as we scroll. Clamp keeps us
    // from overshooting any single frame, but we do NOT stop the ticker
    // here — the next frame will see more extent available.
    final next = (pos.pixels + _autoScrollPxPerSec * dtSec)
        .clamp(0.0, pos.maxScrollExtent);
    _scrollController.jumpTo(next);
  }

  void _autoScrollAdvanceChapter() {
    if (!mounted) return;
    final bloc = context.read<MangaReaderBloc>();
    final state = bloc.state;
    // Next chapter is at chapterIndex - 1 (chapters stored newest-first).
    final nextIdx = state.chapterIndex - 1;
    if (nextIdx >= 0) {
      bloc.add(MangaReaderChapterChanged(nextIdx));
    }
  }

  void _applyOrientationLock(MangaOrientationLock lock) {
    if (_appliedOrientation == lock) return;
    _appliedOrientation = lock;
    switch (lock) {
      case MangaOrientationLock.auto:
        SystemChrome.setPreferredOrientations(const []);
        break;
      case MangaOrientationLock.portrait:
        SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.portraitUp,
        ]);
        break;
      case MangaOrientationLock.landscape:
        SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
        break;
    }
  }

  Future<void> _installVolumeListener() async {
    if (_volumeListenerActive) return;
    _volumeListenerActive = true;
    try {
      await FlutterVolumeController.updateShowSystemUI(false);
      _baselineVolume = await FlutterVolumeController.getVolume();
      FlutterVolumeController.addListener(_onVolumeChanged);
    } catch (_) {
      // Listener install failed (e.g. unsupported platform) — silently no-op.
      _volumeListenerActive = false;
    }
  }

  Future<void> _uninstallVolumeListener() async {
    if (!_volumeListenerActive) return;
    _volumeListenerActive = false;
    try {
      FlutterVolumeController.removeListener();
      await FlutterVolumeController.updateShowSystemUI(true);
    } catch (_) {
      // Ignore — we're tearing down.
    }
  }

  void _onVolumeChanged(double newVolume) {
    if (!mounted) return;
    if (_suppressNextVolumeEvent) {
      _suppressNextVolumeEvent = false;
      return;
    }
    final baseline = _baselineVolume ?? newVolume;
    // Compare with a small dead-zone to avoid jitter.
    final delta = newVolume - baseline;
    if (delta.abs() < 0.005) {
      _baselineVolume = newVolume;
      return;
    }
    final pressedUp = delta > 0;
    // Restore the OS volume so it doesn't drift after each press.
    _suppressNextVolumeEvent = true;
    // ignore: discarded_futures
    // System UI suppression is handled globally via updateShowSystemUI(false)
    // at install time; setVolume in 1.3.4 doesn't accept a per-call flag.
    FlutterVolumeController.setVolume(baseline).catchError((_) {});
    _baselineVolume = baseline;

    final state = context.read<MangaReaderBloc>().state;
    if (state.pages.isEmpty) return;
    if (pressedUp) {
      _advancePage(state, forward: true);
    } else {
      _advancePage(state, forward: false);
    }
  }

  void _advancePage(MangaReaderState state, {required bool forward}) {
    if (state.mode == ReaderMode.vertical) {
      if (!_scrollController.hasClients) return;
      final step = MediaQuery.of(context).size.height * 0.85;
      final pos = _scrollController.position;
      final target = (_scrollController.offset + (forward ? step : -step))
          .clamp(pos.minScrollExtent, pos.maxScrollExtent);
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    } else {
      if (!_pageController.hasClients) return;
      final current = state.pageIndex;
      // PageView with `reverse: true` already maps page index 0..N to RTL
      // reading order, so "next in reading order" is always `current + 1`.
      final target = (current + (forward ? 1 : -1))
          .clamp(0, state.pages.length - 1);
      if (target == current) return;
      _pageController.animateToPage(
        target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    }
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

  /// Resolves the active manga prefs, falling back to defaults if the cubit
  /// is unreachable (e.g. mid-rebuild during a hot reload). Reads happen
  /// often from hot paths so we keep it cheap.
  MangaPrefs _readMangaPrefs() {
    try {
      return context.read<MangaPrefsCubit>().state;
    } catch (_) {
      return const MangaPrefs(
        readingDirection: MangaReadingDirection.vertical,
        cropEdges: false,
        colorFilter: MangaColorFilter.none,
        autoScroll: MangaAutoScroll.off,
        imageQuality: MangaImageQuality.auto,
        orientationLock: MangaOrientationLock.auto,
        keepScreenOn: true,
        tapZoneNavigation: true,
      );
    }
  }

  void _handleTapUp(TapUpDetails details, MangaReaderState state) {
    final prefs = _readMangaPrefs();
    if (!prefs.tapZoneNavigation) {
      _toggleChrome();
      return;
    }
    final size = context.size ?? MediaQuery.of(context).size;
    if (state.mode == ReaderMode.vertical) {
      // Top / middle / bottom thirds. Top scrolls up, bottom scrolls down.
      final third = size.height / 3;
      final y = details.localPosition.dy;
      if (y < third) {
        _scrollByViewport(forward: false);
      } else if (y > size.height - third) {
        _scrollByViewport(forward: true);
      } else {
        _toggleChrome();
      }
    } else {
      // Left / middle / right thirds. Direction flips based on LTR/RTL.
      final third = size.width / 3;
      final x = details.localPosition.dx;
      final isRtl = state.direction == ReadingDirection.rtl;
      if (x < third) {
        if (isRtl) {
          _jumpToPage(state.pageIndex + 1, state.mode);
        } else {
          _jumpToPage(state.pageIndex - 1, state.mode);
        }
      } else if (x > size.width - third) {
        if (isRtl) {
          _jumpToPage(state.pageIndex - 1, state.mode);
        } else {
          _jumpToPage(state.pageIndex + 1, state.mode);
        }
      } else {
        _toggleChrome();
      }
    }
  }

  void _scrollByViewport({required bool forward}) {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    final step = MediaQuery.of(context).size.height * 0.85;
    final target = (_scrollController.offset + (forward ? step : -step))
        .clamp(pos.minScrollExtent, pos.maxScrollExtent);
    _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOut,
    );
  }

  void _onDoubleTapDown(TapDownDetails details) {
    _doubleTapPosition = details.localPosition;
  }

  void _handleDoubleTap(ReaderMode mode) {
    final controller =
        mode == ReaderMode.vertical ? _verticalTransform : _horizontalTransform;
    // If already zoomed in, reset. Otherwise zoom 2x centered on the tap.
    final current = controller.value.getMaxScaleOnAxis();
    if (current > 1.01) {
      controller.value = Matrix4.identity();
      return;
    }
    final pos = _doubleTapPosition ??
        Offset(
          MediaQuery.of(context).size.width / 2,
          MediaQuery.of(context).size.height / 2,
        );
    const zoom = 2.0;
    final matrix = Matrix4.identity()
      ..translateByDouble(
        -pos.dx * (zoom - 1),
        -pos.dy * (zoom - 1),
        0,
        1,
      )
      ..scaleByDouble(zoom, zoom, 1, 1);
    controller.value = matrix;
  }

  /// Show the page-number pill for ~2 seconds. Called whenever the bloc
  /// emits a new pageIndex.
  void _flashPageIndicator(int page) {
    if (page == _lastIndicatedPage && _pageIndicatorVisible) return;
    _lastIndicatedPage = page;
    setState(() => _pageIndicatorVisible = true);
    _pageIndicatorTimer?.cancel();
    _pageIndicatorTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      setState(() => _pageIndicatorVisible = false);
    });
  }

  /// Cycles through reading directions on the top-bar quick-toggle.
  void _cycleReadingDirection() {
    final cubit = context.read<MangaPrefsCubit>();
    final current = cubit.state.readingDirection;
    final next = switch (current) {
      MangaReadingDirection.vertical => MangaReadingDirection.horizontalLtr,
      MangaReadingDirection.horizontalLtr => MangaReadingDirection.horizontalRtl,
      MangaReadingDirection.horizontalRtl => MangaReadingDirection.vertical,
    };
    cubit.setDirection(next);
    // Mirror the change into the reader bloc so the on-screen layout
    // re-renders without waiting for the user to re-enter the screen.
    final bloc = context.read<MangaReaderBloc>();
    final targetMode = next == MangaReadingDirection.vertical
        ? ReaderMode.vertical
        : ReaderMode.horizontal;
    bloc.add(MangaReaderModeSet(targetMode));
    if (targetMode == ReaderMode.horizontal) {
      final desired = next == MangaReadingDirection.horizontalRtl
          ? ReadingDirection.rtl
          : ReadingDirection.ltr;
      if (bloc.state.direction != desired) {
        bloc.add(const MangaReaderDirectionToggled());
      }
    }
  }

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
        listenWhen: (a, b) =>
            a.chapterIndex != b.chapterIndex ||
            a.pageIndex != b.pageIndex ||
            (a.pendingResumeProgress != b.pendingResumeProgress) ||
            (a.status != b.status),
        listener: (ctx, state) {
          // Reset scrollers + zoom when a new chapter starts loading.
          if (state.status == ReaderStatus.loading) {
            if (_scrollController.hasClients) _scrollController.jumpTo(0);
            if (_pageController.hasClients) _pageController.jumpToPage(0);
            _verticalTransform.value = Matrix4.identity();
            _horizontalTransform.value = Matrix4.identity();
          }
          // Flash the page-number indicator on every page change.
          if (state.pages.isNotEmpty) {
            _flashPageIndicator(state.pageIndex);
          }
          // Apply pending resume once pages are loaded.
          if (state.status == ReaderStatus.success &&
              state.pendingResumeProgress != null &&
              state.pages.isNotEmpty) {
            final frac = state.pendingResumeProgress!.clamp(0.0, 1.0);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              if (state.mode == ReaderMode.vertical) {
                if (_scrollController.hasClients) {
                  final max = _scrollController.position.maxScrollExtent;
                  if (max > 0) {
                    _scrollController.jumpTo(max * frac);
                  }
                }
              } else {
                if (_pageController.hasClients) {
                  final target =
                      (frac * (state.pages.length - 1)).round().clamp(
                            0,
                            state.pages.length - 1,
                          );
                  _pageController.jumpToPage(target);
                }
              }
              ctx
                  .read<MangaReaderBloc>()
                  .add(const MangaReaderResumeConsumed());
            });
          }
        },
        builder: (context, state) {
          final bgMode = context.watch<NovelPrefsCubit>().state.backgroundMode;
          final total = state.pages.length;
          final hasPages = total > 0;
          final book = state.book;
          // The "next chapter" — list is descending so newer = lower index.
          final nextChapterIndex = state.chapterIndex - 1;
          final hasNextChapter = book != null &&
              nextChapterIndex >= 0 &&
              nextChapterIndex < book.chapters.length;
          final nextChapterTitle = hasNextChapter
              ? book.chapters[nextChapterIndex].title
              : null;
          return Stack(
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (d) => _handleTapUp(d, state),
                onDoubleTapDown: _onDoubleTapDown,
                onDoubleTap: () => _handleDoubleTap(state.mode),
                child: _PageContent(
                  state: state,
                  bgMode: bgMode,
                  scrollController: _scrollController,
                  pageController: _pageController,
                  verticalTransform: _verticalTransform,
                  horizontalTransform: _horizontalTransform,
                  hasNextChapter: hasNextChapter,
                  nextChapterTitle: nextChapterTitle,
                  nextChapterIndex: nextChapterIndex,
                  onOpenNextChapter: hasNextChapter
                      ? () => context
                          .read<MangaReaderBloc>()
                          .add(MangaReaderChapterChanged(nextChapterIndex))
                      : null,
                  onArmAutoAdvance: () => _autoAdvanceArmed = true,
                  onTryAutoAdvance: () {
                    if (!_autoAdvanceArmed) return;
                    _autoAdvanceArmed = false;
                    if (book == null) return;
                    if (hasNextChapter) {
                      context
                          .read<MangaReaderBloc>()
                          .add(MangaReaderChapterChanged(nextChapterIndex));
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

              // Floating auto-scroll entry point. Draggable within the
              // reader screen bounds; tap opens the auto-scroll sheet
              // (speed slider). Gated on `showFloatingAutoScroll` so
              // users who don't want the button on-screen can hide it
              // from the reader settings sheet.
              if (state.mode == ReaderMode.vertical &&
                  _autoScrollMode != MangaAutoScroll.off &&
                  context
                      .watch<MangaPrefsCubit>()
                      .state
                      .showFloatingAutoScroll)
                Positioned.fill(
                  child: _DraggableAutoScrollFab(
                    onTap: _openAutoScrollSheet,
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
                  onMarkComplete: () => _markCompleted(state),
                  onCycleDirection: _cycleReadingDirection,
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

              // Page-number affordance — visible even when chrome is hidden.
              if (hasPages)
                Positioned(
                  right: 14,
                  bottom: 24,
                  child: IgnorePointer(
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 240),
                      opacity: _pageIndicatorVisible ? 1.0 : 0.0,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Text(
                          '${state.pageIndex.clamp(0, total - 1) + 1} / $total',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

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
    // Capture the bloc + cubit BEFORE the modal pushes its own context — the
    // modal builds in the root Overlay, outside this screen's provider tree,
    // so we have to re-expose them via BlocProvider.value.
    final bloc = context.read<MangaReaderBloc>();
    final prefs = context.read<NovelPrefsCubit>();
    final mangaPrefs = context.read<MangaPrefsCubit>();
    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return MultiBlocProvider(
          providers: [
            BlocProvider.value(value: bloc),
            BlocProvider.value(value: prefs),
            BlocProvider.value(value: mangaPrefs),
          ],
          child: BlocBuilder<MangaReaderBloc, MangaReaderState>(
            builder: (_, s) => _ReaderSettingsSheet(state: s, bloc: bloc),
          ),
        );
      },
    );
  }

  /// Opens the dedicated auto-scroll bottom sheet — Enable toggle,
  /// continuous speed slider, and the "show floating control" checkbox.
  /// Same prefs cubit drives the sheet and the runtime, so dragging
  /// the slider tunes the active ticker in real time.
  Future<void> _openAutoScrollSheet() async {
    final mangaPrefs = context.read<MangaPrefsCubit>();
    final book = context.read<MangaReaderBloc>().state.book;
    // No book = no sheet (auto-scroll is per-book; nothing meaningful
    // to toggle). The FAB shouldn't be visible in this state anyway,
    // but guard defensively.
    if (book == null) return;
    final sourceId = book.sourceId;
    final bookId = book.id;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: false,
      builder: (ctx) {
        return BlocProvider.value(
          value: mangaPrefs,
          child: _AutoScrollSheet(sourceId: sourceId, bookId: bookId),
        );
      },
    );
  }

  /// Marks the current book as Completed and bounces back to the detail
  /// screen. Single-tap with Undo — the snackbar action restores the
  /// previous status if the user mis-tapped.
  Future<void> _markCompleted(MangaReaderState state) async {
    final book = state.book;
    if (book == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final library = sl<LibraryRepository>();
    final prev = library.get(book.sourceId, book.id)?.status;
    await library.setStatus(
      book.sourceId,
      book.id,
      LibraryStatus.completed,
    );
    if (!mounted) return;
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
    if (context.canPop()) context.pop();
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
          child: SingleChildScrollView(
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

              const SizedBox(height: 16),
              _SectionLabel('Background'),
              const SizedBox(height: 8),
              BlocBuilder<NovelPrefsCubit, NovelPrefs>(
                builder: (context, prefs) => ReadingBgPicker(
                  value: prefs.backgroundMode,
                  onChanged: (m) =>
                      context.read<NovelPrefsCubit>().setBackgroundMode(m),
                ),
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

              const SizedBox(height: 18),
              BlocBuilder<NovelPrefsCubit, NovelPrefs>(
                builder: (context, prefs) => _SheetSwitchRow(
                  icon: Icons.volume_up_rounded,
                  label: 'Volume buttons',
                  value: prefs.useVolumeButtons,
                  onChanged: (v) => context
                      .read<NovelPrefsCubit>()
                      .setUseVolumeButtons(v),
                ),
              ),

              const SizedBox(height: 18),
              _SectionLabel('Reading'),
              const SizedBox(height: 4),
              BlocBuilder<MangaPrefsCubit, MangaPrefs>(
                builder: (context, mp) {
                  final cubit = context.read<MangaPrefsCubit>();
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _SheetSwitchRow(
                        icon: Icons.touch_app_outlined,
                        label: 'Tap zones',
                        value: mp.tapZoneNavigation,
                        onChanged: cubit.setTapZoneNavigation,
                      ),
                      _SheetSwitchRow(
                        icon: Icons.lightbulb_outline,
                        label: 'Keep screen on',
                        value: mp.keepScreenOn,
                        onChanged: cubit.setKeepScreenOn,
                      ),
                      _SheetSwitchRow(
                        icon: Icons.crop_rounded,
                        label: 'Crop edges',
                        value: mp.cropEdges,
                        onChanged: cubit.setCropEdges,
                      ),
                      _SheetPickerRow(
                        icon: Icons.color_lens_outlined,
                        label: 'Color filter',
                        valueLabel: colorFilterLabel(mp.colorFilter),
                        onTap: () =>
                            openMangaColorFilterSheet(context, mp.colorFilter),
                      ),
                      // Auto-scroll is per-book: the toggle below
                      // writes to `mp.autoScrollEnabledBooks` keyed by
                      // the current `sourceId::bookId`. Opening a
                      // different series later won't carry the toggle
                      // — each book remembers its own state.
                      if (state.book != null)
                        Builder(builder: (_) {
                          final book = state.book!;
                          final enabled = mp.autoScrollEnabledBooks.contains(
                              MangaPrefsCubit.bookKey(
                                  book.sourceId, book.id));
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _SheetSwitchRow(
                                icon: Icons.play_circle_outline_rounded,
                                label: 'Auto-scroll',
                                value: enabled,
                                onChanged: (v) => cubit.setAutoScrollForBook(
                                  book.sourceId,
                                  book.id,
                                  v,
                                ),
                              ),
                              // Companion toggle for the draggable
                              // floating button. Stays global — a user
                              // who hides the button can re-enable it
                              // from here even if the floating control
                              // (the only other entry point) is gone.
                              if (enabled)
                                _SheetSwitchRow(
                                  icon: Icons.drag_indicator_rounded,
                                  label: 'Floating control',
                                  value: mp.showFloatingAutoScroll,
                                  onChanged: cubit.setShowFloatingAutoScroll,
                                ),
                            ],
                          );
                        }),
                      _SheetPickerRow(
                        icon: Icons.high_quality_outlined,
                        label: 'Image quality',
                        valueLabel: imageQualityLabel(mp.imageQuality),
                        onTap: () =>
                            openMangaImageQualitySheet(context, mp.imageQuality),
                      ),
                      _SheetPickerRow(
                        icon: Icons.screen_rotation_rounded,
                        label: 'Lock orientation',
                        valueLabel: orientationLockLabel(mp.orientationLock),
                        onTap: () => openMangaOrientationLockSheet(
                            context, mp.orientationLock),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
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

class _SheetSwitchRow extends StatelessWidget {
  const _SheetSwitchRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
  });
  final IconData icon;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(icon, color: AppColors.textSecondary, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Switch.adaptive(
            value: value,
            activeTrackColor: AppColors.primary,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class _SheetPickerRow extends StatelessWidget {
  const _SheetPickerRow({
    required this.icon,
    required this.label,
    required this.valueLabel,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final String valueLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Icon(icon, color: AppColors.textSecondary, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              valueLabel,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
              ),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right_rounded,
                color: AppColors.textTertiary, size: 18),
          ],
        ),
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

class _NoPagesView extends StatelessWidget {
  const _NoPagesView({
    required this.subtitle,
    required this.canNext,
    required this.onNext,
  });
  final String subtitle;
  final bool canNext;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.image_not_supported_outlined,
                size: 56, color: AppColors.textTertiary),
            const SizedBox(height: 14),
            const Text(
              'This chapter has no pages',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: () => context.pop(),
                  icon: const Icon(Icons.arrow_back, size: 16),
                  label: const Text('Back'),
                ),
                const SizedBox(width: 10),
                ElevatedButton.icon(
                  onPressed: canNext ? onNext : null,
                  icon: const Icon(Icons.skip_next, size: 16),
                  label: const Text('Next chapter'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PageContent extends StatelessWidget {
  const _PageContent({
    required this.state,
    required this.bgMode,
    required this.scrollController,
    required this.pageController,
    required this.verticalTransform,
    required this.horizontalTransform,
    required this.hasNextChapter,
    required this.nextChapterTitle,
    required this.nextChapterIndex,
    required this.onOpenNextChapter,
    required this.onArmAutoAdvance,
    required this.onTryAutoAdvance,
  });
  final MangaReaderState state;
  final ReadingBgMode bgMode;
  final ScrollController scrollController;
  final PageController pageController;
  final TransformationController verticalTransform;
  final TransformationController horizontalTransform;
  final bool hasNextChapter;
  final String? nextChapterTitle;
  final int nextChapterIndex;
  final VoidCallback? onOpenNextChapter;
  final VoidCallback onArmAutoAdvance;
  final VoidCallback onTryAutoAdvance;

  @override
  Widget build(BuildContext context) {
    if (state.status == ReaderStatus.loading) return const LoadingView();
    final book = state.book;
    final hasPages = state.pages.isNotEmpty;
    if (!hasPages &&
        (state.status == ReaderStatus.error ||
            state.status == ReaderStatus.success)) {
      final canNext = book != null && state.chapterIndex - 1 >= 0;
      return _NoPagesView(
        subtitle: state.error ?? 'Try another chapter or source',
        canNext: canNext,
        onNext: canNext
            ? () => context
                .read<MangaReaderBloc>()
                .add(MangaReaderChapterChanged(state.chapterIndex - 1))
            : null,
      );
    }
    if (state.status == ReaderStatus.error) {
      return ErrorView(
        message: state.error ?? 'Failed to load pages',
        onRetry: () => context
            .read<MangaReaderBloc>()
            .add(MangaReaderChapterChanged(state.chapterIndex)),
      );
    }

    if (state.mode == ReaderMode.vertical) {
      return _VerticalReader(
        state: state,
        bgMode: bgMode,
        controller: scrollController,
        transform: verticalTransform,
        hasNextChapter: hasNextChapter,
        nextChapterTitle: nextChapterTitle,
        onOpenNextChapter: onOpenNextChapter,
        onArm: onArmAutoAdvance,
        onTryAdvance: onTryAutoAdvance,
      );
    }
    return _HorizontalReader(
      state: state,
      controller: pageController,
      transform: horizontalTransform,
      hasNextChapter: hasNextChapter,
      nextChapterTitle: nextChapterTitle,
      onOpenNextChapter: onOpenNextChapter,
    );
  }
}

/// Resolves the user's `MangaFitMode` preference into a concrete
/// [BoxFit]. `fitHeight` inside a lazy ListView (vertical reader)
/// breaks layout, so we silently fall back to `fitWidth` there — the
/// settings sheet hides the option in that mode too, but this guard
/// keeps things safe if the pref was already persisted from horizontal
/// mode.
BoxFit _resolveFit(MangaFitMode mode, {required bool isVertical}) {
  switch (mode) {
    case MangaFitMode.fitWidth:
      return BoxFit.fitWidth;
    case MangaFitMode.fitHeight:
      return isVertical ? BoxFit.fitWidth : BoxFit.fitHeight;
    case MangaFitMode.fitScreen:
      return BoxFit.contain;
  }
}

class _VerticalReader extends StatelessWidget {
  const _VerticalReader({
    required this.state,
    required this.bgMode,
    required this.controller,
    required this.transform,
    required this.hasNextChapter,
    required this.nextChapterTitle,
    required this.onOpenNextChapter,
    required this.onArm,
    required this.onTryAdvance,
  });
  final MangaReaderState state;
  final ReadingBgMode bgMode;
  final ScrollController controller;
  final TransformationController transform;
  final bool hasNextChapter;
  final String? nextChapterTitle;
  final VoidCallback? onOpenNextChapter;
  final VoidCallback onArm;
  final VoidCallback onTryAdvance;

  @override
  Widget build(BuildContext context) {
    final gap = ReadingBg.mangaGapFor(bgMode, context);
    final isLight = bgMode == ReadingBgMode.white || bgMode == ReadingBgMode.sepia;
    final footerText = isLight ? Colors.black38 : Colors.white38;
    final fit = _resolveFit(
      context.watch<MangaPrefsCubit>().state.fitMode,
      isVertical: true,
    );
    // The list has one trailing slot for the next-chapter preview card when
    // available; the bloc's pageIndex math still tracks page count only.
    final pageCount = state.pages.length;
    final itemCount = hasNextChapter ? pageCount + 1 : pageCount;
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n is ScrollUpdateNotification) {
          final max = n.metrics.maxScrollExtent;
          final total = state.pages.length;
          if (max > 0 && total > 0) {
            final frac = (n.metrics.pixels / max).clamp(0.0, 1.0);
            // Smooth-progress signal — fires on every scroll update so
            // the bottom slider tracks the user's scroll continuously.
            // Drives `chapterScrollFraction` in the bloc.
            context
                .read<MangaReaderBloc>()
                .add(MangaReaderScrollFractionUpdated(frac));
            // Discrete page-index signal — only fires on page-boundary
            // crossings. Drives the "X / Y" indicator and the mark-as-
            // read trigger that fires when the last image is reached.
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
      child: Container(
        color: gap,
        child: InteractiveViewer(
          transformationController: transform,
          minScale: 1,
          maxScale: 4,
          panEnabled: true,
          child: ListView.builder(
            controller: controller,
            cacheExtent: MediaQuery.of(context).size.height * 4,
            itemCount: itemCount,
            itemBuilder: (_, i) {
              if (i >= pageCount) {
                return _NextChapterCard(
                  title: nextChapterTitle ?? '',
                  onOpen: onOpenNextChapter,
                );
              }
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    PageImage(
                      page: state.pages[i],
                      sourceId: state.book?.sourceId ?? '',
                      bookId: state.book?.id ?? '',
                      chapterId: (state.book != null &&
                              state.chapterIndex >= 0 &&
                              state.chapterIndex <
                                  state.book!.chapters.length)
                          ? state.book!.chapters[state.chapterIndex].id
                          : '',
                      bookTitle: state.book?.title,
                      chapterTitle: (state.book != null &&
                              state.chapterIndex >= 0 &&
                              state.chapterIndex <
                                  state.book!.chapters.length)
                          ? state.book!.chapters[state.chapterIndex].title
                          : null,
                      pageIndex: i,
                      fit: fit,
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      color: gap,
                      child: Text(
                        '${i + 1} / $pageCount',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: footerText, fontSize: 11),
                      ),
                    ),
                  ],
                ),
              );
            },
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
    required this.transform,
    required this.hasNextChapter,
    required this.nextChapterTitle,
    required this.onOpenNextChapter,
  });
  final MangaReaderState state;
  final PageController controller;
  final TransformationController transform;
  final bool hasNextChapter;
  final String? nextChapterTitle;
  final VoidCallback? onOpenNextChapter;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;
    final fit = _resolveFit(
      context.watch<MangaPrefsCubit>().state.fitMode,
      isVertical: false,
    );
    final pageCount = state.pages.length;
    final itemCount = hasNextChapter ? pageCount + 1 : pageCount;
    return Stack(
      children: [
        PageView.builder(
          controller: controller,
          itemCount: itemCount,
          reverse: state.direction == ReadingDirection.rtl,
          onPageChanged: (i) {
            // Clamp page-change events to actual page range so the bloc
            // doesn't get a phantom pageIndex pointing at the trailing card.
            final clamped = i.clamp(0, pageCount - 1);
            context
                .read<MangaReaderBloc>()
                .add(MangaReaderPageChanged(clamped));
          },
          itemBuilder: (_, i) {
            if (i >= pageCount) {
              return _NextChapterCard(
                title: nextChapterTitle ?? '',
                onOpen: onOpenNextChapter,
              );
            }
            // Two-page spread when landscape — pair page i with page i+1
            // if available, else show page i alone.
            if (isLandscape && i + 1 < pageCount) {
              return InteractiveViewer(
                transformationController: transform,
                minScale: 1,
                maxScale: 4,
                panEnabled: true,
                child: Row(
                  children: [
                    Expanded(
                      child: Center(
                        child: PageImage(
                          page: state.pages[i],
                          sourceId: state.book?.sourceId ?? '',
                          bookId: state.book?.id ?? '',
                          chapterId: (state.book != null &&
                                  state.chapterIndex >= 0 &&
                                  state.chapterIndex <
                                      state.book!.chapters.length)
                              ? state.book!
                                  .chapters[state.chapterIndex].id
                              : '',
                          bookTitle: state.book?.title,
                          chapterTitle: (state.book != null &&
                                  state.chapterIndex >= 0 &&
                                  state.chapterIndex <
                                      state.book!.chapters.length)
                              ? state.book!
                                  .chapters[state.chapterIndex].title
                              : null,
                          pageIndex: i,
                          fit: fit,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Center(
                        child: PageImage(
                          page: state.pages[i + 1],
                          sourceId: state.book?.sourceId ?? '',
                          bookId: state.book?.id ?? '',
                          chapterId: (state.book != null &&
                                  state.chapterIndex >= 0 &&
                                  state.chapterIndex <
                                      state.book!.chapters.length)
                              ? state.book!
                                  .chapters[state.chapterIndex].id
                              : '',
                          bookTitle: state.book?.title,
                          chapterTitle: (state.book != null &&
                                  state.chapterIndex >= 0 &&
                                  state.chapterIndex <
                                      state.book!.chapters.length)
                              ? state.book!
                                  .chapters[state.chapterIndex].title
                              : null,
                          pageIndex: i + 1,
                          fit: fit,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }
            return InteractiveViewer(
              transformationController: transform,
              minScale: 1,
              maxScale: 4,
              panEnabled: true,
              child: Center(
                child: PageImage(
                  page: state.pages[i],
                  sourceId: state.book?.sourceId ?? '',
                  bookId: state.book?.id ?? '',
                  chapterId: (state.book != null &&
                          state.chapterIndex >= 0 &&
                          state.chapterIndex <
                              state.book!.chapters.length)
                      ? state.book!.chapters[state.chapterIndex].id
                      : '',
                  bookTitle: state.book?.title,
                  chapterTitle: (state.book != null &&
                          state.chapterIndex >= 0 &&
                          state.chapterIndex <
                              state.book!.chapters.length)
                      ? state.book!.chapters[state.chapterIndex].title
                      : null,
                  pageIndex: i,
                  fit: fit,
                ),
              ),
            );
          },
        ),
        // Tiny edge hint while controls are hidden — show direction arrows
        // briefly on first page entry. Subtle; doesn't intrude.
        if (state.pageIndex == 0)
          Positioned(
            left: 8,
            top: 0,
            bottom: 0,
            child: IgnorePointer(
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
          ),
      ],
    );
  }
}

class _NextChapterCard extends StatelessWidget {
  const _NextChapterCard({required this.title, required this.onOpen});
  final String title;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      alignment: Alignment.center,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 360),
        padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: AppColors.textTertiary.withValues(alpha: 0.18),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Up next',
              style: TextStyle(
                color: AppColors.textTertiary,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: onOpen,
                icon: const Icon(Icons.play_arrow_rounded, size: 18),
                label: const Text('Open'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.state,
    required this.onBack,
    required this.onOpenChapters,
    required this.onOpenSettings,
    required this.onMarkComplete,
    required this.onCycleDirection,
  });
  final MangaReaderState state;
  final VoidCallback onBack;
  final VoidCallback onOpenChapters;
  final VoidCallback onOpenSettings;
  final VoidCallback onMarkComplete;
  final VoidCallback onCycleDirection;

  @override
  Widget build(BuildContext context) {
    final book = state.book;
    final chapter = (book != null && book.chapters.isNotEmpty)
        ? book.chapters[state.chapterIndex].title
        : '';
    // Pick the direction icon from the persisted preference so it stays in
    // sync with what the next reader-open will use, not just the current
    // session's bloc state.
    final prefs = context.watch<MangaPrefsCubit>().state;
    final IconData dirIcon = switch (prefs.readingDirection) {
      MangaReadingDirection.vertical => Icons.swap_vert_rounded,
      MangaReadingDirection.horizontalLtr => Icons.east_rounded,
      MangaReadingDirection.horizontalRtl => Icons.west_rounded,
    };
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
                    // Most-used actions stay visible. Direction toggle,
                    // download, and mark-complete live in the overflow
                    // menu so the top bar doesn't squeeze the title.
                    IconButton(
                      tooltip: 'Chapters',
                      icon: const Icon(Icons.list, color: Colors.white),
                      onPressed: onOpenChapters,
                    ),
                    // Auto-scroll lives in the reader settings sheet
                    // (Reading section) and surfaces as a draggable
                    // floating button on the reader once enabled — no
                    // top-bar entry point.
                    IconButton(
                      tooltip: 'Settings',
                      icon: const Icon(Icons.tune_rounded, color: Colors.white),
                      onPressed: onOpenSettings,
                    ),
                    PopupMenuButton<_TopBarAction>(
                      tooltip: 'More',
                      color: const Color(0xFF1A1A1A),
                      icon: const Icon(Icons.more_vert, color: Colors.white),
                      onSelected: (action) {
                        switch (action) {
                          case _TopBarAction.cycleDirection:
                            onCycleDirection();
                            break;
                          case _TopBarAction.download:
                            if (book != null &&
                                state.chapterIndex >= 0 &&
                                state.chapterIndex < book.chapters.length) {
                              _ReaderDownloadButton.start(
                                context,
                                book,
                                book.chapters[state.chapterIndex],
                              );
                            }
                            break;
                          case _TopBarAction.markComplete:
                            onMarkComplete();
                            break;
                        }
                      },
                      itemBuilder: (context) => [
                        PopupMenuItem(
                          value: _TopBarAction.cycleDirection,
                          child: Row(
                            children: [
                              Icon(dirIcon, color: Colors.white70, size: 20),
                              const SizedBox(width: 12),
                              const Text(
                                'Reading direction',
                                style: TextStyle(color: Colors.white),
                              ),
                            ],
                          ),
                        ),
                        if (book != null &&
                            state.chapterIndex >= 0 &&
                            state.chapterIndex < book.chapters.length)
                          PopupMenuItem(
                            value: _TopBarAction.download,
                            child: _DownloadMenuRow(
                              book: book,
                              chapter: book.chapters[state.chapterIndex],
                            ),
                          ),
                        const PopupMenuItem(
                          value: _TopBarAction.markComplete,
                          child: Row(
                            children: [
                              Icon(Icons.task_alt_rounded,
                                  color: Colors.white70, size: 20),
                              SizedBox(width: 12),
                              Text(
                                'Mark as completed',
                                style: TextStyle(color: Colors.white),
                              ),
                            ],
                          ),
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

/// Top-bar download trigger for the chapter currently being read. Mirrors
/// the icon-state logic from the detail screen's chapter list.
/// Actions surfaced through the top-bar overflow menu. Kept as an enum so
/// `PopupMenuButton.onSelected` is type-checked at the call site.
enum _TopBarAction { cycleDirection, download, markComplete }

/// Compact row used inside the top-bar overflow menu's "Download chapter"
/// entry. Mirrors the status states of [_ReaderDownloadButton] but renders
/// inline next to the menu label so the user can see at a glance whether
/// the chapter is already saved.
class _DownloadMenuRow extends StatelessWidget {
  const _DownloadMenuRow({required this.book, required this.chapter});

  final BookDetail book;
  final Chapter chapter;

  @override
  Widget build(BuildContext context) {
    final repo = sl<DownloadsRepository>();
    return StreamBuilder<DownloadEntry>(
      stream: repo.watch(book.sourceId, book.id, chapter.id),
      builder: (context, snap) {
        final entry =
            snap.data ?? repo.get(book.sourceId, book.id, chapter.id);
        final isDeleted = entry?.error == '__deleted__';
        final effective = isDeleted ? null : entry;
        final (IconData icon, String label) = switch (effective?.status) {
          null => (Icons.download_for_offline_outlined, 'Download chapter'),
          DownloadStatus.queued ||
          DownloadStatus.downloading =>
            (Icons.cloud_download_outlined, 'Downloading…'),
          // Paused: render as a tap-to-resume target. Agent A will refine
          // the UX; this just keeps the menu compiling + functional.
          DownloadStatus.paused =>
            (Icons.pause_circle_outline, 'Paused — tap to resume'),
          DownloadStatus.done => (Icons.check_circle, 'Downloaded'),
          DownloadStatus.failed => (Icons.error_outline, 'Retry download'),
        };
        return Row(
          children: [
            Icon(icon, color: Colors.white70, size: 20),
            const SizedBox(width: 12),
            Text(label, style: const TextStyle(color: Colors.white)),
          ],
        );
      },
    );
  }
}

class _ReaderDownloadButton extends StatelessWidget {
  const _ReaderDownloadButton({required this.book, required this.chapter});

  final BookDetail book;
  final Chapter chapter;

  /// Shared download trigger — used by the standalone IconButton AND by
  /// the overflow menu so both paths kick the same enqueue flow.
  static Future<void> start(
    BuildContext context,
    BookDetail book,
    Chapter chapter,
  ) async {
    final repo = sl<DownloadsRepository>();
    final providerRepo = sl<ProviderRepository>();
    final dio = sl<Dio>();
    final messenger = ScaffoldMessenger.of(context);
    final pagesRes = await providerRepo.pages(book.sourceId, chapter.url);
    if (!context.mounted) return;
    pagesRes.fold(
      (f) => messenger.showAppSnack(
        SnackBar(content: Text('Failed to fetch pages: ${f.message}')),
      ),
      (pages) {
        if (pages.isEmpty) {
          messenger.showAppSnack(
            const SnackBar(content: Text('No pages to download')),
          );
          return;
        }
        // ignore: discarded_futures
        repo.enqueue(book, chapter, pages, dio);
        messenger.showAppSnack(
          SnackBar(content: Text('Downloading ${chapter.title}…')),
        );
      },
    );
  }

  Future<void> _start(BuildContext context) => start(context, book, chapter);

  @override
  Widget build(BuildContext context) {
    final repo = sl<DownloadsRepository>();
    return StreamBuilder<DownloadEntry>(
      stream: repo.watch(book.sourceId, book.id, chapter.id),
      builder: (context, snap) {
        final entry = snap.data ?? repo.get(book.sourceId, book.id, chapter.id);
        final isDeleted = entry?.error == '__deleted__';
        final effective = isDeleted ? null : entry;
        if (effective == null) {
          return IconButton(
            tooltip: 'Download chapter',
            icon: const Icon(Icons.download_for_offline_outlined,
                color: Colors.white),
            onPressed: () => _start(context),
          );
        }
        switch (effective.status) {
          case DownloadStatus.queued:
          case DownloadStatus.downloading:
            return const IconButton(
              tooltip: 'Downloading',
              icon: Icon(Icons.cloud_download_outlined, color: Colors.white),
              onPressed: null,
            );
          // Paused entries get a resume tap target. Agent A will replace
          // this with a richer pause/resume affordance later.
          case DownloadStatus.paused:
            return IconButton(
              tooltip: 'Resume download',
              icon: const Icon(Icons.play_circle_outline, color: Colors.white),
              onPressed: () => sl<DownloadsRepository>()
                  .resume(book.sourceId, book.id, chapter.id),
            );
          case DownloadStatus.done:
            return const IconButton(
              tooltip: 'Downloaded',
              icon: Icon(Icons.check_circle, color: Colors.white),
              onPressed: null,
            );
          case DownloadStatus.failed:
            return IconButton(
              tooltip: 'Retry download',
              icon: const Icon(Icons.error_outline, color: Colors.white),
              onPressed: () => _start(context),
            );
        }
      },
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
                      // Vertical mode uses the live scroll fraction so
                      // the slider fills smoothly for manhwa (few long
                      // strips → previously jumped 12-25% per page).
                      // Paged mode keeps the discrete-page slider.
                      _PageSlider(
                        current: state.mode == ReaderMode.vertical
                            ? state.chapterScrollFraction * (total - 1)
                            : pageIndex.toDouble(),
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

  /// Continuous position along the slider in `[0, total - 1]`. Vertical
  /// mode passes the smooth scroll fraction scaled by `(total - 1)`;
  /// paged mode passes the integer page index cast to double.
  final double current;
  final int total;
  final ValueChanged<double> onChange;

  @override
  Widget build(BuildContext context) {
    final maxVal = (total - 1).toDouble();
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
        max: maxVal,
        value: current.clamp(0.0, maxVal),
        onChanged: onChange,
      ),
    );
  }
}

/// Bottom sheet driving auto-scroll for the current book. Enable
/// toggles per-book; the speed slider and floating-control checkbox
/// stay global (the slider tunes the running ticker live).
class _AutoScrollSheet extends StatelessWidget {
  const _AutoScrollSheet({required this.sourceId, required this.bookId});
  final String sourceId;
  final String bookId;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<MangaPrefsCubit, MangaPrefs>(
      builder: (context, prefs) {
        final cubit = context.read<MangaPrefsCubit>();
        final enabled = prefs.autoScrollEnabledBooks
            .contains(MangaPrefsCubit.bookKey(sourceId, bookId));
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
                        tooltip: 'Close',
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

/// Single-icon circular button that overlays the reader whenever
/// auto-scroll is enabled. Draggable within the reader screen bounds;
/// tapping opens the [_AutoScrollSheet] for live speed tuning.
///
/// Smoothness notes:
///   * Position is held in a [ValueNotifier] so dragging doesn't trigger
///     a [State.setState] / `LayoutBuilder` rebuild of the whole subtree
///     every frame — only the inner [ValueListenableBuilder] rebuilds,
///     and that wraps just the [Positioned] re-parent-data hop.
///   * The visual uses a const [Container] with a [BoxDecoration] shadow
///     instead of a [Material] with `elevation: 4`. `Material` shadow
///     rasterisation showed up as the main cost on pan ticks.
///   * Bounds come from the parent constraints once (via [LayoutBuilder]
///     at the outermost level only) so we don't re-resolve them every
///     drag frame.
class _DraggableAutoScrollFab extends StatefulWidget {
  const _DraggableAutoScrollFab({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_DraggableAutoScrollFab> createState() =>
      _DraggableAutoScrollFabState();
}

class _DraggableAutoScrollFabState extends State<_DraggableAutoScrollFab> {
  static const double _size = 44;
  static const double _margin = 16;

  final ValueNotifier<Offset?> _offset = ValueNotifier<Offset?>(null);

  @override
  void dispose() {
    _offset.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        // Default to lower-right, computed once. Subsequent rebuilds
        // (e.g. orientation change) keep the user's dragged position.
        if (_offset.value == null && w > _size && h > _size) {
          _offset.value = Offset(w - _size - _margin, h * 0.45);
        }
        final maxX = math.max(0.0, w - _size);
        final maxY = math.max(0.0, h - _size);
        // Transform.translate is paint-only — no Stack relayout per
        // frame, no parent-data churn. The icon also sits inside its
        // own RepaintBoundary so dragging doesn't invalidate the
        // manga-page layer underneath. Together these cut the per-frame
        // work from "relayout + repaint of the whole reader subtree"
        // down to "compositor reuses the FAB's existing layer at a new
        // transform offset" — what 60-90fps drag actually needs.
        return ValueListenableBuilder<Offset?>(
          valueListenable: _offset,
          builder: (context, o, child) {
            if (o == null) return const SizedBox.shrink();
            return Transform.translate(
              offset: o,
              child: Align(
                alignment: Alignment.topLeft,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  // Start the drag from the pointer-down location
                  // (default is `start`, which waits for the slop
                  // distance to be exceeded before the first
                  // onPanUpdate fires — that's what makes the first
                  // few millimetres of drag feel "stuck").
                  dragStartBehavior: DragStartBehavior.down,
                  onTap: widget.onTap,
                  onPanUpdate: (d) {
                    final next = o + d.delta;
                    _offset.value = Offset(
                      next.dx.clamp(0.0, maxX),
                      next.dy.clamp(0.0, maxY),
                    );
                  },
                  child: child,
                ),
              ),
            );
          },
          // Const so this subtree is never rebuilt when the offset
          // changes — Transform.translate is the only thing moving.
          child: const RepaintBoundary(child: _AutoScrollFabIcon()),
        );
      },
    );
  }
}

class _AutoScrollFabIcon extends StatelessWidget {
  const _AutoScrollFabIcon();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      decoration: const BoxDecoration(
        color: Color(0x8C000000),
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Color(0x55000000),
            blurRadius: 6,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: const Center(
        child: Icon(
          Icons.play_circle_rounded,
          color: AppColors.primary,
          size: 26,
        ),
      ),
    );
  }
}
