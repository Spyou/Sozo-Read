import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/di/injection.dart';
import '../../../core/sync/library_sync_service.dart';

/// Surfaces the [LibrarySyncService] state in account UI: last-synced
/// relative time, a textual status (idle / syncing / error), a "Sync
/// now" button, and an error chip when the last attempt failed.
///
/// The widget owns a 30-second timer that just calls `setState` so the
/// relative time label refreshes without us having to bind to a clock
/// stream.
///
/// [margin] defaults to the same 20-horizontal inset used by the rest of
/// the Profile / Settings cards, but callers in already-padded layouts
/// can pass `EdgeInsets.zero` to flatten it.
class SyncStatusTile extends StatefulWidget {
  const SyncStatusTile({super.key, this.margin});

  final EdgeInsetsGeometry? margin;

  @override
  State<SyncStatusTile> createState() => _SyncStatusTileState();
}

class _SyncStatusTileState extends State<SyncStatusTile> {
  LibrarySyncService get _sync => sl<LibrarySyncService>();

  StreamSubscription<LibrarySyncStatus>? _sub;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _sub = _sync.statusStream.listen((_) {
      if (mounted) setState(() {});
    });
    // Periodically refresh the "x minutes ago" label without burning a
    // per-second timer.
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _onTap() async {
    if (_sync.status == LibrarySyncStatus.syncing) return;
    try {
      await _sync.refresh();
    } catch (_) {
      // The service flips its own status to error; nothing extra here.
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = _sync.status;
    final isSyncing = status == LibrarySyncStatus.syncing;
    final isError = status == LibrarySyncStatus.error;

    final muted = theme.textTheme.bodySmall?.color;
    final subtitle = _subtitleFor(status);

    return Container(
      margin: widget.margin ?? const EdgeInsets.fromLTRB(20, 4, 20, 0),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest
            .withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
            child: Row(
              children: [
                _StatusIcon(status: status, color: theme.colorScheme.primary),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Library sync',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: TextStyle(color: muted, fontSize: 13),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: isSyncing ? null : _onTap,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    minimumSize: const Size(0, 36),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: Text(isSyncing ? 'Syncing…' : 'Sync now'),
                ),
              ],
            ),
          ),
          if (isError) _ErrorChip(message: _sync.lastError),
        ],
      ),
    );
  }

  String _subtitleFor(LibrarySyncStatus status) {
    switch (status) {
      case LibrarySyncStatus.syncing:
        return 'Syncing…';
      case LibrarySyncStatus.error:
        // The chip below carries the detailed error; subtitle stays terse.
        return 'Last sync failed';
      case LibrarySyncStatus.idle:
        final at = _sync.lastSyncedAt;
        if (at == null) return 'Never synced';
        return 'Synced ${_relative(at)}';
    }
  }
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.status, required this.color});
  final LibrarySyncStatus status;
  final Color color;

  @override
  Widget build(BuildContext context) {
    switch (status) {
      case LibrarySyncStatus.syncing:
        return SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2.2, color: color),
        );
      case LibrarySyncStatus.error:
        return const Icon(
          Icons.cloud_off_rounded,
          color: Color(0xFFE57373),
          size: 22,
        );
      case LibrarySyncStatus.idle:
        return Icon(Icons.cloud_done_rounded, color: color, size: 22);
    }
  }
}

class _ErrorChip extends StatelessWidget {
  const _ErrorChip({this.message});
  final String? message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = (message == null || message!.isEmpty)
        ? 'Sync failed. Check your connection and try again.'
        : message!;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      decoration: BoxDecoration(
        color: const Color(0xFFE57373).withValues(alpha: 0.10),
        border: Border(
          top: BorderSide(
            color: theme.dividerColor.withValues(alpha: 0.4),
            width: 0.5,
          ),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.error_outline_rounded,
            color: Color(0xFFE57373),
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: Color(0xFFE57373),
                fontSize: 12.5,
                height: 1.3,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// Lightweight relative-time formatter. No `intl`/`timeago` dep, so we
/// roll the minimum buckets the UI actually needs.
String _relative(DateTime when) {
  final diff = DateTime.now().difference(when);
  if (diff.inSeconds < 30) return 'just now';
  if (diff.inMinutes < 1) return '${diff.inSeconds} seconds ago';
  if (diff.inMinutes < 60) {
    final m = diff.inMinutes;
    return '$m ${m == 1 ? 'minute' : 'minutes'} ago';
  }
  if (diff.inHours < 24) {
    final h = diff.inHours;
    return '$h ${h == 1 ? 'hour' : 'hours'} ago';
  }
  if (diff.inDays < 7) {
    final d = diff.inDays;
    return '$d ${d == 1 ? 'day' : 'days'} ago';
  }
  // Older than a week — drop to a date stamp.
  final mm = when.month.toString().padLeft(2, '0');
  final dd = when.day.toString().padLeft(2, '0');
  return '$mm/$dd/${when.year}';
}
