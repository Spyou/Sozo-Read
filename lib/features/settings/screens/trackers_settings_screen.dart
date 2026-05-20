import 'package:flutter/material.dart';
import '../../../core/widgets/app_snack.dart';
import 'package:go_router/go_router.dart';

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

  /// Tracker IDs the user has just tapped Connect on. Used to show a
  /// "Completing sign-in…" indicator until the OAuth round-trip lands and
  /// [Tracker.authChanges] fires.
  final Set<String> _connecting = <String>{};

  /// Per-tracker previous `isAuthenticated` value, so we can detect a
  /// transition into "logged in" and show a success snackbar.
  late final Map<String, bool> _wasAuthed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _wasAuthed = {
      for (final t in _repo.trackers) t.id: t.isAuthenticated,
    };
    for (final tracker in _repo.trackers) {
      tracker.authChanges.addListener(_onTrackerAuthChanged);
    }
  }

  @override
  void dispose() {
    for (final tracker in _repo.trackers) {
      tracker.authChanges.removeListener(_onTrackerAuthChanged);
    }
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _onTrackerAuthChanged() {
    if (!mounted) return;
    // Walk every tracker to spot the one whose state flipped — fire the
    // user-facing snackbar only on the false → true transition. The
    // notifier doesn't tell us WHICH tracker fired, so we diff.
    for (final tracker in _repo.trackers) {
      final before = _wasAuthed[tracker.id] ?? false;
      final now = tracker.isAuthenticated;
      if (now && !before) {
        // Successful connect — clear the "connecting" indicator and
        // celebrate. Username may still be in-flight; the row will
        // re-render again when the next authChanges fires.
        _connecting.remove(tracker.id);
        ScaffoldMessenger.of(context).showAppSnack(
          SnackBar(
            content: Text('Connected to ${tracker.displayName}'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
      _wasAuthed[tracker.id] = now;
    }
    setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Safety net: if the deep-link path failed for some reason but the
    // app resumed after the browser handed control back, force a rebuild
    // so any pending "Completing sign-in…" indicator clears once the
    // user's been gone long enough to assume the flow didn't complete.
    if (state == AppLifecycleState.resumed) {
      if (mounted) setState(() {});
    }
  }

  Future<void> _onConnect(Tracker tracker) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _connecting.add(tracker.id));
    try {
      await tracker.startLogin();
    } catch (e) {
      if (!mounted) return;
      setState(() => _connecting.remove(tracker.id));
      // Surface the "no client ID configured" case as a clear, actionable
      // message rather than a stack trace. Both AniList and MAL throw a
      // typed exception with `ClientIdMissing` in the class name when
      // the env var is unset.
      final msg = e.toString().contains('ClientIdMissing')
          ? "${tracker.displayName} isn't configured yet — set the client "
              "ID in .env"
          : "Couldn't open browser: $e";
      messenger.showAppSnack(SnackBar(content: Text(msg)));
    }
    // We DON'T clear _connecting here on success — wait for the OAuth
    // round-trip to land in [_onTrackerAuthChanged]. If the user cancels
    // and never completes, the next foreground / Connect tap clears it.
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
        // Custom back so a cold-start OAuth callback (which lands the user
        // directly on this screen with no navigator stack underneath) still
        // has a working back gesture — falls back to /settings.
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            if (context.canPop()) {
              context.pop();
            } else {
              context.go('/settings');
            }
          },
        ),
      ),
      body: ListView(
        children: [
          const _TrackersHeaderCard(),
          SettingsCard(
            children: [
              for (final tracker in trackers)
                _TrackerRow(
                  tracker: tracker,
                  connecting: _connecting.contains(tracker.id),
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
    required this.connecting,
    required this.onConnect,
    required this.onDisconnect,
  });

  final Tracker tracker;

  /// True while the OAuth round-trip is in flight — the row swaps the
  /// trailing button for a spinner + "Completing sign-in…" subtitle so
  /// the user knows the app is waiting on the browser callback.
  final bool connecting;
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
        : connecting
            ? 'Completing sign-in…'
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
          else if (connecting)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  color: AppColors.primary,
                ),
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
