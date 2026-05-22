import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/di/injection.dart';
import '../../../core/state/manga_prefs_cubit.dart';
import '../../../core/state/notifications_prefs_cubit.dart';
import '../../../core/state/novel_prefs_cubit.dart';
import '../widgets/settings_dialogs.dart';
import '../widgets/settings_widgets.dart';

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
                  ],
                ),
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
