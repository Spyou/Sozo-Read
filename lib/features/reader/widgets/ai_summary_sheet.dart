import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../../core/di/injection.dart';
import '../../../core/repository/summaries_repository.dart';
import '../../../core/services/ai/ai_client.dart';
import '../../../core/state/ai_prefs_cubit.dart';
import '../../../core/theme/app_colors.dart';

/// One-shot bottom sheet for AI chapter summaries.
///
/// Backed by [SummariesRepository] — re-asking the same chapter is
/// instant and doesn't burn a request. Caller hands us the lookup
/// keys (sourceId, bookId, chapterId, chapterLabel) and a payload
/// builder: novels return their text inside `payloadText`, manga
/// readers return their page images inside `payloadImages`. We ask
/// once on `show()` and again when the user taps "Regenerate".
class AiSummarySheet extends StatefulWidget {
  const AiSummarySheet({
    super.key,
    required this.sourceId,
    required this.bookId,
    required this.chapterId,
    required this.chapterLabel,
    required this.kind,
    required this.fetchPayload,
    this.preWarnImagesCount,
  });

  final String sourceId;
  final String bookId;
  final String chapterId;
  final String chapterLabel;

  /// Loose category for tailoring the prompt — novels get a literary
  /// summary, manga / manhwa get a visual + dialogue recap.
  final AiSummaryKind kind;

  /// Builds the payload at request time. Called lazily so we don't
  /// fetch images / read large text just to open a sheet that the user
  /// might dismiss. Returns null to abort (e.g. user cancelled).
  final Future<AiSummaryPayload?> Function() fetchPayload;

  /// If provided, the sheet shows a "this will send N images to
  /// Gemini" warning before the first request. Novels skip this.
  final int? preWarnImagesCount;

  static Future<void> show(
    BuildContext context, {
    required String sourceId,
    required String bookId,
    required String chapterId,
    required String chapterLabel,
    required AiSummaryKind kind,
    required Future<AiSummaryPayload?> Function() fetchPayload,
    int? preWarnImagesCount,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => AiSummarySheet(
        sourceId: sourceId,
        bookId: bookId,
        chapterId: chapterId,
        chapterLabel: chapterLabel,
        kind: kind,
        fetchPayload: fetchPayload,
        preWarnImagesCount: preWarnImagesCount,
      ),
    );
  }

  @override
  State<AiSummarySheet> createState() => _AiSummarySheetState();
}

class _AiSummarySheetState extends State<AiSummarySheet> {
  bool _loading = false;
  String? _summary;
  String? _error;
  bool _accepted = false; // user dismissed the image-count warning

  @override
  void initState() {
    super.initState();
    // Always try the cache first — instant + free.
    final cached = sl<SummariesRepository>().get(
      widget.sourceId,
      widget.bookId,
      widget.chapterId,
    );
    if (cached != null && cached.isNotEmpty) {
      _summary = cached;
    }
  }

  bool get _needsImageWarning =>
      _summary == null &&
      widget.preWarnImagesCount != null &&
      widget.preWarnImagesCount! > 0 &&
      !_accepted;

  Future<void> _generate() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final payload = await widget.fetchPayload();
      if (payload == null) {
        if (!mounted) return;
        setState(() => _loading = false);
        return;
      }
      final cubit = sl<AiPrefsCubit>();
      final model = cubit.state.model;
      final result = await sl<AiClient>().summarize(
        prompt: _promptFor(widget.kind),
        text: payload.text,
        images: payload.images,
        model: model,
      );
      await sl<SummariesRepository>().put(
        sourceId: widget.sourceId,
        bookId: widget.bookId,
        chapterId: widget.chapterId,
        summary: result,
        modelApiId: model.apiId,
      );
      if (!mounted) return;
      setState(() {
        _summary = result;
        _loading = false;
      });
    } on AiClientException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
      if (e.kind == AiErrorKind.noApiKey) {
        // Auto-route the user to the settings screen so they don't
        // have to hunt for it. The sheet stays open in the
        // background — they can re-tap regenerate after saving a key.
        // ignore: discarded_futures
        Future<void>.microtask(() {
          if (mounted) context.push('/settings/ai');
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Unexpected error: $e';
        _loading = false;
      });
    }
  }

  String _promptFor(AiSummaryKind kind) {
    switch (kind) {
      case AiSummaryKind.novel:
        return 'You are summarizing a chapter from a novel a reader '
            'just finished. Produce a 4-6 sentence recap that covers '
            'the major plot events, character actions, and any '
            'twists or revelations. Avoid spoilers from beyond this '
            'chapter (the user only wants what happened here). '
            'Match the original tone where possible.';
      case AiSummaryKind.manga:
        return 'You are summarizing a manga chapter. The user just '
            'finished reading these pages. Produce a 4-6 sentence '
            'recap that covers the major story events, fight beats, '
            'dialogue moments, and visual reveals. Use present tense. '
            "Don't describe panels mechanically — focus on what "
            'happened. Avoid speculation about future chapters.';
      case AiSummaryKind.manhwa:
        return 'You are summarizing a manhwa chapter. The user just '
            'finished reading these vertical-scroll pages. Produce a '
            "4-6 sentence recap that covers the main events. Don't "
            'describe panels mechanically — focus on plot, dialogue '
            'beats, and any reveals.';
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.95,
      builder: (_, scrollCtrl) => SafeArea(
        top: false,
        child: Column(
          children: [
            _header(context),
            const Divider(color: AppColors.divider, height: 1),
            Expanded(child: _body(scrollCtrl)),
            _footer(),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 8, 8),
      child: Row(
        children: [
          const Icon(Icons.auto_awesome_outlined,
              color: AppColors.primary, size: 22),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'AI summary',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  widget.chapterLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded,
                color: AppColors.textSecondary),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _body(ScrollController scrollCtrl) {
    if (_needsImageWarning) return _imageWarning();
    if (_loading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: AppColors.primary),
              SizedBox(height: 16),
              Text(
                'Asking Gemini...',
                style: TextStyle(color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
      );
    }
    if (_error != null) return _errorView();
    if (_summary != null) return _summaryView(scrollCtrl);
    return _startPrompt();
  }

  Widget _startPrompt() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Generate a summary of this chapter using Gemini.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            icon: const Icon(Icons.auto_awesome_rounded),
            label: const Text('Summarize'),
            onPressed: _generate,
          ),
        ],
      ),
    );
  }

  Widget _imageWarning() {
    final n = widget.preWarnImagesCount ?? 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.image_outlined,
              size: 48, color: AppColors.textTertiary),
          const SizedBox(height: 12),
          Text(
            'This chapter has $n pages. Generating a summary will '
            'send all of them to Gemini and use approximately 1 '
            'request of your daily quota.',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            icon: const Icon(Icons.auto_awesome_rounded),
            label: const Text('Continue'),
            onPressed: () {
              setState(() => _accepted = true);
              // ignore: discarded_futures
              _generate();
            },
          ),
        ],
      ),
    );
  }

  Widget _errorView() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline_rounded,
              size: 40, color: AppColors.error),
          const SizedBox(height: 12),
          Text(
            _error ?? 'Something went wrong',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Try again'),
            onPressed: _generate,
          ),
        ],
      ),
    );
  }

  Widget _summaryView(ScrollController scrollCtrl) {
    return SingleChildScrollView(
      controller: scrollCtrl,
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
      child: SelectableText(
        _summary!,
        style: const TextStyle(
          color: AppColors.textPrimary,
          fontSize: 14,
          height: 1.55,
        ),
      ),
    );
  }

  Widget _footer() {
    if (_summary == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        children: [
          TextButton.icon(
            icon: const Icon(Icons.copy_rounded, size: 18),
            label: const Text('Copy'),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _summary!));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Copied')),
              );
            },
          ),
          const Spacer(),
          TextButton.icon(
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('Regenerate'),
            onPressed: () async {
              await sl<SummariesRepository>().remove(
                widget.sourceId,
                widget.bookId,
                widget.chapterId,
              );
              if (!mounted) return;
              setState(() {
                _summary = null;
                _error = null;
              });
              // ignore: discarded_futures
              _generate();
            },
          ),
        ],
      ),
    );
  }
}

enum AiSummaryKind { novel, manga, manhwa }

class AiSummaryPayload {
  AiSummaryPayload({this.text, this.images});

  final String? text;
  final List<AiImage>? images;
}

/// Convert raw image bytes to an [AiImage] with the right MIME type.
/// Sniffs the magic bytes — Gemini accepts JPEG, PNG, WEBP, HEIC. Pure
/// helper so reader feature code doesn't have to import dart:typed_data
/// directly.
AiImage imageFromBytes(Uint8List bytes) {
  String mime = 'image/jpeg';
  if (bytes.length >= 4) {
    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      mime = 'image/png';
    } else if (bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46) {
      mime = 'image/gif';
    } else if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      mime = 'image/webp';
    }
  }
  return AiImage(bytes: bytes, mimeType: mime);
}
