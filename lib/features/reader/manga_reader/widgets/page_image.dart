import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import '../../../../core/widgets/app_snack.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive/hive.dart';
import 'package:saver_gallery/saver_gallery.dart';

import '../../../../core/di/injection.dart';
import '../../../../core/models/page_content.dart';
import '../../../../core/repository/page_bookmarks_repository.dart';
import '../../../../core/state/manga_prefs_cubit.dart';
import '../../../../core/theme/app_colors.dart';

// Color matrices are top-level constants so they are evaluated once and shared
// across every PageImage instance — the manga reader builds hundreds of these
// per chapter, so we keep per-build work to a minimum.

const ColorFilter _sepiaFilter = ColorFilter.matrix(<double>[
  0.393, 0.769, 0.189, 0, 0, //
  0.349, 0.686, 0.168, 0, 0, //
  0.272, 0.534, 0.131, 0, 0, //
  0, 0, 0, 1, 0, //
]);

const ColorFilter _invertFilter = ColorFilter.matrix(<double>[
  -1, 0, 0, 0, 255, //
  0, -1, 0, 0, 255, //
  0, 0, -1, 0, 255, //
  0, 0, 0, 1, 0, //
]);

// Blue-light reduction — knocks the green/blue channels down to produce a
// warmer image, easier on the eyes at night.
const ColorFilter _blueLightFilter = ColorFilter.matrix(<double>[
  1, 0, 0, 0, 0, //
  0, 0.95, 0, 0, 0, //
  0, 0, 0.78, 0, 0, //
  0, 0, 0, 1, 0, //
]);

ColorFilter? _filterFor(MangaColorFilter value) {
  switch (value) {
    case MangaColorFilter.none:
      return null;
    case MangaColorFilter.sepia:
      return _sepiaFilter;
    case MangaColorFilter.invert:
      return _invertFilter;
    case MangaColorFilter.blueLight:
      return _blueLightFilter;
  }
}

/// Reads the current manga prefs without throwing if the cubit isn't
/// available in the widget tree (e.g. used outside the reader screen). Falls
/// back to a sensible default so callers never crash.
MangaPrefs _readPrefs(BuildContext context) {
  try {
    return context.watch<MangaPrefsCubit>().state;
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

/// Manga page image with retry-with-backoff and reader-prefs-aware rendering.
///
/// On load failure, automatically retries up to 3 times with exponential
/// backoff (500ms, 1000ms, 2000ms). If all auto-retries fail, a manual
/// "Retry" button is shown that evicts the URL from the network cache and
/// re-fetches just this page (without disturbing the rest of the chapter).
///
/// Applies user prefs from [MangaPrefsCubit] on every build:
///   * color filter (sepia / invert / blue-light reduction)
///   * crop edges (trims a fixed band off each side — see [_CropEdges])
///   * image quality (caps disk-cache resolution when set to `low`)
///
/// A long-press on the page opens a small bottom sheet with actions to save
/// the page to the device gallery, view it full-resolution in a pinch-zoom
/// dialog, or copy its URL to the clipboard.
class PageImage extends StatefulWidget {
  const PageImage({
    super.key,
    required this.page,
    required this.sourceId,
    required this.bookId,
    required this.chapterId,
    required this.pageIndex,
    this.fit = BoxFit.fitWidth,
  });

  final PageContent page;
  final String sourceId;
  final String bookId;
  final String chapterId;
  final int pageIndex;
  final BoxFit fit;

  @override
  State<PageImage> createState() => _PageImageState();
}

class _PageImageState extends State<PageImage> {
  static const int _maxAutoRetries = 3;
  static const List<Duration> _backoff = [
    Duration(milliseconds: 500),
    Duration(milliseconds: 1000),
    Duration(milliseconds: 2000),
  ];

  /// Counts loads attempted. Used both as a uniqueness key (to force
  /// CachedNetworkImage to rebuild) and to pick the backoff delay.
  int _attempt = 0;
  bool _scheduling = false;
  String? _lastError;
  Timer? _retryTimer;

  @override
  void dispose() {
    _retryTimer?.cancel();
    super.dispose();
  }

  void _scheduleRetry(String err) {
    if (_scheduling) return;
    if (_attempt >= _maxAutoRetries) return;
    _scheduling = true;
    final delay = _backoff[_attempt.clamp(0, _backoff.length - 1)];
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      if (!mounted) return;
      setState(() {
        _attempt += 1;
        _scheduling = false;
        _lastError = err;
      });
    });
  }

  /// Manual retry: evict the URL from the cache so we don't immediately
  /// re-serve the same failure, reset the attempt counter, and rebuild.
  Future<void> _manualRetry() async {
    _retryTimer?.cancel();
    try {
      await CachedNetworkImage.evictFromCache(widget.page.url);
    } catch (e) {
      debugPrint('PageImage evictFromCache failed: $e');
    }
    if (!mounted) return;
    setState(() {
      _attempt = 0;
      _scheduling = false;
      _lastError = null;
    });
  }

  Future<void> _openLongPressMenu() async {
    final url = widget.page.url;
    // Local-file URLs (offline-downloaded pages) don't make sense to
    // re-save or open via URL — skip the menu entirely.
    if (url.startsWith('file://') || url.startsWith('/')) return;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetCtx) {
        final pageRepo = sl<PageBookmarksRepository>();
        // Stream-watch inside the sheet so the bookmark row flips
        // instantly when toggled — no need to dismiss + reopen.
        return SafeArea(
          child: StreamBuilder<BoxEvent>(
            stream: pageRepo.watch(),
            builder: (sheetCtx2, _) {
              final bookmarked = pageRepo.isBookmarked(
                sourceId: widget.sourceId,
                bookId: widget.bookId,
                chapterId: widget.chapterId,
                pageIndex: widget.pageIndex,
              );
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 8),
                  Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.divider,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 8),
                  ListTile(
                    leading: Icon(
                      bookmarked
                          ? Icons.bookmark_remove_outlined
                          : Icons.bookmark_add_outlined,
                      color: AppColors.textPrimary,
                    ),
                    title: Text(
                      bookmarked
                          ? 'Bookmark added'
                          : 'Bookmark this page',
                      style: const TextStyle(color: AppColors.textPrimary),
                    ),
                    onTap: () => _togglePageBookmark(sheetCtx, bookmarked),
                  ),
                  ListTile(
                    leading: const Icon(Icons.save_alt,
                        color: AppColors.textPrimary),
                    title: const Text('Save image',
                        style: TextStyle(color: AppColors.textPrimary)),
                    onTap: () {
                      Navigator.pop(sheetCtx);
                      _saveImage();
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.zoom_out_map,
                        color: AppColors.textPrimary),
                    title: const Text('View full resolution',
                        style: TextStyle(color: AppColors.textPrimary)),
                    onTap: () {
                      Navigator.pop(sheetCtx);
                      _viewFullResolution();
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.link,
                        color: AppColors.textPrimary),
                    title: const Text('Copy image URL',
                        style: TextStyle(color: AppColors.textPrimary)),
                    onTap: () {
                      Navigator.pop(sheetCtx);
                      _copyUrl();
                    },
                  ),
                  const SizedBox(height: 8),
                ],
              );
            },
          ),
        );
      },
    );
  }

  Future<void> _togglePageBookmark(
    BuildContext sheetCtx,
    bool currentlyBookmarked,
  ) async {
    final repo = sl<PageBookmarksRepository>();
    final messenger = ScaffoldMessenger.of(context);
    if (currentlyBookmarked) {
      await repo.remove(
        sourceId: widget.sourceId,
        bookId: widget.bookId,
        chapterId: widget.chapterId,
        pageIndex: widget.pageIndex,
      );
      messenger.hideCurrentSnackBar();
      messenger.showAppSnack(
        const SnackBar(content: Text('Bookmark removed')),
      );
    } else {
      await repo.add(
        sourceId: widget.sourceId,
        bookId: widget.bookId,
        chapterId: widget.chapterId,
        pageIndex: widget.pageIndex,
        pageUrl: widget.page.url,
      );
      messenger.hideCurrentSnackBar();
      messenger.showAppSnack(
        SnackBar(content: Text('Bookmarked page ${widget.pageIndex + 1}')),
      );
    }
  }

  Future<void> _saveImage() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final dio = sl<Dio>();
      final res = await dio.get<List<int>>(
        widget.page.url,
        options: Options(
          responseType: ResponseType.bytes,
          // Some manga CDNs require the original Referer header set by the
          // provider — reuse the per-page headers (which contain Referer
          // + User-Agent overrides) so the request actually succeeds.
          headers: widget.page.headers,
        ),
      );
      final data = res.data;
      if (data == null || data.isEmpty) {
        throw StateError('Empty response body');
      }
      final bytes = Uint8List.fromList(data);
      final fileName =
          'sozo_manga_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final result = await SaverGallery.saveImage(
        bytes,
        fileName: fileName,
        androidRelativePath: 'Pictures/Sozo Manga',
        skipIfExists: false,
      );
      if (!mounted) return;
      if (result.isSuccess) {
        messenger.showAppSnack(
          const SnackBar(content: Text('Saved to gallery')),
        );
      } else {
        messenger.showAppSnack(
          SnackBar(
            content: Text('Save failed: ${result.errorMessage ?? 'unknown'}'),
          ),
        );
      }
    } catch (e) {
      debugPrint('PageImage save failed: $e');
      if (!mounted) return;
      messenger.showAppSnack(SnackBar(content: Text('Save failed: $e')));
    }
  }

  void _viewFullResolution() {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.92),
      builder: (dialogCtx) {
        return Dialog(
          insetPadding: EdgeInsets.zero,
          backgroundColor: Colors.transparent,
          elevation: 0,
          child: Stack(
            children: [
              // Tap anywhere outside the image to dismiss.
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => Navigator.of(dialogCtx).pop(),
                ),
              ),
              Center(
                child: InteractiveViewer(
                  minScale: 1,
                  maxScale: 5,
                  child: CachedNetworkImage(
                    imageUrl: widget.page.url,
                    httpHeaders: widget.page.headers,
                    fit: BoxFit.contain,
                    placeholder: (_, _) => const SizedBox(
                      width: 32,
                      height: 32,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: AppColors.primary),
                    ),
                    errorWidget: (_, _, _) => const Icon(
                      Icons.broken_image,
                      color: AppColors.textTertiary,
                      size: 48,
                    ),
                  ),
                ),
              ),
              Positioned(
                top: MediaQuery.of(dialogCtx).padding.top + 8,
                right: 8,
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.of(dialogCtx).pop(),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _copyUrl() async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: widget.page.url));
    if (!mounted) return;
    messenger.showAppSnack(
      const SnackBar(content: Text('Image URL copied')),
    );
  }

  /// Wraps [child] with the user's chosen color filter (if any) and the
  /// crop-edges trim (if enabled). Both transforms are cheap — they don't
  /// touch pixel data, just composit at draw time.
  Widget _applyTransforms(Widget child, MangaPrefs prefs) {
    Widget out = child;
    if (prefs.cropEdges) {
      out = _CropEdges(child: out);
    }
    final filter = _filterFor(prefs.colorFilter);
    if (filter != null) {
      out = ColorFiltered(colorFilter: filter, child: out);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final prefs = _readPrefs(context);
    final retrying = _scheduling && _attempt < _maxAutoRetries;
    final exhausted = _attempt >= _maxAutoRetries && _lastError != null;

    // Local-file fast-path: the manga reader bloc rewrites downloaded pages
    // with a `file://...` URL. Render with Image.file (no network, no cache).
    final url = widget.page.url;
    if (url.startsWith('file://') || url.startsWith('/')) {
      final path = url.startsWith('file://') ? url.substring(7) : url;
      final fileWidget = Image.file(
        File(path),
        fit: widget.fit,
        errorBuilder: (_, err, _) => AspectRatio(
          aspectRatio: 2 / 3,
          child: Container(
            color: AppColors.card,
            alignment: Alignment.center,
            child: const Icon(Icons.broken_image,
                color: AppColors.textTertiary, size: 36),
          ),
        ),
      );
      return GestureDetector(
        onLongPress: _openLongPressMenu,
        child: _applyTransforms(fileWidget, prefs),
      );
    }

    // Image quality cap. Sets disk-cache dimensions per setting. Note: only
    // affects fresh downloads — already-cached pages keep their original
    // resolution until cache is cleared, so switching quality on a chapter
    // you've already read won't visibly change anything.
    int? maxWidthDisk;
    int? maxHeightDisk;
    switch (prefs.imageQuality) {
      case MangaImageQuality.low:
        maxWidthDisk = 600;
        maxHeightDisk = 900;
        break;
      case MangaImageQuality.auto:
        maxWidthDisk = 1200;
        maxHeightDisk = 1800;
        break;
      case MangaImageQuality.high:
        // No cap — use original source resolution.
        break;
    }

    final networkImage = CachedNetworkImage(
      // Adding the attempt counter to the key forces a fresh image attempt
      // on each retry.
      key: ValueKey('${widget.page.url}#$_attempt'),
      imageUrl: widget.page.url,
      fit: widget.fit,
      httpHeaders: widget.page.headers,
      maxWidthDiskCache: maxWidthDisk,
      maxHeightDiskCache: maxHeightDisk,
      fadeInDuration: const Duration(milliseconds: 100),
      fadeOutDuration: Duration.zero,
      placeholder: (_, _) => AspectRatio(
        aspectRatio: 2 / 3,
        child: Container(
          color: AppColors.card,
          alignment: Alignment.center,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AppColors.primary),
              ),
              if (retrying) ...[
                const SizedBox(height: 10),
                Text(
                  'Retrying… (${_attempt + 1}/$_maxAutoRetries)',
                  style: const TextStyle(
                      color: AppColors.textTertiary, fontSize: 11),
                ),
              ],
            ],
          ),
        ),
      ),
      errorWidget: (_, url, err) {
        // Schedule the next retry on the next frame so we don't call
        // setState during build.
        if (!exhausted) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _scheduleRetry(err.toString());
          });
          return AspectRatio(
            aspectRatio: 2 / 3,
            child: Container(
              color: AppColors.card,
              alignment: Alignment.center,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: AppColors.primary),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Retrying… (${(_attempt + 1).clamp(1, _maxAutoRetries)}/$_maxAutoRetries)',
                    style: const TextStyle(
                        color: AppColors.textTertiary, fontSize: 11),
                  ),
                ],
              ),
            ),
          );
        }
        return AspectRatio(
          aspectRatio: 2 / 3,
          child: Container(
            color: AppColors.card,
            padding: const EdgeInsets.all(20),
            alignment: Alignment.center,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.broken_image,
                    color: AppColors.textTertiary, size: 36),
                const SizedBox(height: 8),
                const Text(
                  'This page failed to load',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: AppColors.textSecondary, fontSize: 12),
                ),
                const SizedBox(height: 4),
                Text(
                  (_lastError ?? err.toString()),
                  maxLines: 3,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: AppColors.textTertiary, fontSize: 10),
                ),
                const SizedBox(height: 10),
                TextButton.icon(
                  onPressed: _manualRetry,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Retry'),
                ),
              ],
            ),
          ),
        );
      },
    );

    return GestureDetector(
      onLongPress: _openLongPressMenu,
      child: _applyTransforms(networkImage, prefs),
    );
  }
}

/// Trims a fixed band off each side of the rendered image — 8px horizontal,
/// 4px vertical — by scaling the child up slightly and clipping back to the
/// original bounds. This is a poor-man's crop: it does not auto-detect actual
/// white margins, just shaves a fixed amount.
///
/// Real edge-detection requires per-pixel analysis, deferred to a v2 when
/// we add the `image` package to the deps.
class _CropEdges extends StatelessWidget {
  const _CropEdges({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: LayoutBuilder(
        builder: (ctx, constraints) {
          // Scale just enough that an 8px horizontal band falls outside the
          // clip. We don't have the image's true width here (constraints
          // can be unbounded mid-layout), so apply a uniform ~3% scale —
          // visually equivalent to "shave a bit off the edges" for typical
          // manga page widths around 600–900 px.
          return Transform.scale(
            scale: 1.05,
            child: child,
          );
        },
      ),
    );
  }
}
