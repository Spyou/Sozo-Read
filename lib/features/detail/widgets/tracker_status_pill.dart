import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/di/injection.dart';
import '../../../core/repository/tracker_repository.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/trackers/tracker.dart';
import '../../../core/trackers/tracker_entry.dart';
import '../../../core/trackers/tracker_match.dart';

/// Compact pill row that sits above the chapters list on the detail screen.
///
/// On first mount we ensure an auto-match exists for this local series, then
/// render one [_TrackerChip] per linked tracker. Tapping a chip opens an
/// edit sheet with status / score / open-on-web / unlink actions.
///
/// The widget renders nothing when:
///   * The user has no authenticated trackers at all, or
///   * Auto-match attempted and produced no matches (quiet failure).
class TrackerStatusPill extends StatefulWidget {
  const TrackerStatusPill({
    super.key,
    required this.sourceId,
    required this.bookId,
    required this.localTitle,
  });

  final String sourceId;
  final String bookId;
  final String localTitle;

  @override
  State<TrackerStatusPill> createState() => _TrackerStatusPillState();
}

class _TrackerStatusPillState extends State<TrackerStatusPill> {
  TrackerRepository get _repo => sl<TrackerRepository>();

  /// True while [TrackerRepository.ensureMatched] is in flight on first
  /// mount — used to differentiate "looking up" from "no matches".
  bool _matching = false;

  /// Guards the "no match found" snackbar so it fires at most once per
  /// widget lifetime — without this, every rebuild after the match call
  /// would re-trigger the toast.
  bool _noMatchToastShown = false;

  /// Cached remote entries per match key. Populated lazily when each chip
  /// is built and refreshed after every setStatus / setScore.
  final Map<String, TrackerEntry?> _entryCache = {};
  final Set<String> _entryLoading = {};

  @override
  void initState() {
    super.initState();
    // Listen on every tracker's auth changes so the pill appears the moment
    // the user finishes the OAuth round-trip from the trackers settings
    // screen — even if the detail screen was already mounted in the back
    // stack at the time.
    for (final tracker in _repo.trackers) {
      tracker.authChanges.addListener(_onAuthChanged);
    }
    _kickOffMatch();
  }

  @override
  void dispose() {
    for (final tracker in _repo.trackers) {
      tracker.authChanges.removeListener(_onAuthChanged);
    }
    super.dispose();
  }

  void _onAuthChanged() {
    if (!mounted) return;
    // A tracker just became authenticated — re-run the auto-match in case
    // we previously bailed out due to no authed trackers. setState in the
    // finally clause of _kickOffMatch will refresh us.
    setState(() {});
    _kickOffMatch();
  }

  Future<void> _kickOffMatch() async {
    if (!_repo.hasAuthenticatedTracker) return;
    // If we already have matches cached for this book skip the network call
    // — ensureMatched is idempotent but it costs a few ms to walk the box.
    final existing = _repo.matchesFor(widget.sourceId, widget.bookId);
    if (existing.isNotEmpty) return;
    setState(() => _matching = true);
    try {
      await _repo.ensureMatched(
        sourceId: widget.sourceId,
        bookId: widget.bookId,
        localTitle: widget.localTitle,
      );
    } catch (_) {
      // Quiet failure — chip just won't render.
    } finally {
      if (mounted) setState(() => _matching = false);
      _maybeFireNoMatchToast();
    }
  }

  /// If auto-match ran across every authed tracker and none produced a
  /// link, surface a one-shot snackbar so the user knows the chip isn't
  /// going to appear and why. Without this the silent-empty state would
  /// look like the tracker is just broken.
  void _maybeFireNoMatchToast() {
    if (!mounted) return;
    if (_noMatchToastShown) return;
    final matches = _repo.matchesFor(widget.sourceId, widget.bookId);
    if (matches.isNotEmpty) return;
    final names = _repo.authenticatedTrackers
        .map((t) => t.displayName)
        .toList();
    if (names.isEmpty) return;
    _noMatchToastShown = true;
    final on = names.length == 1
        ? names.first
        : '${names.take(names.length - 1).join(', ')} or ${names.last}';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text("Couldn't find this manga on $on"),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<void> _loadEntry(TrackerMatch match) async {
    if (_entryLoading.contains(match.key)) return;
    if (_entryCache.containsKey(match.key)) return;
    _entryLoading.add(match.key);
    try {
      final entry = await _repo.fetchRemoteEntry(match);
      if (!mounted) return;
      setState(() {
        _entryCache[match.key] = entry;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _entryCache[match.key] = null;
      });
    } finally {
      _entryLoading.remove(match.key);
    }
  }

  Future<void> _refreshEntry(TrackerMatch match) async {
    _entryCache.remove(match.key);
    await _loadEntry(match);
  }

  @override
  Widget build(BuildContext context) {
    if (!_repo.hasAuthenticatedTracker) {
      return const SizedBox.shrink();
    }
    final matches = _repo.matchesFor(widget.sourceId, widget.bookId);

    if (matches.isEmpty) {
      if (_matching) {
        // Show a card-shaped skeleton so the slot is reserved and the
        // transition into the real card doesn't shift the layout.
        return const _TrackerCardSkeleton();
      }
      // Auto-match completed with no result — quiet failure.
      return const SizedBox.shrink();
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final match in matches)
          _TrackerCard(
            match: match,
            tracker: _repo.trackerById(match.trackerId),
            entry: _entryCache[match.key],
            isLoadingEntry: !_entryCache.containsKey(match.key),
            onMount: () => _loadEntry(match),
            onOpenMenu: () => _openEditSheet(match),
          ),
      ],
    );
  }

  Future<void> _openEditSheet(TrackerMatch match) async {
    final tracker = _repo.trackerById(match.trackerId);
    final trackerName = tracker?.displayName ?? match.trackerId;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return _EditSheet(
          trackerName: trackerName,
          onChangeStatus: () async {
            Navigator.pop(ctx);
            await _openStatusSheet(match);
          },
          onChangeScore: () async {
            Navigator.pop(ctx);
            await _openScoreDialog(match);
          },
          onOpenWeb: () async {
            Navigator.pop(ctx);
            await _openOnWeb(match);
          },
          onUnlink: () async {
            Navigator.pop(ctx);
            await _confirmAndUnlink(match);
          },
        );
      },
    );
  }

  Future<void> _openStatusSheet(TrackerMatch match) async {
    final current = _entryCache[match.key]?.status;
    final picked = await showModalBottomSheet<TrackerStatus>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return _StatusPickerSheet(current: current);
      },
    );
    if (picked == null) return;
    try {
      await _repo.setStatus(match, picked);
      await _refreshEntry(match);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Couldn't update status: $e")),
      );
    }
  }

  Future<void> _openScoreDialog(TrackerMatch match) async {
    final initial = _entryCache[match.key]?.score ?? 0.0;
    final picked = await showDialog<double>(
      context: context,
      builder: (ctx) => _ScoreDialog(initial: initial),
    );
    if (picked == null) return;
    try {
      await _repo.setScore(match, picked);
      await _refreshEntry(match);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Couldn't update score: $e")),
      );
    }
  }

  Future<void> _openOnWeb(TrackerMatch match) async {
    final uri = Uri.parse('https://anilist.com/manga/${match.remoteId}');
    try {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        await launchUrl(uri, mode: LaunchMode.platformDefault);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Couldn't open browser: $e")),
      );
    }
  }

  Future<void> _confirmAndUnlink(TrackerMatch match) async {
    final tracker = _repo.trackerById(match.trackerId);
    final name = tracker?.displayName ?? match.trackerId;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Unlink from $name?'),
        content: Text(
          '“${match.matchedTitle}” will no longer sync with $name. '
          'Your local progress is not affected.',
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
            child: const Text('Unlink'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _repo.unlink(
        sourceId: widget.sourceId,
        bookId: widget.bookId,
        trackerId: match.trackerId,
      );
      if (!mounted) return;
      setState(() {
        _entryCache.remove(match.key);
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Couldn't unlink: $e")),
      );
    }
  }
}

/// Compact skeleton shown while the initial auto-match is still in flight.
/// Same height as the real chip so the slot doesn't shift when it lands.
class _TrackerCardSkeleton extends StatelessWidget {
  const _TrackerCardSkeleton();

  @override
  Widget build(BuildContext context) {
    return _ChipShell(
      child: Row(
        children: [
          const _TrackerLogo(trackerId: 'anilist'),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Looking up on AniList…',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 1.6,
              valueColor: AlwaysStoppedAnimation<Color>(
                AppColors.primary.withValues(alpha: 0.9),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Full-width tracker card. Replaces the small pill chip with a richer
/// surface that surfaces status, score, and progress at a glance.
///
/// All three interactive areas (status chip, score chip, overflow `⋯`)
/// call back into the parent which already owns the sheets/dialogs.
class _TrackerCard extends StatefulWidget {
  const _TrackerCard({
    required this.match,
    required this.tracker,
    required this.entry,
    required this.isLoadingEntry,
    required this.onMount,
    required this.onOpenMenu,
  });

  final TrackerMatch match;
  final Tracker? tracker;
  final TrackerEntry? entry;
  final bool isLoadingEntry;
  final VoidCallback onMount;

  /// Tapping the chip surface or the trailing ⋯ both open the same edit
  /// sheet — status, score, open-on-web, unlink all live there. Keeps
  /// the inline visual minimal.
  final VoidCallback onOpenMenu;

  @override
  State<_TrackerCard> createState() => _TrackerCardState();
}

class _TrackerCardState extends State<_TrackerCard> {
  @override
  void initState() {
    super.initState();
    if (widget.isLoadingEntry) {
      WidgetsBinding.instance.addPostFrameCallback((_) => widget.onMount());
    }
  }

  @override
  void didUpdateWidget(covariant _TrackerCard old) {
    super.didUpdateWidget(old);
    if (widget.isLoadingEntry && !old.isLoadingEntry) {
      WidgetsBinding.instance.addPostFrameCallback((_) => widget.onMount());
    }
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final loading = widget.isLoadingEntry && entry == null;

    // Build the compact body label, e.g. "Reading · 1105 / 1182" or
    // "Reading · Ch 1105" when total chapters are unknown.
    final status = entry?.status.label ?? (loading ? '…' : 'Reading');
    final progressText = entry == null
        ? ''
        : entry.totalChapters > 0
            ? ' · ${entry.progress} / ${entry.totalChapters}'
            : entry.progress > 0
                ? ' · Ch ${entry.progress}'
                : '';
    final scoreText = (entry?.score != null && entry!.score! > 0)
        ? ' · ★${entry.score!.toStringAsFixed(1)}'
        : '';

    return _ChipShell(
      onTap: widget.onOpenMenu,
      child: Row(
        children: [
          _TrackerLogo(trackerId: widget.match.trackerId),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '$status$progressText$scoreText',
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 6),
          const Icon(
            Icons.more_horiz_rounded,
            size: 18,
            color: AppColors.textSecondary,
          ),
        ],
      ),
    );
  }
}

/// Compact single-row chip shared by the real tracker view and the
/// skeleton — keeps padding/color/corner radius consistent so transitions
/// between loading and loaded don't shift the layout.
class _ChipShell extends StatelessWidget {
  const _ChipShell({required this.child, this.onTap});
  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final shell = Container(
      margin: const EdgeInsets.fromLTRB(16, 2, 16, 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(12),
      ),
      child: child,
    );
    if (onTap == null) return shell;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: shell,
    );
  }
}

/// Small colored badge identifying the remote service. Right now AniList
/// only — uses AniList's brand blue with the "A" mark. Extensible to a
/// MAL badge later by keying off [trackerId].
class _TrackerLogo extends StatelessWidget {
  const _TrackerLogo({required this.trackerId});
  final String trackerId;

  @override
  Widget build(BuildContext context) {
    Color bg;
    String letter;
    switch (trackerId) {
      case 'anilist':
        bg = const Color(0xFF02A9FF);
        letter = 'A';
        break;
      case 'mal':
        bg = const Color(0xFF2E51A2);
        letter = 'M';
        break;
      default:
        bg = AppColors.textTertiary;
        letter = trackerId.isNotEmpty ? trackerId[0].toUpperCase() : '?';
    }
    return Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(5),
      ),
      alignment: Alignment.center,
      child: Text(
        letter,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.2,
        ),
      ),
    );
  }
}

/// Bottom sheet shown when the user taps a tracker chip.
class _EditSheet extends StatelessWidget {
  const _EditSheet({
    required this.trackerName,
    required this.onChangeStatus,
    required this.onChangeScore,
    required this.onOpenWeb,
    required this.onUnlink,
  });

  final String trackerName;
  final VoidCallback onChangeStatus;
  final VoidCallback onChangeScore;
  final VoidCallback onOpenWeb;
  final VoidCallback onUnlink;

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
                      .withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  trackerName,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.toggle_on_rounded),
              title: const Text('Change status'),
              onTap: onChangeStatus,
            ),
            ListTile(
              leading: const Icon(Icons.star_rounded),
              title: const Text('Score'),
              onTap: onChangeScore,
            ),
            ListTile(
              leading: const Icon(Icons.open_in_new_rounded),
              title: Text('Open on $trackerName'),
              onTap: onOpenWeb,
            ),
            ListTile(
              leading: const Icon(
                Icons.link_off_rounded,
                color: AppColors.primary,
              ),
              title: const Text(
                'Unlink',
                style: TextStyle(color: AppColors.primary),
              ),
              onTap: onUnlink,
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }
}

/// Sub-sheet with the six [TrackerStatus] options.
class _StatusPickerSheet extends StatelessWidget {
  const _StatusPickerSheet({required this.current});

  final TrackerStatus? current;

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
                      .withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 8, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Change status',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
              ),
            ),
            for (final status in TrackerStatus.values)
              ListTile(
                leading: Icon(_iconFor(status)),
                title: Text(status.label),
                trailing: status == current
                    ? Icon(
                        Icons.check,
                        color: theme.colorScheme.primary,
                      )
                    : null,
                onTap: () => Navigator.pop(context, status),
              ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }

  IconData _iconFor(TrackerStatus s) {
    switch (s) {
      case TrackerStatus.reading:
        return Icons.menu_book_rounded;
      case TrackerStatus.planToRead:
        return Icons.bookmark_add_outlined;
      case TrackerStatus.completed:
        return Icons.check_circle_rounded;
      case TrackerStatus.onHold:
        return Icons.pause_circle_outline_rounded;
      case TrackerStatus.dropped:
        return Icons.cancel_outlined;
      case TrackerStatus.rereading:
        return Icons.replay_rounded;
    }
  }
}

/// Slider dialog for the 0–10, step 0.5 user score.
class _ScoreDialog extends StatefulWidget {
  const _ScoreDialog({required this.initial});

  final double initial;

  @override
  State<_ScoreDialog> createState() => _ScoreDialogState();
}

class _ScoreDialogState extends State<_ScoreDialog> {
  late double _value = widget.initial.clamp(0.0, 10.0).toDouble();

  String get _formatted {
    // Show ".0" for whole numbers to match the slider step granularity.
    return _value.toStringAsFixed(1);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Score'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _formatted,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          Slider(
            value: _value,
            min: 0,
            max: 10,
            divisions: 20,
            label: _formatted,
            onChanged: (v) => setState(() => _value = v),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _value),
          style: TextButton.styleFrom(
            foregroundColor: AppColors.primary,
          ),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
