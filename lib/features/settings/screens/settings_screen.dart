import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/di/injection.dart';
import '../../../core/repository/provider_repository.dart';
import '../../../core/state/active_source_cubit.dart';
import '../../../core/state/novel_prefs_cubit.dart';
import '../../../core/state/theme_cubit.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/source_picker.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider.value(value: sl<ActiveSourceCubit>()),
        BlocProvider.value(value: sl<ThemeCubit>()),
        BlocProvider.value(value: sl<NovelPrefsCubit>()),
      ],
      child: const _SettingsView(),
    );
  }
}

class _SettingsView extends StatefulWidget {
  const _SettingsView();
  @override
  State<_SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<_SettingsView> {
  Future<int>? _cacheSizeFuture;

  @override
  void initState() {
    super.initState();
    _cacheSizeFuture = _computeCacheSize();
  }

  void _refreshCacheSize() {
    setState(() => _cacheSizeFuture = _computeCacheSize());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const _SectionHeader('Source'),
          _SourceTile(),
          const _Divider(),

          const _SectionHeader('Appearance'),
          BlocBuilder<ThemeCubit, ThemeSettings>(
            builder: (context, s) => Column(
              children: [
                _Tile(
                  icon: Icons.brightness_6_outlined,
                  title: 'Theme',
                  subtitle: _themeLabel(s.mode),
                  onTap: () => _openThemeSheet(context, s.mode),
                ),
                _Tile(
                  icon: Icons.palette_outlined,
                  title: 'Accent color',
                  subtitle: _accentLabel(s.accent),
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
                  onTap: () => _openAccentSheet(context, s.accent),
                ),
              ],
            ),
          ),
          const _Divider(),

          const _SectionHeader('Reader'),
          _Tile(
            icon: Icons.swap_vert_rounded,
            title: 'Reading direction',
            subtitle: 'Vertical (Webtoon)',
            onTap: () => _comingSoon(context, 'Reading direction'),
          ),
          const _Divider(),

          const _SectionHeader('Novel Reader'),
          BlocBuilder<NovelPrefsCubit, NovelPrefs>(
            builder: (context, p) => Column(
              children: [
                _Tile(
                  icon: Icons.format_size_rounded,
                  title: 'Font size',
                  subtitle: '${p.fontSize.toStringAsFixed(0)} pt',
                  onTap: () => _openSliderDialog(
                    context,
                    title: 'Font size',
                    value: p.fontSize,
                    min: 12,
                    max: 28,
                    divisions: 16,
                    formatter: (v) => '${v.toStringAsFixed(0)} pt',
                    onChanged: context.read<NovelPrefsCubit>().setFontSize,
                  ),
                ),
                _Tile(
                  icon: Icons.format_line_spacing_rounded,
                  title: 'Line height',
                  subtitle: p.lineHeight.toStringAsFixed(2),
                  onTap: () => _openSliderDialog(
                    context,
                    title: 'Line height',
                    value: p.lineHeight,
                    min: 1.2,
                    max: 2.2,
                    divisions: 20,
                    formatter: (v) => v.toStringAsFixed(2),
                    onChanged: context.read<NovelPrefsCubit>().setLineHeight,
                  ),
                ),
                _Tile(
                  icon: Icons.format_indent_increase_rounded,
                  title: 'Margin',
                  subtitle: '${p.horizontalMargin.toStringAsFixed(0)} px',
                  onTap: () => _openSliderDialog(
                    context,
                    title: 'Horizontal margin',
                    value: p.horizontalMargin,
                    min: 8,
                    max: 40,
                    divisions: 32,
                    formatter: (v) => '${v.toStringAsFixed(0)} px',
                    onChanged: context.read<NovelPrefsCubit>().setMargin,
                  ),
                ),
                _Tile(
                  icon: Icons.font_download_outlined,
                  title: 'Font family',
                  subtitle: p.fontFamily,
                  onTap: () => _openFontFamilySheet(context, p.fontFamily),
                ),
              ],
            ),
          ),
          const _Divider(),

          const _SectionHeader('Library'),
          _Tile(
            icon: Icons.history_rounded,
            title: 'Reading history',
            subtitle: 'See what you\'ve read',
            onTap: () => _comingSoon(context, 'Reading history'),
          ),
          const _Divider(),

          const _SectionHeader('Storage'),
          FutureBuilder<int>(
            future: _cacheSizeFuture,
            builder: (context, snap) {
              String subtitle;
              if (snap.connectionState != ConnectionState.done) {
                subtitle = 'calculating...';
              } else if (snap.hasError) {
                subtitle = 'unavailable';
              } else {
                subtitle = _formatBytes(snap.data ?? 0);
              }
              return _Tile(
                icon: Icons.sd_storage_outlined,
                title: 'Image cache',
                subtitle: subtitle,
              );
            },
          ),
          _Tile(
            icon: Icons.cleaning_services_rounded,
            title: 'Clear image cache',
            subtitle: 'Free up space',
            onTap: () => _clearCache(context),
          ),
          const _Divider(),

          const _SectionHeader('Providers'),
          _Tile(
            icon: Icons.extension_rounded,
            title: 'Manage providers',
            subtitle: 'Install, update, remove',
            onTap: () => context.pushNamed('sources'),
          ),
          const _Divider(),

          const _SectionHeader('About'),
          const _Tile(
            icon: Icons.info_outline,
            title: 'Sozo Read',
            subtitle: 'v1.0.0',
          ),
        ],
      ),
    );
  }

  // ---- helpers --------------------------------------------------------

  static String _themeLabel(ThemeMode m) {
    switch (m) {
      case ThemeMode.system:
        return 'System default';
      case ThemeMode.light:
        return 'Light';
      case ThemeMode.dark:
        return 'AMOLED Dark';
    }
  }

  static String _accentLabel(Color c) {
    // Map back to friendly names where possible.
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

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    return '${(mb / 1024).toStringAsFixed(2)} GB';
  }

  void _comingSoon(BuildContext context, String label) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$label - coming soon')),
    );
  }

  Future<void> _clearCache(BuildContext context) async {
    // CachedNetworkImage exposes evictFromCache(url) but no clear-all in its
    // public API; physically wipe the on-disk cache directory we previously
    // measured. Then ask the in-memory cache to drop everything too.
    try {
      final tmp = await getTemporaryDirectory();
      for (final name in ['libCachedImageData', 'cached_network_image']) {
        final dir = Directory('${tmp.path}/$name');
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
      }
    } catch (_) {
      // Best-effort.
    }
    await CachedNetworkImage.evictFromCache('');
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Image cache cleared')),
    );
    _refreshCacheSize();
  }

  /// Walks the cached_network_image directory under tmp and sums file sizes.
  Future<int> _computeCacheSize() async {
    try {
      final tmp = await getTemporaryDirectory();
      // cached_network_image / flutter_cache_manager stores under this name.
      final candidates = [
        Directory('${tmp.path}/libCachedImageData'),
        Directory('${tmp.path}/cached_network_image'),
      ];
      var total = 0;
      for (final dir in candidates) {
        if (!await dir.exists()) continue;
        await for (final entity in dir.list(recursive: true, followLinks: false)) {
          if (entity is File) {
            try {
              total += await entity.length();
            } catch (_) {
              // Skip unreadable files.
            }
          }
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  // ---- sheets / dialogs ----------------------------------------------

  Future<void> _openThemeSheet(BuildContext context, ThemeMode current) async {
    final cubit = context.read<ThemeCubit>();
    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return _SheetShell(
          title: 'Theme',
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final entry in const [
                (ThemeMode.system, 'System default', Icons.brightness_auto_rounded),
                (ThemeMode.light, 'Light', Icons.light_mode_rounded),
                (ThemeMode.dark, 'AMOLED Dark', Icons.dark_mode_rounded),
              ])
                ListTile(
                  leading: Icon(entry.$3),
                  title: Text(entry.$2),
                  trailing: entry.$1 == current
                      ? Icon(Icons.check, color: Theme.of(ctx).colorScheme.primary)
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

  Future<void> _openAccentSheet(BuildContext context, Color current) async {
    final cubit = context.read<ThemeCubit>();
    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return _SheetShell(
          title: 'Accent color',
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            child: Wrap(
              spacing: 14,
              runSpacing: 14,
              children: [
                for (final c in ThemeCubit.accentPalette)
                  _AccentSwatch(
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

  Future<void> _openFontFamilySheet(BuildContext context, String current) async {
    final cubit = context.read<NovelPrefsCubit>();
    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return _SheetShell(
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
                      ? Icon(Icons.check, color: Theme.of(ctx).colorScheme.primary)
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

  Future<void> _openSliderDialog(
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
              Text(formatter(current),
                  style: Theme.of(ctx).textTheme.headlineSmall),
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
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);
  final String label;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 8),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w700,
          fontSize: 11,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
    this.trailing,
  });
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      onTap: onTap,
      leading: Icon(icon, color: theme.textTheme.bodySmall?.color),
      title: Text(title),
      subtitle: subtitle != null
          ? Text(subtitle!,
              style: TextStyle(
                color: theme.textTheme.labelSmall?.color,
                fontSize: 12,
              ))
          : null,
      trailing: trailing ??
          (onTap != null
              ? Icon(Icons.chevron_right, color: theme.textTheme.labelSmall?.color)
              : null),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();
  @override
  Widget build(BuildContext context) =>
      Divider(height: 1, color: Theme.of(context).dividerColor);
}

class _SourceTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ActiveSourceCubit, String?>(
      builder: (context, active) {
        final providers = sl<ProviderRepository>().providers;
        final name = active ?? '(none selected)';
        return _Tile(
          icon: Icons.collections_bookmark_rounded,
          title: 'Active source',
          subtitle: name,
          onTap: providers.isEmpty ? null : () => showSourcePicker(context),
        );
      },
    );
  }
}

class _AccentSwatch extends StatelessWidget {
  const _AccentSwatch({
    required this.color,
    required this.selected,
    required this.onTap,
  });
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? Colors.white : Colors.transparent,
            width: 1.6,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: color.withValues(alpha: 0.45),
                    blurRadius: 10,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
        child: selected
            ? const Icon(Icons.check, color: Colors.white, size: 20)
            : null,
      ),
    );
  }
}

/// Common bottom-sheet shell that mirrors the manga reader's settings sheet:
/// rounded top, drag handle, surface fill.
class _SheetShell extends StatelessWidget {
  const _SheetShell({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 6),
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: (theme.textTheme.labelSmall?.color ??
                          AppColors.textTertiary)
                      .withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 8),
              child: Row(
                children: [
                  Text(title, style: theme.textTheme.titleLarge),
                ],
              ),
            ),
            child,
          ],
        ),
      ),
    );
  }
}
