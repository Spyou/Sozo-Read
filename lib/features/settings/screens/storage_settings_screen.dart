import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

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
      final candidates = [
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
    try {
      final tmp = await getTemporaryDirectory();
      for (final name in ['libCachedImageData', 'cached_network_image']) {
        final dir = Directory('${tmp.path}/$name');
        if (await dir.exists()) await dir.delete(recursive: true);
      }
    } catch (_) {/* best-effort */}
    await CachedNetworkImage.evictFromCache('');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Storage'),
        centerTitle: true,
      ),
      body: ListView(
        children: [
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
    );
  }
}
