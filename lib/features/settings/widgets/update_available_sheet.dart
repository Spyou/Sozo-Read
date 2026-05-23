import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/di/injection.dart';
import '../../../core/models/github_release.dart';
import '../../../core/services/update_service.dart';
import '../../../core/theme/app_colors.dart';

/// Modal prompt shown when a newer release is detected. Three actions:
///   • Update — download the APK + hand off to the OS installer prompt
///   • Later  — snooze prompts for 24h
///   • Skip   — never prompt for this exact tag again
class UpdateAvailableSheet extends StatefulWidget {
  const UpdateAvailableSheet({super.key, required this.release});
  final GitHubRelease release;

  static Future<void> show(BuildContext context, GitHubRelease release) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      isDismissible: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => UpdateAvailableSheet(release: release),
    );
  }

  @override
  State<UpdateAvailableSheet> createState() => _UpdateAvailableSheetState();
}

class _UpdateAvailableSheetState extends State<UpdateAvailableSheet> {
  final UpdateService _service = sl<UpdateService>();
  CancelToken? _cancel;
  double _progress = 0;
  bool _downloading = false;
  String? _error;

  @override
  void dispose() {
    _cancel?.cancel('sheet closed');
    super.dispose();
  }

  Future<void> _startUpdate() async {
    // Resolve via the ABI-aware picker so the filename + path match
    // whichever asset will actually be downloaded (matters for the
    // FileProvider install step, which uses the resolved path).
    final asset = await _service.resolveApkAsset(widget.release);
    if (asset == null) {
      setState(() => _error = 'No APK attached to this release.');
      return;
    }
    setState(() {
      _downloading = true;
      _progress = 0;
      _error = null;
    });
    _cancel = CancelToken();
    try {
      // App cache dir / updates / <filename>.apk — the FileProvider authority
      // declared in AndroidManifest.xml maps exactly this subtree.
      final cacheDir = await getApplicationCacheDirectory();
      final dir = Directory('${cacheDir.path}/updates');
      if (!await dir.exists()) await dir.create(recursive: true);
      final target = '${dir.path}/${asset.name}';
      await for (final p in _service.downloadApk(
        widget.release,
        targetPath: target,
        cancelToken: _cancel,
      )) {
        if (!mounted) return;
        setState(() => _progress = p.clamp(0, 1));
      }
      if (!mounted) return;
      await _service.install(target);
      if (!mounted) return;
      // Dismiss the sheet — the OS installer prompt is now in the foreground.
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _error = 'Update failed: $e';
      });
    }
  }

  Future<void> _remindLater() async {
    await _service.remindLater();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _skip() async {
    await _service.skipVersion(widget.release);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final release = widget.release;
    final pct = (_progress * 100).clamp(0, 100).toStringAsFixed(0);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.65,
      maxChildSize: 0.92,
      minChildSize: 0.4,
      builder: (_, scrollCtrl) => SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 12, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Update available',
                          style: TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          release.name.isEmpty ? release.tagName : release.name,
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
                    onPressed: _downloading
                        ? null
                        : () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(color: AppColors.divider, height: 1),
            Expanded(
              child: Markdown(
                controller: scrollCtrl,
                data: release.body.isEmpty
                    ? '_No release notes provided._'
                    : release.body,
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                selectable: true,
                styleSheet: MarkdownStyleSheet(
                  p: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 14,
                    height: 1.4,
                  ),
                  h1: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                  h2: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                  h3: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                  code: TextStyle(
                    backgroundColor: AppColors.card.withValues(alpha: 0.6),
                    color: AppColors.textPrimary,
                    fontFamily: 'monospace',
                    fontSize: 13,
                  ),
                ),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                child: Text(
                  _error!,
                  style: const TextStyle(
                    color: AppColors.error,
                    fontSize: 12,
                  ),
                ),
              ),
            if (_downloading)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: _progress == 0 ? null : _progress,
                        minHeight: 6,
                        backgroundColor:
                            AppColors.card.withValues(alpha: 0.6),
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          AppColors.primary,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Downloading $pct%',
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: Row(
                children: [
                  TextButton(
                    onPressed: _downloading ? null : _skip,
                    child: const Text('Skip this version'),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: _downloading ? null : _remindLater,
                    child: const Text('Later'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _downloading ? null : _startUpdate,
                    icon: const Icon(Icons.system_update_alt_rounded, size: 18),
                    label: Text(_downloading ? 'Updating…' : 'Update'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
