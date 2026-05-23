import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/di/injection.dart';
import '../../../core/repository/voices_repository.dart';
import '../../../core/services/novel_tts_service.dart';
import '../../../core/services/voice_catalog.dart';
import '../../../core/state/manga_prefs_cubit.dart';
import '../../../core/state/notifications_prefs_cubit.dart';
import '../../../core/state/novel_prefs_cubit.dart';
import '../widgets/settings_dialogs.dart';
import '../widgets/settings_widgets.dart';
import '../widgets/voice_picker_sheet.dart';

/// `/settings/reading` — split into MANGA and NOVEL sub-sections.
class ReadingSettingsScreen extends StatelessWidget {
  const ReadingSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider.value(value: sl<NovelPrefsCubit>()),
        BlocProvider.value(value: sl<MangaPrefsCubit>()),
        BlocProvider.value(value: sl<NotificationsPrefsCubit>()),
      ],
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Reading'),
          centerTitle: true,
        ),
        body: BlocBuilder<NovelPrefsCubit, NovelPrefs>(
          builder: (context, p) {
            return ListView(
              children: [
                const SettingsSectionLabel('Manga'),
                BlocBuilder<MangaPrefsCubit, MangaPrefs>(
                  builder: (context, m) => SettingsCard(
                    children: [
                      SettingsTile(
                        icon: Icons.swap_vert_rounded,
                        title: 'Direction',
                        subtitle: MangaPrefsCubit.directionLabel(
                            m.readingDirection),
                        onTap: () => openMangaDirectionSheet(
                          context,
                          m.readingDirection,
                        ),
                      ),
                      SettingsTile(
                        icon: Icons.touch_app_outlined,
                        title: 'Tap zones',
                        subtitle: 'Tap left/right to flip pages',
                        trailing: Switch.adaptive(
                          value: m.tapZoneNavigation,
                          onChanged: (v) => context
                              .read<MangaPrefsCubit>()
                              .setTapZoneNavigation(v),
                        ),
                        onTap: () => context
                            .read<MangaPrefsCubit>()
                            .setTapZoneNavigation(!m.tapZoneNavigation),
                      ),
                      SettingsTile(
                        icon: Icons.crop_rounded,
                        title: 'Crop edges',
                        subtitle: 'Trim white margins from panels',
                        trailing: Switch.adaptive(
                          value: m.cropEdges,
                          onChanged: (v) => context
                              .read<MangaPrefsCubit>()
                              .setCropEdges(v),
                        ),
                        onTap: () => context
                            .read<MangaPrefsCubit>()
                            .setCropEdges(!m.cropEdges),
                      ),
                      SettingsTile(
                        icon: Icons.palette_outlined,
                        title: 'Color filter',
                        subtitle: colorFilterLabel(m.colorFilter),
                        onTap: () => openMangaColorFilterSheet(
                          context,
                          m.colorFilter,
                        ),
                      ),
                      SettingsTile(
                        icon: Icons.swipe_vertical_rounded,
                        title: 'Auto-scroll',
                        subtitle: autoScrollLabel(m.autoScroll),
                        onTap: () => openMangaAutoScrollSheet(
                          context,
                          m.autoScroll,
                        ),
                      ),
                      SettingsTile(
                        icon: Icons.image_outlined,
                        title: 'Image quality',
                        subtitle: imageQualityLabel(m.imageQuality),
                        onTap: () => openMangaImageQualitySheet(
                          context,
                          m.imageQuality,
                        ),
                      ),
                      SettingsTile(
                        icon: Icons.fit_screen_rounded,
                        title: 'Image fit',
                        subtitle: fitModeLabel(m.fitMode),
                        onTap: () => openMangaFitModeSheet(
                          context,
                          m.fitMode,
                          // Fit height only makes sense in paged/horizontal
                          // mode — hide the option when the user reads in
                          // vertical/webtoon mode to avoid a confusing
                          // setting that visibly does nothing.
                          fitHeightAvailable: m.readingDirection !=
                              MangaReadingDirection.vertical,
                        ),
                      ),
                      // Double-page spread is meaningless in vertical mode
                      // (webtoon stacks pages); hide the tile entirely
                      // there so the user can't set a pref that goes
                      // silently ignored.
                      if (m.readingDirection !=
                          MangaReadingDirection.vertical)
                        SettingsTile(
                          icon: Icons.menu_book_rounded,
                          title: 'Double page',
                          subtitle: doublePageModeLabel(m.doublePageMode),
                          onTap: () => openMangaDoublePageModeSheet(
                            context,
                            m.doublePageMode,
                          ),
                        ),
                      SettingsTile(
                        icon: Icons.screen_rotation_rounded,
                        title: 'Lock orientation',
                        subtitle: orientationLockLabel(m.orientationLock),
                        onTap: () => openMangaOrientationLockSheet(
                          context,
                          m.orientationLock,
                        ),
                      ),
                      SettingsTile(
                        icon: Icons.lightbulb_outline_rounded,
                        title: 'Keep screen on',
                        subtitle: 'Prevent screen timeout while reading',
                        trailing: Switch.adaptive(
                          value: m.keepScreenOn,
                          onChanged: (v) => context
                              .read<MangaPrefsCubit>()
                              .setKeepScreenOn(v),
                        ),
                        onTap: () => context
                            .read<MangaPrefsCubit>()
                            .setKeepScreenOn(!m.keepScreenOn),
                      ),
                    ],
                  ),
                ),
                const SettingsSectionLabel('Downloads'),
                BlocBuilder<MangaPrefsCubit, MangaPrefs>(
                  builder: (context, m) => SettingsCard(
                    children: [
                      SettingsTile(
                        icon: Icons.wifi_rounded,
                        title: 'WiFi only',
                        subtitle:
                            'Pause downloads when not on WiFi',
                        trailing: Switch.adaptive(
                          value: m.downloadsWifiOnly,
                          onChanged: (v) => context
                              .read<MangaPrefsCubit>()
                              .setDownloadsWifiOnly(v),
                        ),
                        onTap: () => context
                            .read<MangaPrefsCubit>()
                            .setDownloadsWifiOnly(!m.downloadsWifiOnly),
                      ),
                    ],
                  ),
                ),
                const SettingsSectionLabel('Novel'),
                SettingsCard(
                  children: [
                    SettingsTile(
                      icon: Icons.format_size_rounded,
                      title: 'Font size',
                      subtitle: '${p.fontSize.toStringAsFixed(0)} pt',
                      onTap: () => openSliderDialog(
                        context,
                        title: 'Font size',
                        value: p.fontSize,
                        min: 12,
                        max: 28,
                        divisions: 16,
                        formatter: (v) => '${v.toStringAsFixed(0)} pt',
                        onChanged:
                            context.read<NovelPrefsCubit>().setFontSize,
                      ),
                    ),
                    SettingsTile(
                      icon: Icons.format_line_spacing_rounded,
                      title: 'Line height',
                      subtitle: p.lineHeight.toStringAsFixed(2),
                      onTap: () => openSliderDialog(
                        context,
                        title: 'Line height',
                        value: p.lineHeight,
                        min: 1.2,
                        max: 2.2,
                        divisions: 20,
                        formatter: (v) => v.toStringAsFixed(2),
                        onChanged:
                            context.read<NovelPrefsCubit>().setLineHeight,
                      ),
                    ),
                    SettingsTile(
                      icon: Icons.format_indent_increase_rounded,
                      title: 'Margin',
                      subtitle: '${p.horizontalMargin.toStringAsFixed(0)} px',
                      onTap: () => openSliderDialog(
                        context,
                        title: 'Horizontal margin',
                        value: p.horizontalMargin,
                        min: 8,
                        max: 40,
                        divisions: 32,
                        formatter: (v) => '${v.toStringAsFixed(0)} px',
                        onChanged:
                            context.read<NovelPrefsCubit>().setMargin,
                      ),
                    ),
                    SettingsTile(
                      icon: Icons.font_download_outlined,
                      title: 'Font family',
                      subtitle: p.fontFamily,
                      onTap: () => openFontFamilySheet(context, p.fontFamily),
                    ),
                    // TTS voice rate. Bounds picked to match the audible
                    // range on Android+iOS: below 0.3 the engines start
                    // dropping phonemes, above 0.8 they sound chipmunked.
                    SettingsTile(
                      icon: Icons.record_voice_over_outlined,
                      title: 'TTS voice rate',
                      subtitle: p.ttsRate.toStringAsFixed(2),
                      onTap: () => openSliderDialog(
                        context,
                        title: 'TTS voice rate',
                        value: p.ttsRate.clamp(0.3, 0.8),
                        min: 0.3,
                        max: 0.8,
                        divisions: 10,
                        formatter: (v) => v.toStringAsFixed(2),
                        onChanged:
                            context.read<NovelPrefsCubit>().setTtsRate,
                      ),
                    ),
                  ],
                ),
                const SettingsSectionLabel('Text-to-speech'),
                _TtsSettingsCard(prefs: p),
                // ------------------------------------------------------------
                // Notifications. Lives in its own section near the bottom so
                // it stays visually separate from the typography controls
                // and won't conflict with future reading-direction edits.
                // ------------------------------------------------------------
                const SettingsSectionLabel('Notifications'),
                BlocBuilder<NotificationsPrefsCubit, NotificationsPrefs>(
                  builder: (context, n) => SettingsCard(
                    children: [
                      SettingsTile(
                        icon: Icons.notifications_active_outlined,
                        title: 'New chapter alerts',
                        subtitle:
                            n.newChaptersEnabled ? 'On' : 'Off',
                        trailing: Switch.adaptive(
                          value: n.newChaptersEnabled,
                          onChanged: (v) => context
                              .read<NotificationsPrefsCubit>()
                              .setNewChaptersEnabled(v),
                        ),
                        onTap: () => context
                            .read<NotificationsPrefsCubit>()
                            .setNewChaptersEnabled(!n.newChaptersEnabled),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// TTS settings group. Sliders + switches all mirror their new value into
/// the live [NovelTtsService] so a running playback session reacts the
/// instant the user lets go of a thumb / toggles a switch.
class _TtsSettingsCard extends StatelessWidget {
  const _TtsSettingsCard({required this.prefs});

  final NovelPrefs prefs;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<NovelPrefsCubit>();
    final entryCount = prefs.ttsPronunciations.length;
    final isNeural = prefs.ttsEngine == TtsEngine.neural;
    final installedNeuralCount =
        isNeural ? sl<VoicesRepository>().installedIds().length : 0;
    return SettingsCard(
      children: [
        SettingsTile(
          icon: Icons.tune_rounded,
          title: 'TTS engine',
          subtitle: isNeural
              ? 'Neural (premium, on-device)'
              : 'System (built-in, free)',
          onTap: () => _openEnginePicker(context, prefs.ttsEngine),
        ),
        SettingsTile(
          icon: Icons.graphic_eq_rounded,
          title: 'Voice',
          subtitle: _voiceSubtitle(prefs, isNeural),
          onTap: () => VoicePickerSheet.show(context),
        ),
        if (isNeural)
          SettingsTile(
            icon: Icons.library_music_outlined,
            title: 'Manage voices',
            subtitle: '$installedNeuralCount downloaded',
            onTap: () => context.push('/settings/tts/voices'),
          ),
        _SliderTile(
          icon: Icons.height_rounded,
          title: 'Pitch',
          value: prefs.ttsPitch,
          min: 0.5,
          max: 2.0,
          divisions: 15,
          formatter: (v) => v.toStringAsFixed(1),
          onChanged: (v) {
            cubit.setTtsPitch(v);
            // ignore: discarded_futures
            sl<NovelTtsService>().setPitch(v);
          },
        ),
        _SliderTile(
          icon: Icons.volume_up_rounded,
          title: 'Volume',
          value: prefs.ttsVolume,
          min: 0.0,
          max: 1.0,
          divisions: 10,
          formatter: (v) => '${(v * 100).round()}%',
          onChanged: (v) {
            cubit.setTtsVolume(v);
            // ignore: discarded_futures
            sl<NovelTtsService>().setVolume(v);
          },
        ),
        SettingsTile(
          icon: Icons.spellcheck_outlined,
          title: 'Pronunciations',
          subtitle: entryCount == 0 ? 'None' : '$entryCount entries',
          onTap: () => context.push('/settings/tts/pronunciations'),
        ),
        SwitchListTile.adaptive(
          secondary: const Icon(Icons.stop_circle_outlined),
          title: const Text('Stop at chapter end'),
          subtitle: const Text("Don't auto-advance to the next chapter"),
          value: prefs.ttsStopAtChapterEnd,
          onChanged: (v) {
            cubit.setTtsStopAtChapterEnd(v);
            sl<NovelTtsService>().setStopAtChapterEnd(v);
          },
        ),
        SwitchListTile.adaptive(
          secondary: const Icon(Icons.format_clear_rounded),
          title: const Text('Skip dialogue / markup'),
          subtitle: const Text('Strip tags and scene-break glyphs'),
          value: prefs.ttsSkipMarkers,
          onChanged: (v) {
            cubit.setTtsSkipMarkers(v);
            sl<NovelTtsService>().setSkipMarkers(v);
          },
        ),
        _SliderTile(
          icon: Icons.short_text_rounded,
          title: 'Paragraph pause',
          value: prefs.ttsParagraphPauseMs.toDouble(),
          min: 0,
          max: 2000,
          divisions: 20,
          formatter: (v) => '${v.round()} ms',
          onChanged: (v) {
            final ms = v.round();
            cubit.setTtsParagraphPauseMs(ms);
            sl<NovelTtsService>().setParagraphPauseMs(ms);
          },
        ),
      ],
    );
  }
}

/// Subtitle for the Voice tile. Branches on engine so a user who
/// switched to Neural sees the Piper voice (not a stale system-engine
/// name carried over from the other branch).
String _voiceSubtitle(NovelPrefs prefs, bool isNeural) {
  if (!isNeural) {
    return prefs.ttsVoiceName ?? 'Default for language';
  }
  final id = prefs.ttsNeuralVoiceId;
  if (id == null || id.isEmpty) return 'No voice downloaded yet';
  return VoiceCatalog.byId(id)?.displayName ?? id;
}

/// Bottom sheet that lets the user flip between the system and neural
/// TTS engines. Selecting `neural` when no voice is installed routes
/// the user straight to the voice manager so they can download one
/// immediately — otherwise they'd hit silent speech and have to hunt
/// for the right screen themselves.
Future<void> _openEnginePicker(
  BuildContext context,
  TtsEngine current,
) async {
  final cubit = context.read<NovelPrefsCubit>();
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (ctx) {
      return SettingsSheetShell(
        title: 'TTS engine',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.record_voice_over_outlined),
              title: const Text('System'),
              subtitle: const Text(
                'Built-in OS voices. Free, always available.',
              ),
              trailing: current == TtsEngine.system
                  ? Icon(Icons.check, color: Theme.of(ctx).colorScheme.primary)
                  : null,
              onTap: () {
                cubit.setTtsEngine(TtsEngine.system);
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              leading: const Icon(Icons.auto_awesome_outlined),
              title: const Text('Neural'),
              subtitle: const Text(
                'Premium, fully on-device. Requires a downloaded voice.',
              ),
              trailing: current == TtsEngine.neural
                  ? Icon(Icons.check, color: Theme.of(ctx).colorScheme.primary)
                  : null,
              onTap: () {
                cubit.setTtsEngine(TtsEngine.neural);
                Navigator.pop(ctx);
                // No installed neural voice yet — drop the user on
                // the manager so they can pick + download one in one
                // continuous gesture.
                final installed = sl<VoicesRepository>().installedIds();
                if (installed.isEmpty) {
                  context.push('/settings/tts/voices');
                }
              },
            ),
          ],
        ),
      );
    },
  );
}

/// Inline slider row that fits the [SettingsCard] visual style. We keep
/// this private to the screen so it stays out of the public widget API —
/// other screens use the modal `openSliderDialog` pattern instead.
class _SliderTile extends StatelessWidget {
  const _SliderTile({
    required this.icon,
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.formatter,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String Function(double) formatter;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.color;
    final clamped = value.clamp(min, max);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, color: muted, size: 22),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Text(
                formatter(clamped),
                style: TextStyle(color: muted, fontSize: 13),
              ),
            ],
          ),
          Slider(
            value: clamped,
            min: min,
            max: max,
            divisions: divisions,
            label: formatter(clamped),
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}
