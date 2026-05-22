import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/services/image_cache_manager.dart';
import '../../../core/storage/download_storage_locator.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/app_snack.dart';
import 'package:path_provider/path_provider.dart';

import '../cubit/storage_location_cubit.dart';
import '../widgets/settings_widgets.dart';

/// `/settings/storage` — image cache info + clear cache action.
class StorageSettingsScreen extends StatefulWidget {
  const StorageSettingsScreen({super.key});

  @override
  State<StorageSettingsScreen> createState() => _StorageSettingsScreenState();
}

class _StorageSettingsScreenState extends State<StorageSettingsScreen> {
  late Future<int> _cacheSizeFuture;

  @override
  void initState() {
    super.initState();
    _cacheSizeFuture = _computeCacheSize();
  }

  void _refresh() {
    setState(() => _cacheSizeFuture = _computeCacheSize());
  }

  Future<int> _computeCacheSize() async {
    try {
      final tmp = await getTemporaryDirectory();
      // Older builds wrote into `libCachedImageData` (cached_network_image's
      // DefaultCacheManager default). Current builds use our size-capped
      // `sozoread_image_cache`. Sum both so a user upgrading from an old
      // install sees the legacy bytes too and can wipe them.
      final candidates = [
        Directory('${tmp.path}/sozoread_image_cache'),
        Directory('${tmp.path}/libCachedImageData'),
        Directory('${tmp.path}/cached_network_image'),
      ];
      var total = 0;
      for (final dir in candidates) {
        if (!await dir.exists()) continue;
        await for (final entity
            in dir.list(recursive: true, followLinks: false)) {
          if (entity is File) {
            try {
              total += await entity.length();
            } catch (_) {/* unreadable */}
          }
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  Future<void> _clearCache() async {
    // Empty the size-capped cache via its own API so the SQLite index
    // and on-disk files stay in sync. (Manually removing the directory
    // would leave the index thinking entries still exist, which breaks
    // the next download.)
    try {
      await appImageCacheManager.emptyCache();
    } catch (_) {/* best-effort */}
    // Legacy directories from older builds aren't touched by the cache
    // manager — scrub them by hand. Safe even on first install (no-op
    // when the dirs don't exist).
    try {
      final tmp = await getTemporaryDirectory();
      for (final name in ['libCachedImageData', 'cached_network_image']) {
        final dir = Directory('${tmp.path}/$name');
        if (await dir.exists()) await dir.delete(recursive: true);
      }
    } catch (_) {/* best-effort */}
    // Drop in-memory image entries too so the visible UI re-fetches
    // (or shows placeholders) after the clear.
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showAppSnack(
      const SnackBar(content: Text('Image cache cleared')),
    );
    _refresh();
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    return '${(mb / 1024).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider<StorageLocationCubit>(
      create: (_) => StorageLocationCubit(),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Storage'),
          centerTitle: true,
        ),
        body: ListView(
          children: [
            const _DownloadLocationCard(),
            FutureBuilder<int>(
              future: _cacheSizeFuture,
              builder: (context, snap) {
                final String subtitle;
                if (snap.connectionState != ConnectionState.done) {
                  subtitle = '…';
                } else if (snap.hasError) {
                  subtitle = '—';
                } else {
                  subtitle = _formatBytes(snap.data ?? 0);
                }
                return SettingsCard(
                  children: [
                    SettingsTile(
                      icon: Icons.sd_storage_outlined,
                      title: 'Image cache',
                      subtitle: subtitle,
                    ),
                    SettingsTile(
                      icon: Icons.cleaning_services_rounded,
                      title: 'Clear image cache',
                      onTap: _clearCache,
                      destructive: true,
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Settings card group for the download-storage picker. Two rows:
///   1. "Download location" — shows the current path (or "Internal storage")
///      and on tap opens the SAF tree picker (Android only; iOS toasts).
///   2. "Migrate downloads" — only after the user picked a custom location.
///      Walks every completed entry and copies the bytes into the new tree.
class _DownloadLocationCard extends StatelessWidget {
  const _DownloadLocationCard();

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<StorageLocationCubit, StorageLocationState>(
      listener: (ctx, s) {
        final messenger = ScaffoldMessenger.of(ctx);
        if (s.phase == StorageLocationPhase.error && s.error != null) {
          messenger.showAppSnack(SnackBar(content: Text(s.error!)));
        } else if (s.phase == StorageLocationPhase.done) {
          final failed = s.failedEntries;
          final msg = failed == 0
              ? 'Migration complete — copied ${s.copied} pages.'
              : 'Migration finished with $failed entr${failed == 1 ? "y" : "ies"} marked for re-download.';
          messenger.showAppSnack(SnackBar(content: Text(msg)));
          ctx.read<StorageLocationCubit>().acknowledgeDone();
        }
      },
      builder: (ctx, s) {
        final cubit = ctx.read<StorageLocationCubit>();
        final migrating = s.phase == StorageLocationPhase.migrating;
        return SettingsCard(
          children: [
            SettingsTile(
              icon: Icons.folder_outlined,
              title: 'Download location',
              subtitle: s.currentLabel,
              onTap: migrating
                  ? null
                  : () async {
                      if (!DownloadStorageLocator.safSupported) {
                        ScaffoldMessenger.of(ctx).showAppSnack(
                          const SnackBar(
                            content:
                                Text('Available on Android only.'),
                          ),
                        );
                        return;
                      }
                      await cubit.pickLocation();
                    },
            ),
            if (s.hasCustomLocation && !migrating)
              SettingsTile(
                icon: Icons.restore_outlined,
                title: 'Use internal storage',
                subtitle: 'Reverts the location; existing files stay put.',
                onTap: () => cubit.resetToInternal(),
              ),
            if (s.hasCustomLocation && Platform.isAndroid)
              migrating
                  ? _MigrateProgressTile(state: s)
                  : SettingsTile(
                      icon: Icons.drive_file_move_outlined,
                      title: 'Migrate downloads to new location',
                      subtitle:
                          'Copies existing chapters into the picked folder.',
                      onTap: () => _confirmAndMigrate(ctx, cubit),
                    ),
          ],
        );
      },
    );
  }

  Future<void> _confirmAndMigrate(
    BuildContext context,
    StorageLocationCubit cubit,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Migrate downloads?'),
        content: const Text(
          'This will copy every downloaded chapter into the new folder. '
          'Pause or finish any in-progress downloads before continuing.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            child: const Text('Migrate'),
          ),
        ],
      ),
    );
    if (ok == true) {
      // ignore: discarded_futures
      cubit.migrate();
    }
  }
}

/// Inline progress row rendered in place of the migrate button while a
/// migration is running. Shows "copied / total" + a thin progress bar so
/// the user has feedback for what can be a long-running, network-free
/// operation on slow SD cards.
class _MigrateProgressTile extends StatelessWidget {
  const _MigrateProgressTile({required this.state});

  final StorageLocationState state;

  @override
  Widget build(BuildContext context) {
    final total = state.total == 0 ? 1 : state.total;
    final value = state.copied / total;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(Icons.cloud_sync_outlined,
                  size: 22, color: AppColors.textSecondary),
              SizedBox(width: 14),
              Text(
                'Migrating downloads…',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: state.total == 0 ? null : value,
              minHeight: 4,
              backgroundColor: AppColors.divider,
              valueColor:
                  const AlwaysStoppedAnimation<Color>(AppColors.primary),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '${state.copied} / ${state.total} pages',
            style:
                const TextStyle(color: AppColors.textTertiary, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
