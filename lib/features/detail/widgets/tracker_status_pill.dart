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

  /// Cached remote entries per match key. Populated lazily when each chip
  /// is built and refreshed after every setStatus / setScore.
  final Map<String, TrackerEntry?> _entryCache = {};
  final Set<String> _entryLoading = {};

  @override
  void initState() {
    super.initState();
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
    }
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
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: _LookingUpChip(),
          ),
        );
      }
      // Auto-match completed with no result — quiet failure.
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final match in matches)
            _TrackerChip(
              match: match,
              tracker: _repo.trackerById(match.trackerId),
              entry: _entryCache[match.key],
              isLoadingEntry:
                  !_entryCache.containsKey(match.key),
              onMount: () => _loadEntry(match),
              onTap: () => _openEditSheet(match),
            ),
        ],
      ),
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

/// Pill shown while the initial auto-match query is still in flight.
class _LookingUpChip extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.card,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
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
            const SizedBox(width: 8),
            const Text(
              'Looking up on AniList…',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Single tracker chip — `[icon] AniList: Reading · 12/1180 ▾`. Wraps a
/// stateful loader so it can request its [TrackerEntry] exactly once when
/// it first appears.
class _TrackerChip extends StatefulWidget {
  const _TrackerChip({
    required this.match,
    required this.tracker,
    required this.entry,
    required this.isLoadingEntry,
    required this.onMount,
    required this.onTap,
  });

  final TrackerMatch match;
  final Tracker? tracker;
  final TrackerEntry? entry;
  final bool isLoadingEntry;
  final VoidCallback onMount;
  final VoidCallback onTap;

  @override
  State<_TrackerChip> createState() => _TrackerChipState();
}

class _TrackerChipState extends State<_TrackerChip> {
  @override
  void initState() {
    super.initState();
    if (widget.isLoadingEntry) {
      WidgetsBinding.instance.addPostFrameCallback((_) => widget.onMount());
    }
  }

  @override
  void didUpdateWidget(covariant _TrackerChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    // If the entry was invalidated (e.g. after setStatus) we need to refetch.
    if (widget.isLoadingEntry && !oldWidget.isLoadingEntry) {
      WidgetsBinding.instance.addPostFrameCallback((_) => widget.onMount());
    }
  }

  IconData get _iconFor {
    switch (widget.match.trackerId) {
      case 'anilist':
        return Icons.bookmark_rounded;
      case 'mal':
        return Icons.menu_book_rounded;
      default:
        return Icons.link_rounded;
    }
  }

  String get _trackerLabel =>
      widget.tracker?.displayName ??
      (widget.match.trackerId == 'anilist'
          ? 'AniList'
          : widget.match.trackerId == 'mal'
              ? 'MAL'
              : widget.match.trackerId);

  String _buildLabel() {
    final tName = _trackerLabel;
    final entry = widget.entry;
    if (entry == null) {
      if (widget.isLoadingEntry) return '$tName: …';
      return tName;
    }
    final total = entry.totalChapters > 0 ? '${entry.totalChapters}' : '?';
    return '$tName: ${entry.status.label} · ${entry.progress}/$total';
  }

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.primary;
    return Material(
      color: accent.withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_iconFor, size: 14, color: accent),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 240),
                child: Text(
                  _buildLabel(),
                  style: TextStyle(
                    color: accent,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 2),
              Icon(Icons.arrow_drop_down_rounded, size: 18, color: accent),
            ],
          ),
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
