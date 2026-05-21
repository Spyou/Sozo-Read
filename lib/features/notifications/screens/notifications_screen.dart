import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import '../../../core/services/image_cache_manager.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hive/hive.dart';

import '../../../core/di/injection.dart';
import '../../../core/repository/notifications_repository.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/app_snack.dart';
import '../../../core/widgets/state_views.dart';

/// `/notifications` — persistent inbox of new-chapter alerts (and future
/// event types). Mirrors the OS notification stream so a dismissed
/// notification doesn't mean lost information.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  StreamSubscription<BoxEvent>? _sub;

  NotificationsRepository get _repo => sl<NotificationsRepository>();

  @override
  void initState() {
    super.initState();
    _sub = _repo.watch().listen((_) {
      if (mounted) setState(() {});
    });
    // Mark every visible notification as read once the screen opens —
    // that's what "clears" the unread bell badge.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _repo.markAllRead();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _clearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Clear all notifications?'),
        content: const Text(
          'This only removes them from the inbox. Your library and '
          'reading progress are not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Clear all',
              style: TextStyle(color: AppColors.primary),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _repo.clear();
  }

  void _open(AppNotification n) {
    if (n.sourceId == null || n.bookId == null) return;
    context.pushNamed(
      'detail',
      pathParameters: {'sourceId': n.sourceId!, 'bookId': n.bookId!},
    );
  }

  Future<void> _delete(AppNotification n) async {
    final messenger = ScaffoldMessenger.of(context);
    await _repo.delete(n.id);
    messenger.showAppSnack(
      SnackBar(content: Text('Removed "${n.title}"')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = _repo.getAll();
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          if (items.isNotEmpty)
            PopupMenuButton<String>(
              color: AppColors.surface,
              onSelected: (v) {
                if (v == 'clear') _clearAll();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'clear', child: Text('Clear all')),
              ],
            ),
        ],
      ),
      body: items.isEmpty
          ? const EmptyView(
              icon: Icons.notifications_none_rounded,
              message:
                  "No notifications yet.\nYou'll see new chapters here when "
                  'your library updates.',
            )
          : ListView.separated(
              itemCount: items.length,
              separatorBuilder: (_, _) =>
                  const Divider(height: 1, color: AppColors.divider),
              itemBuilder: (_, i) {
                final n = items[i];
                return Dismissible(
                  key: ValueKey(n.id),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    color: AppColors.primary.withValues(alpha: 0.18),
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 18),
                    child: const Icon(Icons.delete_outline_rounded,
                        color: AppColors.primary, size: 22),
                  ),
                  onDismissed: (_) => _delete(n),
                  child: _NotificationRow(
                    notification: n,
                    onTap: () => _open(n),
                  ),
                );
              },
            ),
    );
  }
}

class _NotificationRow extends StatelessWidget {
  const _NotificationRow({required this.notification, required this.onTap});
  final AppNotification notification;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final n = notification;
    return ListTile(
      dense: true,
      onTap: onTap,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      leading: SizedBox(
        width: 44,
        height: 60,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: (n.coverUrl != null && n.coverUrl!.isNotEmpty)
              ? CachedNetworkImage(
                  cacheManager: appImageCacheManager,
                  imageUrl: n.coverUrl!,
                  fit: BoxFit.cover,
                  placeholder: (_, _) => Container(color: AppColors.card),
                  errorWidget: (_, _, _) =>
                      _placeholder(Icons.broken_image_outlined),
                )
              : _placeholder(Icons.notifications_active_outlined),
        ),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              n.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 14,
                fontWeight: n.isRead ? FontWeight.w500 : FontWeight.w700,
              ),
            ),
          ),
          if (!n.isRead)
            Container(
              width: 6,
              height: 6,
              margin: const EdgeInsets.only(left: 8),
              decoration: const BoxDecoration(
                color: AppColors.primary,
                shape: BoxShape.circle,
              ),
            ),
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(
          '${n.body}  ·  ${_relativeTime(n.createdAt)}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: AppColors.textTertiary,
            fontSize: 12,
          ),
        ),
      ),
    );
  }

  Widget _placeholder(IconData icon) {
    return Container(
      color: AppColors.card,
      alignment: Alignment.center,
      child: Icon(icon, size: 18, color: AppColors.textTertiary),
    );
  }

  /// Inlined to avoid importing intl just for one util.
  String _relativeTime(DateTime ts) {
    final diff = DateTime.now().difference(ts);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    // Older entries: spell out month/day.
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[ts.month - 1]} ${ts.day}';
  }
}
