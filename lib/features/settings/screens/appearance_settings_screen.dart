import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/di/injection.dart';
import '../../../core/state/theme_cubit.dart';
import '../widgets/settings_dialogs.dart' show openAccentSheet, accentLabel;
import '../widgets/settings_widgets.dart';

/// `/settings/appearance` — Theme + Accent color.
class AppearanceSettingsScreen extends StatelessWidget {
  const AppearanceSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider.value(
      value: sl<ThemeCubit>(),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Appearance'),
          centerTitle: true,
        ),
        body: BlocBuilder<ThemeCubit, ThemeSettings>(
          builder: (context, s) {
            return ListView(
              children: [
                SettingsCard(
                  children: [
                    // Light mode is disabled for v1 — the light palette
                    // hasn't been polished yet. The tile stays visible (with
                    // onTap: null so it greys out and no chevron is drawn) so
                    // users know the affordance is planned. Restore the
                    // openThemeSheet onTap once Light is ready to ship.
                    const SettingsTile(
                      icon: Icons.brightness_6_outlined,
                      title: 'Theme',
                      subtitle: 'Dark (light mode coming soon)',
                    ),
                    SettingsTile(
                      icon: Icons.palette_outlined,
                      title: 'Accent color',
                      subtitle: accentLabel(s.accent),
                      trailing: Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          color: s.accent,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.18),
                            width: 1,
                          ),
                        ),
                      ),
                      onTap: () => openAccentSheet(context, s.accent),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
