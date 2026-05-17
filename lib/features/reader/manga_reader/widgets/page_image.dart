import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../../core/models/page_content.dart';
import '../../../../core/theme/app_colors.dart';

/// Manga page image with retry-with-backoff.
///
/// On load failure, automatically retries up to 3 times with exponential
/// backoff (500ms, 1000ms, 2000ms). If all auto-retries fail, the existing
/// broken-image widget is shown with a manual "Retry" button that resets
/// the retry counter.
class PageImage extends StatefulWidget {
  const PageImage({super.key, required this.page, this.fit = BoxFit.fitWidth});

  final PageContent page;
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

  void _manualRetry() {
    _retryTimer?.cancel();
    setState(() {
      _attempt = 0;
      _scheduling = false;
      _lastError = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final retrying = _scheduling && _attempt < _maxAutoRetries;
    final exhausted = _attempt >= _maxAutoRetries && _lastError != null;

    // Local-file fast-path: the manga reader bloc rewrites downloaded pages
    // with a `file://...` URL. Render with Image.file (no network, no cache).
    final url = widget.page.url;
    if (url.startsWith('file://') || url.startsWith('/')) {
      final path = url.startsWith('file://') ? url.substring(7) : url;
      return Image.file(
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
    }

    return CachedNetworkImage(
      // Adding the attempt counter to the key forces a fresh image attempt
      // on each retry.
      key: ValueKey('${widget.page.url}#$_attempt'),
      imageUrl: widget.page.url,
      fit: widget.fit,
      httpHeaders: widget.page.headers,
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
                  'Page failed to load',
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
  }
}
