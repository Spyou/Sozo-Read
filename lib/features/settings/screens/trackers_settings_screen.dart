import 'package:flutter/material.dart';

import '../../../core/di/injection.dart';
import '../../../core/repository/tracker_repository.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/trackers/tracker.dart';
import '../widgets/settings_widgets.dart';

/// `/settings/trackers` — Connect / Disconnect AniList, MAL, ….
///
/// The OAuth flow is handed off to the system browser via
/// [Tracker.startLogin]. The actual token capture happens in the deep-link
/// callback (handled by the router), so this screen has nothing to await —
/// we just kick off the browser and rely on `didChangeAppLifecycleState`
/// to rebuild when the user returns to the app with the new token in hand.
class TrackersSettingsScreen extends StatefulWidget {
  const TrackersSettingsScreen({super.key});

  @override
  State<TrackersSettingsScreen> createState() => _TrackersSettingsScreenState();
}

class _TrackersSettingsScreenState extends State<TrackersSettingsScreen>
    with WidgetsBindingObserver {
  TrackerRepository get _repo => sl<TrackerRepository>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // On returning from the browser the deep-link handler may have just
    // captured a token — rebuild to reflect the freshly authenticated
    // tracker without making the user pull-to-refresh.
    if (state == AppLifecycleState.resumed) {
      if (mounted) setState(() {});
    }
  }

  Future<void> _onConnect(Tracker tracker) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Opening browser…'),
        duration: Duration(seconds: 2),
      ),
    );
    try {
      await tracker.startLogin();
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text("Couldn't open browser: $e")),
      );
    }
  }

  Future<void> _onDisconnect(Tracker tracker) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Disconnect ${tracker.displayName}?'),
        content: const Text(
          'Your local library is not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.primary,
            ),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await tracker.logout();
    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final trackers = _repo.trackers;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Trackers'),
        centerTitle: true,
      ),
      body: ListView(
        children: [
          const _TrackersHeaderCard(),
          SettingsCard(
            children: [
              for (final tracker in trackers)
                _TrackerRow(
                  tracker: tracker,
                  onConnect: () => _onConnect(tracker),
                  onDisconnect: () => _onDisconnect(tracker),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Explanatory header card pinned to the top of the trackers list. Mirrors
/// the visual weight of [SettingsCard] but with a slightly more prominent
/// fill so the explanation reads as "intro copy", not a tappable row.
class _TrackersHeaderCard extends StatelessWidget {
  const _TrackersHeaderCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.color;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppColors.primary.withValues(alpha: 0.22),
          width: 0.6,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.sync_alt_rounded,
            color: AppColors.primary,
            size: 22,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Linking your AniList or MyAnimeList account lets Sozo Read '
              'push your reading progress automatically. Your library on '
              'the remote service stays in sync as you read.',
              style: TextStyle(
                color: muted,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Single row inside the trackers [SettingsCard]. Built on top of the same
/// row layout primitives that [SettingsTile] uses but with a custom
/// trailing button (Connect / Disconnect) instead of a chevron.
class _TrackerRow extends StatelessWidget {
  const _TrackerRow({
    required this.tracker,
    required this.onConnect,
    required this.onDisconnect,
  });

  final Tracker tracker;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;

  IconData get _iconFor {
    switch (tracker.id) {
      case 'anilist':
        return Icons.bookmark_rounded;
      case 'mal':
        return Icons.menu_book_rounded;
      default:
        return Icons.link_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.color;
    final authed = tracker.isAuthenticated;
    final subtitle = authed
        ? 'Signed in as ${tracker.currentUserName ?? "—"}'
        : 'Not connected';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(_iconFor, color: muted, size: 22),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  tracker.displayName,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: muted,
                    fontSize: 13,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (authed)
            TextButton(
              onPressed: onDisconnect,
              style: TextButton.styleFrom(
                foregroundColor: AppColors.primary,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: const Size(0, 36),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text(
                'Disconnect',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            )
          else
            ElevatedButton(
              onPressed: onConnect,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                minimumSize: const Size(0, 36),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                elevation: 0,
              ),
              child: const Text(
                'Connect',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
        ],
      ),
    );
  }
}
