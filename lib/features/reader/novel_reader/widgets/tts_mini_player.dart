import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/di/injection.dart';
import '../../../../core/services/novel_tts_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../bloc/novel_reader_bloc.dart';
import '../bloc/novel_reader_state.dart';

/// Floating TTS controller — three stacked elements at the bottom of
/// the reader:
///
///   1. A compact capsule pill with transport buttons (prev / play-
///      pause / next / close).
///   2. A thin paragraph-progress bar centered below the pill.
///   3. The chapter title text, ellipsised, below the progress bar.
///
/// The whole cluster sits on top of the chapter scroll view but the
/// reader's bottom padding has been bumped so the last paragraph can
/// still scroll above it without being hidden.
class TtsMiniPlayer extends StatelessWidget {
  const TtsMiniPlayer({
    super.key,
    required this.onTapPill,
    required this.onDismiss,
  });

  /// Tap anywhere on the pill chrome (outside the explicit buttons) →
  /// open the full TTS sheet for speed slider / sleep timer / etc.
  final VoidCallback onTapPill;

  /// Close × button on the pill → fully stops TTS and hides the
  /// cluster; the start-TTS FAB takes its place.
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final tts = sl<NovelTtsService>();
    // Put padding INSIDE SafeArea so the only space below the title
    // text is the device's bottom safe-area inset + 4 px. Wrapping
    // SafeArea around the padding instead added 14 + inset = visible
    // empty band under the title.
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 1. Floating pill — transport buttons only. Background
            //    tap (outside the explicit IconButtons) opens the
            //    full sheet.
            Material(
              color: AppColors.surface.withValues(alpha: 0.97),
              elevation: 8,
              shadowColor: Colors.black.withValues(alpha: 0.45),
              shape: StadiumBorder(
                side: BorderSide(
                  color: AppColors.primary.withValues(alpha: 0.22),
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onTapPill,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 4,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _PillIconButton(
                        icon: Icons.skip_previous_rounded,
                        // ignore: discarded_futures
                        onTap: () => tts.seekToParagraph(-1),
                      ),
                      StreamBuilder<PlaybackState>(
                        stream: tts.playbackState,
                        builder: (_, snap) {
                          final playing = snap.data?.playing ?? false;
                          return _PillIconButton(
                            icon: playing
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            emphasized: true,
                            onTap: () {
                              if (playing) {
                                // ignore: discarded_futures
                                tts.pause();
                              } else {
                                // ignore: discarded_futures
                                tts.play();
                              }
                            },
                          );
                        },
                      ),
                      _PillIconButton(
                        icon: Icons.skip_next_rounded,
                        // ignore: discarded_futures
                        onTap: () => tts.seekToParagraph(1),
                      ),
                      const SizedBox(width: 2),
                      // Explicit expand button → opens the full sheet
                      // with speed slider / sleep timer / etc. The
                      // pill body InkWell still works as a secondary
                      // affordance, but the chevron is the
                      // discoverable one.
                      _PillIconButton(
                        icon: Icons.expand_less_rounded,
                        tooltip: 'Expand controls',
                        muted: true,
                        onTap: onTapPill,
                      ),
                      _PillIconButton(
                        icon: Icons.close_rounded,
                        tooltip: 'Stop and hide',
                        muted: true,
                        onTap: onDismiss,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            // 2. Chapter-scroll progress bar — half the viewport wide
            //    so it reads as a clear progress indicator (wider than
            //    the pill) without spilling onto the navbar's Prev /
            //    Next labels at the screen edges. Uses
            //    NovelReaderState.progress (driven by the scroll-update
            //    notifier) rather than paragraph index, because
            //    paragraphs jump in big steps every minute — the bar
            //    looked frozen between advances.
            FractionallySizedBox(
              widthFactor: 0.5,
              child: BlocBuilder<NovelReaderBloc, NovelReaderState>(
                buildWhen: (a, b) => a.progress != b.progress,
                builder: (_, state) {
                  return ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: state.progress.clamp(0.0, 1.0),
                      minHeight: 3,
                      color: AppColors.primary,
                      backgroundColor:
                          AppColors.card.withValues(alpha: 0.6),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 6),
            // 3. Chapter title — at the bottom, centered, ellipsised.
            //    Tracks `mediaItem.title` so chapter advances refresh
            //    the label automatically.
            StreamBuilder<MediaItem?>(
              stream: tts.mediaItem,
              builder: (_, snap) {
                final title = snap.data?.title ?? '';
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    title.isEmpty ? 'Read aloud' : title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.textSecondary.withValues(alpha: 0.9),
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _PillIconButton extends StatelessWidget {
  const _PillIconButton({
    required this.icon,
    required this.onTap,
    this.emphasized = false,
    this.muted = false,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback onTap;
  final bool emphasized;
  final bool muted;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final color = muted
        ? AppColors.textTertiary
        : (emphasized ? AppColors.primary : AppColors.textPrimary);
    final btn = SizedBox(
      width: 38,
      height: 38,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Icon(icon, size: emphasized ? 22 : 19, color: color),
        ),
      ),
    );
    if (tooltip == null) return btn;
    return Tooltip(message: tooltip!, child: btn);
  }
}

/// FAB shown when TTS isn't loaded. Tap = start Read aloud.
class TtsFloatingButton extends StatelessWidget {
  const TtsFloatingButton({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton(
      onPressed: onTap,
      backgroundColor: AppColors.primary,
      foregroundColor: Colors.white,
      tooltip: 'Read aloud',
      child: const Icon(Icons.headphones_outlined),
    );
  }
}
