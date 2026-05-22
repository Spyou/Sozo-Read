import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/di/injection.dart';
import '../../../../core/services/novel_tts_service.dart';
import '../../../../core/state/novel_prefs_cubit.dart';
import '../../../../core/theme/app_colors.dart';
// MediaItem + PlaybackState come from audio_service above.

/// Bottom-sheet controls for the novel TTS player. Subscribes to the
/// handler's `playbackState` stream so the play/pause icon stays in
/// sync with OS-notification taps from outside the app.
class TtsControlSheet extends StatefulWidget {
  const TtsControlSheet({super.key});

  /// Show the sheet over [context]. Returns when dismissed.
  static Future<void> show(BuildContext context) {
    final prefsCubit = context.read<NovelPrefsCubit>();
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => BlocProvider.value(
        value: prefsCubit,
        child: const TtsControlSheet(),
      ),
    );
  }

  @override
  State<TtsControlSheet> createState() => _TtsControlSheetState();
}

/// Sleep-timer presets. `null` durations are sentinels: `_kEndOfChapter`
/// flips `prefs.ttsStopAtChapterEnd`, `_kOff` cancels any active timer.
enum _SleepPreset { off, m5, m15, m30, m60, endOfChapter }

class _TtsControlSheetState extends State<TtsControlSheet> {
  _SleepPreset _sleep = _SleepPreset.off;
  Timer? _sleepTimer;
  // Snapshot of `ttsStopAtChapterEnd` taken when entering end-of-chapter
  // mode so we can restore the user's prior setting on cancel / stop.
  bool? _stopAtChapterEndRestore;

  @override
  void dispose() {
    _sleepTimer?.cancel();
    super.dispose();
  }

  Duration? _durationFor(_SleepPreset p) {
    switch (p) {
      case _SleepPreset.m5:
        return const Duration(minutes: 5);
      case _SleepPreset.m15:
        return const Duration(minutes: 15);
      case _SleepPreset.m30:
        return const Duration(minutes: 30);
      case _SleepPreset.m60:
        return const Duration(minutes: 60);
      case _SleepPreset.endOfChapter:
      case _SleepPreset.off:
        return null;
    }
  }

  String _labelFor(_SleepPreset p) {
    switch (p) {
      case _SleepPreset.off:
        return 'Off';
      case _SleepPreset.m5:
        return '5 min';
      case _SleepPreset.m15:
        return '15 min';
      case _SleepPreset.m30:
        return '30 min';
      case _SleepPreset.m60:
        return '60 min';
      case _SleepPreset.endOfChapter:
        return 'End of chapter';
    }
  }

  void _applySleep(_SleepPreset p) {
    final cubit = context.read<NovelPrefsCubit>();
    final tts = sl<NovelTtsService>();
    // Re-tap the active chip = cancel.
    final next = (p == _sleep) ? _SleepPreset.off : p;
    _sleepTimer?.cancel();
    _sleepTimer = null;
    // Restore the stop-at-chapter-end flag if we were the ones who
    // toggled it on, regardless of which preset the user picked next.
    if (_stopAtChapterEndRestore != null) {
      cubit.setTtsStopAtChapterEnd(_stopAtChapterEndRestore!);
      tts.setStopAtChapterEnd(_stopAtChapterEndRestore!);
      _stopAtChapterEndRestore = null;
    }
    if (next == _SleepPreset.endOfChapter) {
      _stopAtChapterEndRestore = cubit.state.ttsStopAtChapterEnd;
      cubit.setTtsStopAtChapterEnd(true);
      tts.setStopAtChapterEnd(true);
    } else {
      final d = _durationFor(next);
      if (d != null) {
        _sleepTimer = Timer(d, () async {
          await sl<NovelTtsService>().stop();
          if (!mounted) return;
          setState(() => _sleep = _SleepPreset.off);
        });
      }
    }
    setState(() => _sleep = next);
  }

  @override
  Widget build(BuildContext context) {
    final tts = sl<NovelTtsService>();
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Read aloud',
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
              StreamBuilder<MediaItem?>(
                stream: tts.mediaItem,
                builder: (_, snap) {
                  final item = snap.data;
                  if (item == null) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.album ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          item.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: 18),
              StreamBuilder<PlaybackState>(
                stream: tts.playbackState,
                builder: (_, snap) {
                  final playing = snap.data?.playing ?? false;
                  return Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _RoundButton(
                        icon: Icons.skip_previous_rounded,
                        onTap: () => tts.seekToParagraph(-1),
                      ),
                      _RoundButton(
                        icon: playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        large: true,
                        filled: true,
                        onTap: () =>
                            playing ? tts.pause() : tts.play(),
                      ),
                      _RoundButton(
                        icon: Icons.skip_next_rounded,
                        onTap: () => tts.seekToParagraph(1),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 18),
              _ProgressRow(tts: tts),
              const SizedBox(height: 14),
              const Text(
                'Sleep timer',
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final p in _SleepPreset.values)
                    _SleepChip(
                      label: _labelFor(p),
                      selected: _sleep == p,
                      onTap: () => _applySleep(p),
                    ),
                ],
              ),
              const SizedBox(height: 22),
              Center(
                child: TextButton.icon(
                  icon: const Icon(Icons.stop_rounded,
                      color: AppColors.textSecondary),
                  label: const Text(
                    'Stop',
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                  onPressed: () async {
                    // Cancel any timer + restore the chapter-end flag
                    // before closing so the user's prior config is
                    // preserved across sheet sessions.
                    _applySleep(_SleepPreset.off);
                    await tts.stop();
                    if (context.mounted) Navigator.pop(context);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Paragraph progress row: `Paragraph i / n`, a thin LinearProgressBar,
/// and a muted "Stops at chapter end" badge when that pref is on.
class _ProgressRow extends StatelessWidget {
  const _ProgressRow({required this.tts});
  final NovelTtsService tts;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<int>(
      stream: tts.paragraphIndexStream,
      builder: (_, snap) {
        final n = tts.paragraphCount;
        final i = (snap.data ?? tts.paragraphIndex).clamp(0, n);
        final fraction = n == 0 ? 0.0 : i / n;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    n == 0 ? 'Paragraph 0 / 0' : 'Paragraph $i / $n',
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                BlocBuilder<NovelPrefsCubit, NovelPrefs>(
                  buildWhen: (a, b) =>
                      a.ttsStopAtChapterEnd != b.ttsStopAtChapterEnd,
                  builder: (_, prefs) {
                    if (!prefs.ttsStopAtChapterEnd) {
                      return const SizedBox.shrink();
                    }
                    return const Text(
                      'Stops at chapter end',
                      style: TextStyle(
                        color: AppColors.textTertiary,
                        fontSize: 11,
                      ),
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: fraction.clamp(0.0, 1.0),
                minHeight: 3,
                color: AppColors.primary,
                backgroundColor: AppColors.card,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SleepChip extends StatelessWidget {
  const _SleepChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bg = selected
        ? AppColors.primary.withValues(alpha: 0.2)
        : AppColors.card;
    final fg = selected ? AppColors.primary : AppColors.textSecondary;
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Text(
            label,
            style: TextStyle(
              color: fg,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.onTap,
    this.large = false,
    this.filled = false,
  });

  final IconData icon;
  final VoidCallback onTap;
  final bool large;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final size = large ? 64.0 : 48.0;
    final color = filled ? Colors.white : AppColors.textPrimary;
    return Material(
      color: filled ? AppColors.primary : AppColors.card,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, color: color, size: large ? 36 : 26),
        ),
      ),
    );
  }
}
