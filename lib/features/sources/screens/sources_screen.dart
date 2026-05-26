import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import '../../../core/services/image_cache_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:hive/hive.dart';

import '../../../core/di/injection.dart';
import '../../../core/models/directory_entry.dart';
import '../../../core/provider/provider_manager.dart';
import '../../../core/provider/provider_registry.dart';
import '../../../core/provider/provider_repo_registry.dart';
import '../../../core/repository/provider_repository.dart';
import '../../../core/services/directory_service.dart';
import '../../../core/services/remote_health_service.dart';
import '../../../core/state/source_filter_cubit.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/app_snack.dart';
import '../../../core/widgets/state_views.dart';
import '../bloc/sources_bloc.dart';
import '../bloc/sources_event.dart';
import '../bloc/sources_state.dart';

class SourcesScreen extends StatelessWidget {
  const SourcesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => SourcesBloc(
        registry: sl<ProviderRegistry>(),
        repository: sl<ProviderRepository>(),
        remoteHealth: sl<RemoteHealthService>(),
      )..add(const SourcesStarted()),
      child: const _SourcesView(),
    );
  }
}

class _SourcesView extends StatefulWidget {
  const _SourcesView();

  @override
  State<_SourcesView> createState() => _SourcesViewState();
}

class _SourcesViewState extends State<_SourcesView>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  int _currentTab = 0;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() {
      if (_tabController.indexIsChanging) return;
      if (_currentTab != _tabController.index) {
        setState(() => _currentTab = _tabController.index);
      }
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _showAddRepoDialog(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (_) => const _AddRepoDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isInstalled = _currentTab == 0;
    final isRepos = _currentTab == 1;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Sources'),
        actions: [
          if (isInstalled)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () =>
                  context.read<SourcesBloc>().add(const SourcesRefreshed()),
            ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: AppColors.primary,
          labelColor: AppColors.textPrimary,
          unselectedLabelColor: AppColors.textSecondary,
          indicatorSize: TabBarIndicatorSize.label,
          dividerHeight: 0,
          tabs: const [
            Tab(text: 'Installed'),
            Tab(text: 'Repos'),
            Tab(text: 'Discover'),
          ],
        ),
      ),
      // FAB lives only on the Repos tab — that's where adding a manifest
      // URL is the primary action. The Installed tab is a view of what
      // the user already has; new installs go through Repos → tap an
      // Install pill on a source row. The Discover tab pulls from the
      // central directory so there's nothing for the user to add by
      // hand there either.
      floatingActionButton: isRepos
          ? Builder(
              builder: (ctx) => FloatingActionButton(
                backgroundColor: AppColors.primary,
                onPressed: () => _showAddRepoDialog(ctx),
                child: const Icon(Icons.add),
              ),
            )
          : null,
      body: TabBarView(
        controller: _tabController,
        children: const [
          _InstalledTab(),
          _ReposTab(),
          _DiscoverTab(),
        ],
      ),
    );
  }
}

class _InstalledTab extends StatelessWidget {
  const _InstalledTab();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<SourcesBloc, SourcesState>(
      builder: (context, state) {
        if (state.status == SourcesStatus.loading && state.items.isEmpty) {
          return const LoadingView();
        }
        if (state.items.isEmpty) {
          return const EmptyView(
            message: 'No providers installed.\nTap + to add one.',
            icon: Icons.extension_outlined,
          );
        }
        // Group sources by their origin repo so users can collapse the
        // ones they don't care about right now. The same source could
        // exist in multiple repos via composite keys; each repo gets
        // its own header.
        final groups = <String, List<SourceItem>>{};
        final repoNames = <String, String>{};
        for (final s in state.items) {
          final key = s.repoUrl.isEmpty ? '__bundled__' : s.repoUrl;
          groups.putIfAbsent(key, () => <SourceItem>[]).add(s);
          // Pick the most descriptive name we've seen for this repo.
          final existing = repoNames[key] ?? '';
          final candidate = s.repoDisplayName.isNotEmpty
              ? s.repoDisplayName
              : (s.repoUrl.isEmpty ? 'Bundled' : s.repoUrl);
          if (candidate.length > existing.length) {
            repoNames[key] = candidate;
          }
        }
        final keys = groups.keys.toList()
          ..sort((a, b) {
            // Bundled first, then repos alphabetically by display name.
            if (a == '__bundled__') return -1;
            if (b == '__bundled__') return 1;
            return (repoNames[a] ?? a)
                .toLowerCase()
                .compareTo((repoNames[b] ?? b).toLowerCase());
          });
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
          itemCount: keys.length,
          itemBuilder: (_, i) {
            final key = keys[i];
            final items = groups[key]!
              ..sort((a, b) => (a.info?.name ?? a.name)
                  .toLowerCase()
                  .compareTo((b.info?.name ?? b.name).toLowerCase()));
            return _RepoGroup(
              name: repoNames[key] ?? key,
              repoUrl: key == '__bundled__' ? '' : key,
              items: items,
            );
          },
        );
      },
    );
  }
}

/// Collapsible card grouping every source from one repo. Default
/// expanded so the user sees their providers without clicking — they
/// can fold groups they don't currently care about.
class _RepoGroup extends StatelessWidget {
  const _RepoGroup({
    required this.name,
    required this.repoUrl,
    required this.items,
  });

  final String name;
  final String repoUrl;
  final List<SourceItem> items;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppColors.divider.withValues(alpha: 0.5),
          width: 0.6,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        // ExpansionTile splatters its own divider across the bottom of
        // the header. Suppress it so we can use our own separators.
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: true,
          tilePadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
          childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          leading: const Icon(
            Icons.folder_outlined,
            color: AppColors.textSecondary,
            size: 20,
          ),
          title: Row(
            children: [
              Flexible(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: AppColors.card.withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${items.length}',
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          children: [
            for (var i = 0; i < items.length; i++) ...[
              if (i > 0) const SizedBox(height: 8),
              _SourceTile(item: items[i]),
            ],
          ],
        ),
      ),
    );
  }
}

class _SourceTile extends StatelessWidget {
  const _SourceTile({required this.item});
  final SourceItem item;

  @override
  Widget build(BuildContext context) {
    final effective = item.effectiveHealth;
    final remote = item.remoteHealth;
    final subtitle = _subtitleFor(item);
    final subtitleColor = (item.error != null ||
            effective == ProviderHealthStatus.broken)
        ? AppColors.error
        : AppColors.textSecondary;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(10),
      ),
      child: ListTile(
        title: Row(
          children: [
            Flexible(
              child: Text(
                item.info?.name ?? item.name,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // Local health drives the primary pill — that's what the
            // user's last call to the source actually returned.
            if (item.health != ProviderHealthStatus.healthy) ...[
              const SizedBox(width: 8),
              _HealthPill(status: item.health),
            ],
            // When CI flagged the source but local is still clean, hint
            // separately so the user knows CI has seen trouble even if
            // their own usage looks fine right now.
            if (item.health == ProviderHealthStatus.healthy &&
                remote != null &&
                remote.isProblem) ...[
              const SizedBox(width: 8),
              const _CiFlaggedPill(),
            ],
          ],
        ),
        subtitle: Text(
          subtitle,
          style: TextStyle(
            color: subtitleColor,
            fontSize: 12,
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Per-source settings. Only meaningful for loaded providers
            // since the schema lives in the JS file — disable the icon
            // when the runtime hasn't loaded this entry so users don't
            // navigate to an empty form.
            IconButton(
              tooltip: 'Source settings',
              icon: const Icon(Icons.tune_rounded),
              color: item.loaded
                  ? AppColors.textSecondary
                  : AppColors.textTertiary,
              onPressed: item.loaded
                  ? () => context.pushNamed(
                        'source-settings',
                        pathParameters: {'sourceId': item.name},
                        queryParameters: {
                          'repoUrl': item.repoUrl,
                          if (item.info?.name != null)
                            'displayName': item.info!.name,
                        },
                      )
                  : null,
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              color: AppColors.surface,
              onSelected: (v) {
                final bloc = context.read<SourcesBloc>();
                // Scope mutations to this (repoUrl, sourceId) pair so we
                // don't accidentally touch a sibling repo's copy when two
                // repos publish the same sourceId.
                if (v == 'update') {
                  bloc.add(SourceUpdated(item.name, repoUrl: item.repoUrl));
                }
                if (v == 'remove') {
                  bloc.add(SourceUninstalled(item.name, repoUrl: item.repoUrl));
                }
                if (v == 'reset') bloc.add(SourceHealthReset(item.name));
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'update', child: Text('Update')),
                const PopupMenuItem(value: 'remove', child: Text('Remove')),
                if (item.health != ProviderHealthStatus.healthy)
                  const PopupMenuItem(value: 'reset', child: Text('Reset')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _HealthPill extends StatelessWidget {
  const _HealthPill({required this.status});
  final ProviderHealthStatus status;

  @override
  Widget build(BuildContext context) {
    final isBroken = status == ProviderHealthStatus.broken;
    final color = isBroken ? AppColors.error : Colors.amber;
    final label = isBroken ? 'BROKEN' : 'DEGRADED';
    return _PillChrome(color: color, label: label);
  }
}

/// Pill shown when CI reports a problem but local usage is still fine.
/// Quieter color than `BROKEN` because the user hasn't hit the failure
/// yet — informational, not alarming.
class _CiFlaggedPill extends StatelessWidget {
  const _CiFlaggedPill();

  @override
  Widget build(BuildContext context) {
    return const _PillChrome(color: Colors.orange, label: 'CI');
  }
}

class _PillChrome extends StatelessWidget {
  const _PillChrome({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color, width: 1),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// Builds the second-line text for one source tile.
///
/// Priority of signals (most relevant first):
/// 1. A locally-seen error (most recent + most user-relevant)
/// 2. A CI-reported problem (broken-parse, etc.)
/// 3. The default metadata line (lang • type • version)
String _subtitleFor(SourceItem item) {
  if (item.error != null) return item.error!;
  if (item.health != ProviderHealthStatus.healthy &&
      item.healthError != null) {
    return item.healthError!;
  }
  final remote = item.remoteHealth;
  if (remote != null && remote.isProblem) {
    final detail = remote.error ?? remote.shortLabel;
    return 'CI: $detail';
  }
  if (item.info != null) {
    return '${item.info!.lang} • ${item.info!.type.name} • v${item.info!.version ?? '?'}';
  }
  return item.loaded ? 'loaded' : 'not loaded';
}

// ---------------------------------------------------------------------------
// Repos tab
// ---------------------------------------------------------------------------

/// Renders one section per tracked provider repo. Sections expose Install /
/// Installed pills for each source row. Watches both the repos box and the
/// installed-providers Hive box so add / remove / install actions reflect
/// instantly without manual refreshes.
class _ReposTab extends StatefulWidget {
  const _ReposTab();

  @override
  State<_ReposTab> createState() => _ReposTabState();
}

class _ReposTabState extends State<_ReposTab> {
  StreamSubscription<BoxEvent>? _registrySub;

  @override
  void initState() {
    super.initState();
    // The installed providers box drives the Install/Installed button
    // state. ProviderRegistry doesn't expose a public watch() so we
    // subscribe to the box directly via Hive.
    final box = Hive.box<Map>(ProviderRegistry.boxName);
    _registrySub = box.watch().listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _registrySub?.cancel();
    super.dispose();
  }

  /// Returns the set of composite `(repoUrl, sourceId)` keys currently
  /// installed. The Repos tab pills check membership per-repo, so two
  /// repos that publish the same sourceId can show "Install" in one
  /// section and "Installed" in the other.
  Set<String> _installedKeys() {
    return sl<ProviderRegistry>()
        .getInstalled()
        .map((e) => ProviderRegistry.providerKey(e.originRepoUrl, e.name))
        .toSet();
  }

  Future<void> _retrySeed() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final repos = sl<ProviderReposRegistry>();
      // Re-fetch every known URL. If none are tracked we have nothing to
      // re-seed — the env-driven default is seeded at bootstrap and is
      // outside this widget's reach.
      final urls = repos.getAll().map((r) => r.url).toList();
      if (urls.isEmpty) {
        messenger.showAppSnack(
          const SnackBar(content: Text('No repos to refresh.')),
        );
        return;
      }
      for (final url in urls) {
        await repos.fetchAndCache(url);
      }
      if (!mounted) return;
      messenger.showAppSnack(
        const SnackBar(content: Text('Repos refreshed.')),
      );
    } catch (e) {
      messenger.showAppSnack(
        SnackBar(content: Text("Couldn't refresh: $e")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final repos = sl<ProviderReposRegistry>();
    return StreamBuilder<BoxEvent>(
      stream: repos.watch(),
      builder: (context, _) {
        final all = repos.getAll();
        if (all.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const EmptyView(
                    icon: Icons.cloud_off_outlined,
                    message: 'No repos added yet.\nTap + to add one.',
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: AppColors.textPrimary,
                    ),
                    onPressed: _retrySeed,
                    child: const Text('Retry default repo'),
                  ),
                ],
              ),
            ),
          );
        }

        return BlocBuilder<SourceFilterCubit, bool>(
          bloc: sl<SourceFilterCubit>(),
          builder: (context, showNsfw) {
            final installedKeys = _installedKeys();
            return ListView.builder(
              padding: const EdgeInsets.fromLTRB(0, 8, 0, 96),
              // +1 for the NSFW toggle header.
              itemCount: all.length + 1,
              itemBuilder: (_, i) {
                if (i == 0) {
                  return _NsfwToggle(
                    value: showNsfw,
                    onChanged: (v) =>
                        sl<SourceFilterCubit>().setShowNsfw(v),
                  );
                }
                final repo = all[i - 1];
                return _RepoSection(
                  repo: repo,
                  showNsfw: showNsfw,
                  installedKeys: installedKeys,
                );
              },
            );
          },
        );
      },
    );
  }
}

class _NsfwToggle extends StatelessWidget {
  const _NsfwToggle({required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
      ),
      child: SwitchListTile.adaptive(
        value: value,
        onChanged: onChanged,
        activeThumbColor: AppColors.primary,
        title: const Text(
          'Show NSFW sources',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: const Text(
          'Hidden by default. Toggle on to see adult-tagged providers.',
          style: TextStyle(
            color: AppColors.textSecondary,
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}

class _RepoSection extends StatefulWidget {
  const _RepoSection({
    required this.repo,
    required this.showNsfw,
    required this.installedKeys,
  });

  final ProviderRepo repo;
  final bool showNsfw;

  /// Composite keys of currently-installed providers — see
  /// `ProviderRegistry.providerKey`. Membership is checked per-source
  /// inside this repo so two repos sharing a sourceId render correctly.
  final Set<String> installedKeys;

  @override
  State<_RepoSection> createState() => _RepoSectionState();
}

class _RepoSectionState extends State<_RepoSection> {
  /// Collapsed by default — keeps the Repos tab compact when the user
  /// has multiple repos installed. Each section remembers its own
  /// state for the lifetime of the screen.
  bool _expanded = false;

  // Convenience pass-throughs so the rest of the body stays close to
  // the previous stateless version.
  ProviderRepo get repo => widget.repo;
  bool get showNsfw => widget.showNsfw;
  Set<String> get installedKeys => widget.installedKeys;

  Future<void> _refresh(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final updated =
          await sl<ProviderReposRegistry>().fetchAndCache(repo.url);
      messenger.showAppSnack(
        SnackBar(content: Text('Refreshed ${updated.name}')),
      );
    } catch (e) {
      messenger.showAppSnack(
        SnackBar(content: Text("Couldn't refresh: $e")),
      );
    }
  }

  Future<void> _rename(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final ctrl = TextEditingController(text: repo.customName ?? '');
    final result = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Rename repo'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                labelText: 'Display name',
                hintText: repo.name,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Leave blank to restore the original name.',
              style: TextStyle(
                color: AppColors.textTertiary,
                fontSize: 11,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: AppColors.textPrimary,
            ),
            // Pop the trimmed text — empty string clears the override.
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => ctrl.dispose());
    if (result == null) return; // Cancel
    await sl<ProviderReposRegistry>()
        .setCustomName(repo.url, result.isEmpty ? null : result);
    if (!mounted) return;
    final updated = sl<ProviderReposRegistry>().get(repo.url);
    messenger.showAppSnack(
      SnackBar(
        content: Text(
          result.isEmpty
              ? 'Restored original name'
              : 'Renamed to ${updated?.displayName ?? result}',
        ),
      ),
    );
  }

  Future<void> _remove(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Remove repo?'),
        content: Text(
          'Already-installed sources from "${repo.displayName}" stay installed. '
          'You can remove this repo and add it back later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Remove',
              style: TextStyle(color: AppColors.primary),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    await sl<ProviderReposRegistry>().remove(repo.url);
    messenger.showAppSnack(
      SnackBar(content: Text('Removed ${repo.displayName}')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final visibleSources = repo.sources
        .where((s) => showNsfw || !s.nsfw)
        .toList(growable: false);

    final installedFromThisRepo = repo.sources
        .where((s) => installedKeys
            .contains(ProviderRegistry.providerKey(repo.url, s.id)))
        .length;
    final headerCount = repo.sources.isEmpty
        ? null
        : '$installedFromThisRepo / ${repo.sources.length} installed';

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header row. Tappable surface flips _expanded; refresh and
          // overflow menu stay clickable independently because they
          // intercept the tap before the InkWell sees it.
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Rotating chevron indicates collapsed/expanded.
                  AnimatedRotation(
                    turns: _expanded ? 0.25 : 0.0,
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOut,
                    child: const Icon(
                      Icons.chevron_right_rounded,
                      color: AppColors.textSecondary,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          repo.displayName,
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (headerCount != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            headerCount,
                            style: const TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ] else if (repo.description.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            repo.description,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Refresh',
                    icon: const Icon(
                      Icons.refresh,
                      color: AppColors.textSecondary,
                    ),
                    onPressed: () => _refresh(context),
                  ),
                  PopupMenuButton<String>(
                    color: AppColors.surface,
                    icon: const Icon(
                      Icons.more_vert,
                      color: AppColors.textSecondary,
                    ),
                    onSelected: (v) {
                      if (v == 'rename') _rename(context);
                      if (v == 'remove') _remove(context);
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                          value: 'rename', child: Text('Rename')),
                      PopupMenuItem(
                          value: 'remove', child: Text('Remove repo')),
                    ],
                  ),
                ],
              ),
            ),
          ),
          // Animated body. AnimatedSize gives a slide-down feel without
          // building a dedicated AnimationController.
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: !_expanded
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Divider(height: 1, color: AppColors.divider),
                        if (visibleSources.isEmpty)
                          Padding(
                            padding:
                                const EdgeInsets.symmetric(vertical: 16),
                            child: Text(
                              repo.sources.isEmpty
                                  ? 'No sources in this repo yet.'
                                  : 'All sources hidden by NSFW filter.',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: AppColors.textTertiary,
                                fontSize: 12,
                              ),
                            ),
                          )
                        else
                          ...visibleSources.map(
                            (source) => _SourceRow(
                              repo: repo,
                              source: source,
                              installed: installedKeys.contains(
                                ProviderRegistry.providerKey(
                                    repo.url, source.id),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _SourceRow extends StatelessWidget {
  const _SourceRow({
    required this.repo,
    required this.source,
    required this.installed,
  });

  final ProviderRepo repo;
  final RepoSource source;
  final bool installed;

  Future<void> _install(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    // Route through SourcesBloc so the Installed tab refreshes alongside
    // the Repos tab. Direct registry calls skipped the bloc and left the
    // Installed list out of sync.
    final bloc = context.read<SourcesBloc>();
    final fileUrl = sl<ProviderReposRegistry>().resolveFileUrl(repo, source);
    bloc.add(SourceInstalled(
      name: source.id,
      url: fileUrl,
      repoUrl: repo.url,
      displayName: repo.displayName,
    ));
    messenger.showAppSnack(
      SnackBar(content: Text('Installed ${source.name}')),
    );
  }

  /// Force-refreshes the source — `SourceUpdated` routes through
  /// `ProviderRegistry.loadIntoRuntime(name, force: true)`, which
  /// tells the downloader to bypass its cache and pull the latest
  /// `.js` for this provider. Bundled providers (URL `bundled://`)
  /// re-read from the asset bundle via the special-case in
  /// [ProviderRegistry.loadIntoRuntime]. The runtime reloads with the
  /// new code so the user sees the update without restarting.
  Future<void> _update(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    context
        .read<SourcesBloc>()
        .add(SourceUpdated(source.id, repoUrl: repo.url));
    messenger.showAppSnack(
      SnackBar(content: Text('Updating ${source.name}…')),
    );
  }

  Future<void> _uninstall(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Uninstall ${source.name}?'),
        content: const Text(
          'The provider will be removed from your installed sources.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Uninstall',
              style: TextStyle(color: AppColors.primary),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    // Route through SourcesBloc so the Installed tab picks up the
    // removal. Without this the Repos tab's "Install" pill flipped
    // correctly via its Hive box watch, but the Installed tab kept
    // showing the source until next screen open.
    context
        .read<SourcesBloc>()
        .add(SourceUninstalled(source.id, repoUrl: repo.url));
    messenger.showAppSnack(
      SnackBar(content: Text('Removed ${source.name}')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          _SourceLogo(name: source.name, logo: source.logo),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  source.name,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                _SourceSubtitle(source: source),
              ],
            ),
          ),
          const SizedBox(width: 8),
          installed
              // When installed, the pill becomes a popup menu — Update
              // (re-fetches the .js for the source so users get
              // version bumps without having to remove+reinstall) and
              // Uninstall.
              ? PopupMenuButton<String>(
                  tooltip: 'Manage',
                  color: AppColors.surface,
                  onSelected: (v) {
                    if (v == 'update') _update(context);
                    if (v == 'uninstall') _uninstall(context);
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'update',
                      child: Row(
                        children: [
                          Icon(Icons.refresh_rounded, size: 18),
                          SizedBox(width: 12),
                          Text('Update'),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'uninstall',
                      child: Row(
                        children: [
                          Icon(Icons.delete_outline_rounded,
                              size: 18, color: AppColors.primary),
                          SizedBox(width: 12),
                          Text('Uninstall',
                              style: TextStyle(color: AppColors.primary)),
                        ],
                      ),
                    ),
                  ],
                  child: Container(
                    constraints: const BoxConstraints(minWidth: 88, minHeight: 36),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: AppColors.textSecondary.withValues(alpha: 0.4),
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      'Installed',
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                )
              : ElevatedButton(
                  onPressed: () => _install(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: AppColors.textPrimary,
                    elevation: 0,
                    minimumSize: const Size(88, 36),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: const Text('Install'),
                ),
        ],
      ),
    );
  }
}

class _SourceLogo extends StatelessWidget {
  const _SourceLogo({required this.name, required this.logo});
  final String name;
  final String? logo;

  @override
  Widget build(BuildContext context) {
    if (logo != null && logo!.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: CachedNetworkImage(
          cacheManager: appImageCacheManager,
          imageUrl: logo!,
          width: 36,
          height: 36,
          fit: BoxFit.cover,
          placeholder: (_, _) => _LogoPlaceholder(name: name),
          errorWidget: (_, _, _) => _LogoPlaceholder(name: name),
        ),
      );
    }
    return _LogoPlaceholder(name: name);
  }
}

class _LogoPlaceholder extends StatelessWidget {
  const _LogoPlaceholder({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    final letter = name.isNotEmpty ? name[0].toUpperCase() : '?';
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: AppColors.cardElevated,
        borderRadius: BorderRadius.circular(8),
      ),
      alignment: Alignment.center,
      child: Text(
        letter,
        style: const TextStyle(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _SourceSubtitle extends StatelessWidget {
  const _SourceSubtitle({required this.source});
  final RepoSource source;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        style: const TextStyle(
          color: AppColors.textSecondary,
          fontSize: 12,
        ),
        children: [
          TextSpan(text: '${source.lang} · v${source.version}'),
          if (source.nsfw) ...[
            const TextSpan(text: ' · '),
            const TextSpan(
              text: 'NSFW',
              style: TextStyle(
                color: AppColors.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

// ---------------------------------------------------------------------------
// Add-repo dialog
// ---------------------------------------------------------------------------

class _AddRepoDialog extends StatefulWidget {
  const _AddRepoDialog();

  @override
  State<_AddRepoDialog> createState() => _AddRepoDialogState();
}

class _AddRepoDialogState extends State<_AddRepoDialog> {
  final _urlCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _urlCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) {
      setState(() => _error = 'Enter a manifest URL.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      final name = _nameCtrl.text.trim();
      final repo = await sl<ProviderReposRegistry>().fetchAndCache(
        url,
        customName: name.isEmpty ? null : name,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      messenger.showAppSnack(
        SnackBar(content: Text('Added ${repo.displayName}')),
      );
    } on ProviderRepoException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: const Text('Add repo'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Optional override for the repo's display name. Skipped →
          // manifest's own "name" field is used. Useful when the user
          // has several similarly-named third-party repos and wants
          // their own labels.
          TextField(
            controller: _nameCtrl,
            enabled: !_loading,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Custom name (optional)',
              hintText: "Leave blank to use the repo's own name",
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _urlCtrl,
            enabled: !_loading,
            autofocus: true,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'Manifest URL',
              hintText:
                  'https://raw.githubusercontent.com/user/repo/main/index.json',
            ),
          ),
          const SizedBox(height: 10),
          // Explainer for the common "I pasted a .js URL and only got
          // one source" confusion. The manifest IS the list of every
          // source in the repo — paste the index.json, not a single
          // provider file.
          Container(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline_rounded,
                  size: 16,
                  color: AppColors.textSecondary,
                ),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Paste the manifest URL (the JSON file that lists every '
                    'source in the repo) — not a single provider .js URL. '
                    'One manifest = many sources.',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 11,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: const TextStyle(
                color: AppColors.primary,
                fontSize: 12,
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _loading ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: AppColors.textPrimary,
          ),
          onPressed: _loading ? null : _submit,
          child: _loading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.textPrimary,
                  ),
                )
              : const Text('Add'),
        ),
      ],
    );
  }
}

// -----------------------------------------------------------------------
// Discover tab
// -----------------------------------------------------------------------

/// Lists curated repos pulled from the public Sozo Read directory.
/// Each card is one repo entry; tapping Install adds the repo URL to
/// [ProviderReposRegistry] via the same path the default-repo seeding
/// uses at bootstrap.
///
/// Fetch + cache logic lives in [DirectoryService]; this widget is
/// only the UI layer.
class _DiscoverTab extends StatefulWidget {
  const _DiscoverTab();

  @override
  State<_DiscoverTab> createState() => _DiscoverTabState();
}

class _DiscoverTabState extends State<_DiscoverTab>
    with AutomaticKeepAliveClientMixin {
  late Future<List<DirectoryEntry>> _future;
  // Tracks which entries are currently being installed so we can show
  // a spinner inline on the matching card without freezing the others.
  final Set<String> _installing = <String>{};

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    final svc = sl<DirectoryService>();
    final cached = svc.cached();
    if (cached != null && cached.isNotEmpty) {
      // Render the cached entries instantly so the user never sees a
      // spinner when they have a previously-fetched copy.
      _future = Future.value(cached);
      // Stale-while-revalidate: kick off a network refresh in the
      // background if the cache is older than the soft threshold (5
      // min). Catches "I just added a new entry on GitHub" without
      // waiting out the full 24h TTL. Errors are swallowed — UI
      // already shows the cached copy.
      final cachedAt = svc.cachedAt();
      final softStale = cachedAt == null ||
          DateTime.now().difference(cachedAt) >
              const Duration(minutes: 5);
      if (softStale) {
        // ignore: discarded_futures
        svc.refresh(force: true).then((fresh) {
          if (!mounted) return;
          setState(() => _future = Future.value(fresh));
        }).catchError((_) {/* keep showing cache */});
      }
    } else {
      _future = svc.refresh();
    }
  }

  Future<void> _hardRefresh() async {
    setState(() {
      _future = sl<DirectoryService>().refresh(force: true);
    });
    await _future;
  }

  /// Installs a directory entry's repo URL. Idempotent — if the user
  /// already had the repo tracked, this just shows "Already added".
  /// On success the Repos tab will reactively pick up the new entry
  /// since it listens to the repos Hive box.
  Future<void> _install(DirectoryEntry entry) async {
    final messenger = ScaffoldMessenger.of(context);
    final repos = sl<ProviderReposRegistry>();
    if (repos.has(entry.repoUrl)) {
      messenger.showAppSnackText('${entry.name} is already added');
      return;
    }
    setState(() => _installing.add(entry.repoUrl));
    try {
      final added = await repos.seedDefaultRepo(entry.repoUrl);
      if (!mounted) return;
      messenger.showAppSnackText(
        added
            ? 'Added ${entry.name} — open the Repos tab to install sources'
            : '${entry.name} is already added',
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showAppSnackText('Failed to add ${entry.name}: $e');
    } finally {
      if (mounted) setState(() => _installing.remove(entry.repoUrl));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return RefreshIndicator(
      onRefresh: _hardRefresh,
      color: AppColors.primary,
      child: FutureBuilder<List<DirectoryEntry>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting &&
              !snap.hasData) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: CircularProgressIndicator(
                  color: AppColors.primary,
                ),
              ),
            );
          }
          if (snap.hasError && !snap.hasData) {
            return _DiscoverError(
              error: snap.error.toString(),
              onRetry: _hardRefresh,
            );
          }
          final entries = snap.data ?? const <DirectoryEntry>[];
          if (entries.isEmpty) {
            return const _DiscoverEmpty();
          }
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
            itemCount: entries.length + 1,
            itemBuilder: (_, i) {
              if (i == 0) return const _DiscoverHeader();
              final entry = entries[i - 1];
              return _DiscoverCard(
                entry: entry,
                installing: _installing.contains(entry.repoUrl),
                onInstall: () => _install(entry),
              );
            },
          );
        },
      ),
    );
  }
}

class _DiscoverHeader extends StatelessWidget {
  const _DiscoverHeader();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: AppColors.primary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: AppColors.primary.withValues(alpha: 0.22),
            width: 0.6,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.explore_outlined,
              color: AppColors.primary,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Community-maintained source packs. Tap Install to add '
                'one to your Repos tab. Use at your own risk — sources '
                'are written by third parties.',
                style: TextStyle(
                  color: AppColors.textSecondary.withValues(alpha: 0.9),
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DiscoverCard extends StatelessWidget {
  const _DiscoverCard({
    required this.entry,
    required this.installing,
    required this.onInstall,
  });

  final DirectoryEntry entry;
  final bool installing;
  final VoidCallback onInstall;

  /// Streams `true`/`false` for whether the entry's repoUrl is
  /// currently tracked in [ProviderReposRegistry]. Emits the current
  /// value immediately, then again whenever the repos Hive box
  /// changes. Drives the Install -> Installed swap.
  Stream<bool> _installedStream() async* {
    final repos = sl<ProviderReposRegistry>();
    yield repos.has(entry.repoUrl);
    await for (final _ in repos.watch()) {
      yield repos.has(entry.repoUrl);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppColors.divider.withValues(alpha: 0.6),
          width: 0.6,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Logo(
                logoUrl: entry.logo,
                author: entry.author,
                fallbackSeed: entry.name,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            entry.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (entry.verified) ...[
                          const SizedBox(width: 6),
                          const Icon(
                            Icons.verified_rounded,
                            size: 16,
                            color: AppColors.primary,
                          ),
                        ],
                      ],
                    ),
                    if (entry.author.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        'by ${entry.author}',
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 34,
                child: StreamBuilder<bool>(
                  stream: _installedStream(),
                  initialData:
                      sl<ProviderReposRegistry>().has(entry.repoUrl),
                  builder: (_, snap) {
                    final installed = snap.data ?? false;
                    // Three visual states:
                    //   1. Currently installing → spinner, disabled
                    //   2. Repo already tracked → "Installed" pill in
                    //      muted style + check, disabled
                    //   3. Otherwise → primary "Install" button.
                    if (installing) {
                      return FilledButton(
                        onPressed: null,
                        style: FilledButton.styleFrom(
                          padding:
                              const EdgeInsets.symmetric(horizontal: 14),
                        ),
                        child: const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        ),
                      );
                    }
                    if (installed) {
                      return OutlinedButton.icon(
                        onPressed: null,
                        style: OutlinedButton.styleFrom(
                          padding:
                              const EdgeInsets.symmetric(horizontal: 12),
                          foregroundColor: AppColors.primary,
                          side: BorderSide(
                            color: AppColors.primary
                                .withValues(alpha: 0.5),
                          ),
                        ),
                        icon: const Icon(Icons.check_rounded, size: 16),
                        label: const Text('Installed'),
                      );
                    }
                    return FilledButton(
                      onPressed: onInstall,
                      style: FilledButton.styleFrom(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 14),
                      ),
                      child: const Text('Install'),
                    );
                  },
                ),
              ),
            ],
          ),
          if (entry.description.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              entry.description,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ],
          if (entry.tags.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final t in entry.tags.take(4))
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.card.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      t,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 11,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Small square logo at the leading edge of each card. Three-tier
/// fallback:
///   1. Explicit [logoUrl] from the directory entry (author can ship a
///      custom badge).
///   2. GitHub avatar derived from [author] (`github.com/<x>.png`
///      redirects to the user's avatar; covers 99% of entries since
///      the schema asks for a GitHub handle).
///   3. Tinted initial letter from [fallbackSeed] when neither works
///      or both 404.
class _Logo extends StatelessWidget {
  const _Logo({
    required this.logoUrl,
    required this.author,
    required this.fallbackSeed,
  });

  final String? logoUrl;
  final String author;
  final String fallbackSeed;

  /// First non-empty URL we should try to render. Null when neither
  /// an explicit logo nor a GitHub-handle author is available.
  String? get _effectiveUrl {
    final l = logoUrl?.trim();
    if (l != null && l.isNotEmpty) return l;
    final a = author.trim();
    if (a.isEmpty) return null;
    // GitHub treats `<handle>.png` as a redirect to the user's avatar.
    // Non-existent handles return 404, which the errorWidget below
    // catches and swaps for the initial-letter placeholder.
    return 'https://github.com/${Uri.encodeComponent(a)}.png';
  }

  @override
  Widget build(BuildContext context) {
    final url = _effectiveUrl;
    if (url != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: CachedNetworkImage(
          imageUrl: url,
          width: 44,
          height: 44,
          fit: BoxFit.cover,
          cacheManager: AppImageCacheManager(),
          errorWidget: (_, _, _) => _placeholder(fallbackSeed),
        ),
      );
    }
    return _placeholder(fallbackSeed);
  }

  Widget _placeholder(String seed) {
    final letter =
        seed.trim().isEmpty ? '?' : seed.trim()[0].toUpperCase();
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(8),
      ),
      alignment: Alignment.center,
      child: Text(
        letter,
        style: const TextStyle(
          color: AppColors.primary,
          fontSize: 18,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _DiscoverError extends StatelessWidget {
  const _DiscoverError({required this.error, required this.onRetry});
  final String error;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 80),
        const Icon(
          Icons.cloud_off_rounded,
          size: 48,
          color: AppColors.textTertiary,
        ),
        const SizedBox(height: 12),
        Text(
          "Couldn't load the directory",
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          error,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 12,
          ),
        ),
        const SizedBox(height: 14),
        Center(
          child: OutlinedButton.icon(
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Try again'),
            onPressed: () {
              // ignore: discarded_futures
              onRetry();
            },
          ),
        ),
      ],
    );
  }
}

class _DiscoverEmpty extends StatelessWidget {
  const _DiscoverEmpty();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: const [
        SizedBox(height: 80),
        Icon(
          Icons.explore_off_rounded,
          size: 48,
          color: AppColors.textTertiary,
        ),
        SizedBox(height: 12),
        Center(
          child: Text(
            'No directory entries yet',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        SizedBox(height: 6),
        Center(
          child: Text(
            'Check back later — the curated list will grow over time.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
        ),
      ],
    );
  }
}
