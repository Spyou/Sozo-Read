import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/state/manga_prefs_cubit.dart';
import '../../../core/state/novel_prefs_cubit.dart';
import '../../../core/state/theme_cubit.dart';
import 'settings_widgets.dart';

/// Bottom sheets + dialogs shared by the top-level Settings screen and the
/// subpages. Kept as top-level functions (not methods on a State) so they
/// can be invoked from any context, including the new subpage screens.

Future<void> openThemeSheet(BuildContext context, ThemeMode current) async {
  final cubit = context.read<ThemeCubit>();
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (ctx) {
      return SettingsSheetShell(
        title: 'Theme',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final entry in const [
              (ThemeMode.system, 'System default',
                  Icons.brightness_auto_rounded),
              (ThemeMode.light, 'Light', Icons.light_mode_rounded),
              (ThemeMode.dark, 'AMOLED Dark', Icons.dark_mode_rounded),
            ])
              ListTile(
                leading: Icon(entry.$3),
                title: Text(entry.$2),
                trailing: entry.$1 == current
                    ? Icon(Icons.check,
                        color: Theme.of(ctx).colorScheme.primary)
                    : null,
                onTap: () {
                  cubit.setMode(entry.$1);
                  Navigator.pop(ctx);
                },
              ),
          ],
        ),
      );
    },
  );
}

Future<void> openAccentSheet(BuildContext context, Color current) async {
  final cubit = context.read<ThemeCubit>();
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (ctx) {
      return SettingsSheetShell(
        title: 'Accent color',
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Wrap(
            spacing: 14,
            runSpacing: 14,
            children: [
              for (final c in ThemeCubit.accentPalette)
                AccentSwatch(
                  color: c,
                  selected: c.toARGB32() == current.toARGB32(),
                  onTap: () {
                    cubit.setAccent(c);
                    Navigator.pop(ctx);
                  },
                ),
            ],
          ),
        ),
      );
    },
  );
}

Future<void> openFontFamilySheet(BuildContext context, String current) async {
  final cubit = context.read<NovelPrefsCubit>();
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (ctx) {
      return SettingsSheetShell(
        title: 'Font family',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final f in NovelPrefsCubit.familyOptions)
              ListTile(
                title: Text(
                  f,
                  style: NovelPrefsCubit.applyFontLabel(
                    f,
                    const TextStyle(),
                  ),
                ),
                trailing: f == current
                    ? Icon(Icons.check,
                        color: Theme.of(ctx).colorScheme.primary)
                    : null,
                onTap: () {
                  cubit.setFontFamily(f);
                  Navigator.pop(ctx);
                },
              ),
          ],
        ),
      );
    },
  );
}

Future<void> openMangaDirectionSheet(
  BuildContext context,
  MangaReadingDirection current,
) async {
  final cubit = context.read<MangaPrefsCubit>();
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (ctx) {
      return SettingsSheetShell(
        title: 'Reading direction',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final entry in const [
              (
                MangaReadingDirection.vertical,
                Icons.swap_vert_rounded,
              ),
              (
                MangaReadingDirection.horizontalLtr,
                Icons.east_rounded,
              ),
              (
                MangaReadingDirection.horizontalRtl,
                Icons.west_rounded,
              ),
            ])
              ListTile(
                leading: Icon(entry.$2),
                title: Text(MangaPrefsCubit.directionLabel(entry.$1)),
                trailing: entry.$1 == current
                    ? Icon(Icons.check,
                        color: Theme.of(ctx).colorScheme.primary)
                    : null,
                onTap: () {
                  cubit.setDirection(entry.$1);
                  Navigator.pop(ctx);
                },
              ),
          ],
        ),
      );
    },
  );
}

Future<void> openMangaColorFilterSheet(
  BuildContext context,
  MangaColorFilter current,
) async {
  final cubit = context.read<MangaPrefsCubit>();
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (ctx) {
      return SettingsSheetShell(
        title: 'Color filter',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final entry in const [
              (MangaColorFilter.none, Icons.do_not_disturb_alt_rounded),
              (MangaColorFilter.sepia, Icons.wb_iridescent_rounded),
              (MangaColorFilter.invert, Icons.invert_colors_rounded),
              (MangaColorFilter.blueLight, Icons.nightlight_round),
            ])
              ListTile(
                leading: Icon(entry.$2),
                title: Text(colorFilterLabel(entry.$1)),
                trailing: entry.$1 == current
                    ? Icon(Icons.check,
                        color: Theme.of(ctx).colorScheme.primary)
                    : null,
                onTap: () {
                  cubit.setColorFilter(entry.$1);
                  Navigator.pop(ctx);
                },
              ),
          ],
        ),
      );
    },
  );
}

Future<void> openMangaAutoScrollSheet(
  BuildContext context,
  MangaAutoScroll current,
) async {
  final cubit = context.read<MangaPrefsCubit>();
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (ctx) {
      return SettingsSheetShell(
        title: 'Auto-scroll',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final entry in const [
              (MangaAutoScroll.off, Icons.pause_circle_outline_rounded),
              (MangaAutoScroll.slow, Icons.speed_rounded),
              (MangaAutoScroll.medium, Icons.speed_rounded),
              (MangaAutoScroll.fast, Icons.speed_rounded),
            ])
              ListTile(
                leading: Icon(entry.$2),
                title: Text(autoScrollLabel(entry.$1)),
                trailing: entry.$1 == current
                    ? Icon(Icons.check,
                        color: Theme.of(ctx).colorScheme.primary)
                    : null,
                onTap: () {
                  cubit.setAutoScroll(entry.$1);
                  Navigator.pop(ctx);
                },
              ),
          ],
        ),
      );
    },
  );
}

Future<void> openMangaImageQualitySheet(
  BuildContext context,
  MangaImageQuality current,
) async {
  final cubit = context.read<MangaPrefsCubit>();
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (ctx) {
      return SettingsSheetShell(
        title: 'Image quality',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final entry in const [
              (MangaImageQuality.auto, Icons.auto_awesome_rounded),
              (MangaImageQuality.high, Icons.high_quality_rounded),
              (MangaImageQuality.low, Icons.sd_rounded),
            ])
              ListTile(
                leading: Icon(entry.$2),
                title: Text(imageQualityLabel(entry.$1)),
                trailing: entry.$1 == current
                    ? Icon(Icons.check,
                        color: Theme.of(ctx).colorScheme.primary)
                    : null,
                onTap: () {
                  cubit.setImageQuality(entry.$1);
                  Navigator.pop(ctx);
                },
              ),
          ],
        ),
      );
    },
  );
}

Future<void> openMangaDoublePageModeSheet(
  BuildContext context,
  MangaDoublePageMode current,
) async {
  final cubit = context.read<MangaPrefsCubit>();
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (ctx) {
      return SettingsSheetShell(
        title: 'Double page',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final entry in const [
              (MangaDoublePageMode.auto, Icons.auto_awesome_rounded),
              (MangaDoublePageMode.single, Icons.crop_portrait_rounded),
              (MangaDoublePageMode.dual, Icons.menu_book_rounded),
            ])
              ListTile(
                leading: Icon(entry.$2),
                title: Text(doublePageModeLabel(entry.$1)),
                trailing: entry.$1 == current
                    ? Icon(Icons.check,
                        color: Theme.of(ctx).colorScheme.primary)
                    : null,
                onTap: () {
                  cubit.setDoublePageMode(entry.$1);
                  Navigator.pop(ctx);
                },
              ),
          ],
        ),
      );
    },
  );
}

Future<void> openMangaFitModeSheet(
  BuildContext context,
  MangaFitMode current, {
  bool fitHeightAvailable = true,
}) async {
  final cubit = context.read<MangaPrefsCubit>();
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (ctx) {
      return SettingsSheetShell(
        title: 'Image fit',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final entry in [
              (MangaFitMode.fitScreen, Icons.fit_screen_rounded),
              (MangaFitMode.fitWidth, Icons.swap_horiz_rounded),
              if (fitHeightAvailable)
                (MangaFitMode.fitHeight, Icons.swap_vert_rounded),
            ])
              ListTile(
                leading: Icon(entry.$2),
                title: Text(fitModeLabel(entry.$1)),
                trailing: entry.$1 == current
                    ? Icon(Icons.check,
                        color: Theme.of(ctx).colorScheme.primary)
                    : null,
                onTap: () {
                  cubit.setFitMode(entry.$1);
                  Navigator.pop(ctx);
                },
              ),
          ],
        ),
      );
    },
  );
}

Future<void> openMangaOrientationLockSheet(
  BuildContext context,
  MangaOrientationLock current,
) async {
  final cubit = context.read<MangaPrefsCubit>();
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (ctx) {
      return SettingsSheetShell(
        title: 'Lock orientation',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final entry in const [
              (MangaOrientationLock.auto, Icons.screen_rotation_rounded),
              (MangaOrientationLock.portrait, Icons.stay_current_portrait_rounded),
              (MangaOrientationLock.landscape, Icons.stay_current_landscape_rounded),
            ])
              ListTile(
                leading: Icon(entry.$2),
                title: Text(orientationLockLabel(entry.$1)),
                trailing: entry.$1 == current
                    ? Icon(Icons.check,
                        color: Theme.of(ctx).colorScheme.primary)
                    : null,
                onTap: () {
                  cubit.setOrientationLock(entry.$1);
                  Navigator.pop(ctx);
                },
              ),
          ],
        ),
      );
    },
  );
}

Future<void> openSliderDialog(
  BuildContext context, {
  required String title,
  required double value,
  required double min,
  required double max,
  required int divisions,
  required String Function(double) formatter,
  required void Function(double) onChanged,
}) async {
  var current = value;
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              formatter(current),
              style: Theme.of(ctx).textTheme.headlineSmall,
            ),
            Slider(
              value: current,
              min: min,
              max: max,
              divisions: divisions,
              label: formatter(current),
              onChanged: (v) {
                setLocal(() => current = v);
                onChanged(v);
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Done'),
          ),
        ],
      ),
    ),
  );
}

String themeLabel(ThemeMode m) {
  switch (m) {
    case ThemeMode.system:
      return 'System';
    case ThemeMode.light:
      return 'Light';
    case ThemeMode.dark:
      return 'AMOLED Dark';
  }
}

String colorFilterLabel(MangaColorFilter f) {
  switch (f) {
    case MangaColorFilter.none:
      return 'None';
    case MangaColorFilter.sepia:
      return 'Sepia';
    case MangaColorFilter.invert:
      return 'Invert';
    case MangaColorFilter.blueLight:
      return 'Blue light reducer';
  }
}

String autoScrollLabel(MangaAutoScroll a) {
  switch (a) {
    case MangaAutoScroll.off:
      return 'Off';
    case MangaAutoScroll.slow:
      return 'Slow';
    case MangaAutoScroll.medium:
      return 'Medium';
    case MangaAutoScroll.fast:
      return 'Fast';
  }
}

String imageQualityLabel(MangaImageQuality q) {
  switch (q) {
    case MangaImageQuality.auto:
      return 'Auto';
    case MangaImageQuality.high:
      return 'High';
    case MangaImageQuality.low:
      return 'Low';
  }
}

String doublePageModeLabel(MangaDoublePageMode m) {
  switch (m) {
    case MangaDoublePageMode.auto:
      return 'Auto (landscape / tablet)';
    case MangaDoublePageMode.single:
      return 'Single page';
    case MangaDoublePageMode.dual:
      return 'Two pages';
  }
}

String fitModeLabel(MangaFitMode m) {
  switch (m) {
    case MangaFitMode.fitWidth:
      return 'Fit width';
    case MangaFitMode.fitHeight:
      return 'Fit height';
    case MangaFitMode.fitScreen:
      return 'Fit screen';
  }
}

String orientationLockLabel(MangaOrientationLock o) {
  switch (o) {
    case MangaOrientationLock.auto:
      return 'Auto';
    case MangaOrientationLock.portrait:
      return 'Portrait';
    case MangaOrientationLock.landscape:
      return 'Landscape';
  }
}

String accentLabel(Color c) {
  const named = {
    0xFFE50914: 'Red',
    0xFFFF6B35: 'Orange',
    0xFFFFC107: 'Amber',
    0xFF4CAF50: 'Green',
    0xFF00BCD4: 'Teal',
    0xFF2196F3: 'Blue',
    0xFF9C27B0: 'Purple',
    0xFFE91E63: 'Pink',
  };
  return named[c.toARGB32()] ?? 'Custom';
}
