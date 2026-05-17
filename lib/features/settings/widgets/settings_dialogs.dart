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
                  style: TextStyle(
                    fontFamily: NovelPrefsCubit.resolveFamily(f),
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
