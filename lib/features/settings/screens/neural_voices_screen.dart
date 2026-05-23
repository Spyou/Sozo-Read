import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/di/injection.dart';
import '../../../core/repository/voices_repository.dart';
import '../../../core/services/voice_catalog.dart';
import '../../../core/services/voice_downloader.dart';
import '../../../core/state/novel_prefs_cubit.dart';
import '../../../core/theme/app_colors.dart';

/// `/settings/tts/voices` — picker + downloader for neural Piper voices.
///
/// Each row is independently streamed so the user can queue several
/// downloads at once and watch them progress in parallel. Active
/// downloads are tracked in [_subs] so they cancel on dispose; the
/// underlying [VoiceDownloader] keeps running in the background, the
/// row just stops listening.
class NeuralVoicesScreen extends StatefulWidget {
  const NeuralVoicesScreen({super.key});

  @override
  State<NeuralVoicesScreen> createState() => _NeuralVoicesScreenState();
}

class _NeuralVoicesScreenState extends State<NeuralVoicesScreen> {
  /// Latest event per voice id, keyed by [NeuralVoice.id]. Drives the
  /// trailing widget (progress bar / spinner / installed check).
  final Map<String, VoiceDownloadEvent> _events = <String, VoiceDownloadEvent>{};

  /// Active download subscriptions. Canceled on dispose so the screen
  /// doesn't keep streaming after the user navigates away — the
  /// download itself is owned by [VoiceDownloader] and lives on.
  final Map<String, StreamSubscription<VoiceDownloadEvent>> _subs =
      <String, StreamSubscription<VoiceDownloadEvent>>{};

  /// Bumped after every `repo` mutation so the footer + per-row state
  /// rebuilds. Cheaper than wrapping the whole repo in a cubit just for
  /// this screen.
  int _repoTick = 0;

  VoicesRepository get _repo => sl<VoicesRepository>();
  VoiceDownloader get _downloader => sl<VoiceDownloader>();

  @override
  void dispose() {
    for (final sub in _subs.values) {
      // ignore: discarded_futures
      sub.cancel();
    }
    _subs.clear();
    super.dispose();
  }

  void _startDownload(NeuralVoice voice) {
    if (_subs.containsKey(voice.id)) return;
    final stream = _downloader.download(voice);
    final sub = stream.listen(
      (event) {
        if (!mounted) return;
        setState(() {
          _events[voice.id] = event;
          if (event is VoiceInstalled) {
            _repoTick++;
          }
        });
      },
      onDone: () {
        if (!mounted) return;
        _subs.remove(voice.id);
      },
      onError: (Object err) {
        if (!mounted) return;
        setState(() {
          _events[voice.id] = VoiceFailed(err.toString());
        });
        _subs.remove(voice.id);
      },
    );
    _subs[voice.id] = sub;
  }

  Future<void> _delete(NeuralVoice voice) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${voice.displayName}?'),
        content: const Text(
          'This frees the disk space. The voice can be re-downloaded any time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _downloader.remove(voice);
    if (!mounted) return;
    // If the active voice just got deleted, clear the pref so the
    // service falls back to system speech rather than pointing at a
    // missing file.
    final cubit = context.read<NovelPrefsCubit>();
    if (cubit.state.ttsNeuralVoiceId == voice.id) {
      cubit.setTtsNeuralVoiceId(null);
    }
    setState(() {
      _events.remove(voice.id);
      _repoTick++;
    });
  }

  Future<void> _clearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear all neural voices?'),
        content: const Text(
          'Removes every downloaded voice pack. The system TTS engine is unaffected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear all'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _repo.clear();
    if (!mounted) return;
    context.read<NovelPrefsCubit>().setTtsNeuralVoiceId(null);
    setState(() {
      _events.clear();
      _repoTick++;
    });
  }

  void _selectActive(NeuralVoice voice) {
    context.read<NovelPrefsCubit>().setTtsNeuralVoiceId(voice.id);
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider.value(
      value: sl<NovelPrefsCubit>(),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Neural voices'),
          centerTitle: true,
          actions: [
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'clear') _clearAll();
              },
              itemBuilder: (_) => const [
                PopupMenuItem<String>(
                  value: 'clear',
                  child: Text('Clear all neural voices'),
                ),
              ],
            ),
          ],
        ),
        body: BlocBuilder<NovelPrefsCubit, NovelPrefs>(
          builder: (context, prefs) {
            final voices = VoiceCatalog.all;
            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              itemCount: voices.length + 1,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (ctx, i) {
                if (i == voices.length) {
                  return _Footer(
                    // _repoTick forces a rebuild after install/remove so
                    // the displayed disk usage is always current.
                    key: ValueKey('footer-$_repoTick'),
                    repo: _repo,
                    onClearAll: _clearAll,
                  );
                }
                final voice = voices[i];
                final installed = _repo.isInstalled(voice.id);
                final isActive = prefs.ttsNeuralVoiceId == voice.id;
                final event = _events[voice.id];
                return _VoiceRow(
                  key: ValueKey('voice-${voice.id}-$_repoTick'),
                  voice: voice,
                  installed: installed,
                  isActive: isActive,
                  event: event,
                  onDownload: () => _startDownload(voice),
                  onSelect: () => _selectActive(voice),
                  onDelete: () => _delete(voice),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _VoiceRow extends StatelessWidget {
  const _VoiceRow({
    super.key,
    required this.voice,
    required this.installed,
    required this.isActive,
    required this.event,
    required this.onDownload,
    required this.onSelect,
    required this.onDelete,
  });

  final NeuralVoice voice;
  final bool installed;
  final bool isActive;
  final VoiceDownloadEvent? event;
  final VoidCallback onDownload;
  final VoidCallback onSelect;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Active rows get an accent border so the user can spot the
    // currently-speaking voice at a glance.
    final borderColor = isActive
        ? theme.colorScheme.primary
        : theme.dividerColor.withValues(alpha: 0.4);
    final subtitle =
        '${voice.language} | ${_genderLabel(voice.gender)} | '
        '${_qualityLabel(voice.quality)} | ~${_formatBytes(voice.approxSizeBytes)}';
    final inProgress = event is VoiceDownloading || event is VoiceExtracting;
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest
            .withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: borderColor,
          width: isActive ? 1.4 : 0.6,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: inProgress
            ? null
            : (installed ? onSelect : onDownload),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          child: Row(
            children: [
              Icon(
                Icons.record_voice_over_rounded,
                color: isActive
                    ? theme.colorScheme.primary
                    : theme.textTheme.bodySmall?.color,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            voice.displayName,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (isActive) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary
                                  .withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              'Active',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: theme.colorScheme.primary,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.textTheme.bodySmall?.color,
                      ),
                    ),
                    if (event is VoiceFailed) ...[
                      const SizedBox(height: 6),
                      Text(
                        'Failed: ${(event as VoiceFailed).message}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.error,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _trailing(theme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _trailing(ThemeData theme) {
    final e = event;
    if (e is VoiceDownloading) {
      return SizedBox(
        width: 64,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                value: e.progress.clamp(0.0, 1.0),
                strokeWidth: 3,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${(e.progress * 100).clamp(0, 100).toStringAsFixed(0)}%',
              style: TextStyle(
                fontSize: 11,
                color: theme.textTheme.bodySmall?.color,
              ),
            ),
          ],
        ),
      );
    }
    if (e is VoiceExtracting) {
      return SizedBox(
        width: 64,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            SizedBox(height: 4),
            Text(
              'Extracting',
              style: TextStyle(fontSize: 11),
            ),
          ],
        ),
      );
    }
    if (installed) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.check_circle_rounded,
            color: AppColors.success,
            size: 22,
          ),
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (v) {
              if (v == 'delete') onDelete();
            },
            itemBuilder: (_) => const [
              PopupMenuItem<String>(
                value: 'delete',
                child: Text('Delete'),
              ),
            ],
          ),
        ],
      );
    }
    // Not installed and idle (or last attempt failed) — let the user
    // start / retry the download.
    return OutlinedButton(
      onPressed: onDownload,
      child: Text(e is VoiceFailed ? 'Retry' : 'Download'),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({
    super.key,
    required this.repo,
    required this.onClearAll,
  });

  final VoicesRepository repo;
  final VoidCallback onClearAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final installed = repo.installedIds().length;
    final size = repo.totalSizeBytes();
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$installed downloaded | ${_formatBytes(size)} on disk',
            style: TextStyle(
              fontSize: 12,
              color: theme.textTheme.bodySmall?.color,
            ),
          ),
          const SizedBox(height: 10),
          if (installed > 0)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: onClearAll,
                icon: const Icon(
                  Icons.delete_sweep_outlined,
                  color: AppColors.error,
                ),
                label: const Text(
                  'Clear all neural voices',
                  style: TextStyle(color: AppColors.error),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

String _genderLabel(VoiceGender g) {
  switch (g) {
    case VoiceGender.female:
      return 'Female';
    case VoiceGender.male:
      return 'Male';
    case VoiceGender.unknown:
      return 'Multi';
  }
}

String _qualityLabel(VoiceQuality q) {
  switch (q) {
    case VoiceQuality.low:
      return 'Low';
    case VoiceQuality.medium:
      return 'Medium';
    case VoiceQuality.high:
      return 'High';
  }
}

String _formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  var size = bytes.toDouble();
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  // Bytes/KB stay integer; MB/GB keep one decimal so 63 MB doesn't
  // round up to 64 in the catalog labels.
  if (unit <= 1) {
    return '${size.toStringAsFixed(0)} ${units[unit]}';
  }
  return '${size.toStringAsFixed(1)} ${units[unit]}';
}
