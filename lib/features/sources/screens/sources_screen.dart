import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import '../../../core/services/image_cache_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive/hive.dart';

import '../../../core/di/injection.dart';
import '../../../core/provider/provider_manager.dart';
import '../../../core/provider/provider_registry.dart';
import '../../../core/provider/provider_repo_registry.dart';
import '../../../core/repository/provider_repository.dart';
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
    _tabController = TabController(length: 2, vsync: this);
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

  Future<void> _showInstallDialog(BuildContext context) async {
    final nameCtrl = TextEditingController();
    final urlCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Add provider'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration:
                  const InputDecoration(labelText: 'Name (e.g. mangadex)'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: urlCtrl,
              decoration: const InputDecoration(labelText: 'JS raw URL'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Install'),
          ),
        ],
      ),
    );
    if (ok == true &&
        nameCtrl.text.trim().isNotEmpty &&
        urlCtrl.text.trim().isNotEmpty) {
      if (!context.mounted) return;
      context.read<SourcesBloc>().add(
            SourceInstalled(
              name: nameCtrl.text.trim(),
              url: urlCtrl.text.trim(),
            ),
          );
    }
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
          ],
        ),
      ),
      floatingActionButton: Builder(
        builder: (ctx) => FloatingActionButton(
          backgroundColor: AppColors.primary,
          onPressed: () => isInstalled
              ? _showInstallDialog(ctx)
              : _showAddRepoDialog(ctx),
          child: const Icon(Icons.add),
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: const [
          _InstalledTab(),
          _ReposTab(),
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
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
          itemCount: state.items.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (_, i) {
            final s = state.items[i];
            return _SourceTile(item: s);
          },
        );
      },
    );
  }
}

class _SourceTile extends StatelessWidget {
  const _SourceTile({required this.item});
  final SourceItem item;

  @override
  Widget build(BuildContext context) {
    final subtitle = item.error != null
        ? item.error!
        : item.info != null
            ? '${item.info!.lang} • ${item.info!.type.name} • v${item.info!.version ?? '?'}'
            : item.loaded
                ? 'loaded'
                : 'not loaded';
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
            if (item.health != ProviderHealthStatus.healthy) ...[
              const SizedBox(width: 8),
              _HealthPill(status: item.health),
            ],
          ],
        ),
        subtitle: Text(
          item.health != ProviderHealthStatus.healthy &&
                  item.healthError != null
              ? item.healthError!
              : subtitle,
          style: TextStyle(
            color: (item.error != null ||
                    item.health == ProviderHealthStatus.broken)
                ? AppColors.error
                : AppColors.textSecondary,
            fontSize: 12,
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
          color: AppColors.surface,
          onSelected: (v) {
            final bloc = context.read<SourcesBloc>();
            if (v == 'update') bloc.add(SourceUpdated(item.name));
            if (v == 'remove') bloc.add(SourceUninstalled(item.name));
            if (v == 'reset') bloc.add(SourceHealthReset(item.name));
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'update', child: Text('Update')),
            const PopupMenuItem(value: 'remove', child: Text('Remove')),
            if (item.health != ProviderHealthStatus.healthy)
              const PopupMenuItem(value: 'reset', child: Text('Reset')),
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

  Set<String> _installedIds() {
    return sl<ProviderRegistry>()
        .getInstalled()
        .map((e) => e.name)
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
            final installed = _installedIds();
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
                  installedIds: installed,
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
    required this.installedIds,
  });

  final ProviderRepo repo;
  final bool showNsfw;
  final Set<String> installedIds;

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
  Set<String> get installedIds => widget.installedIds;

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
        .where((s) => installedIds.contains(s.id))
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
                              installed: installedIds.contains(source.id),
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
    bloc.add(SourceInstalled(name: source.id, url: fileUrl));
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
    context.read<SourcesBloc>().add(SourceUpdated(source.id));
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
    context.read<SourcesBloc>().add(SourceUninstalled(source.id));
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
