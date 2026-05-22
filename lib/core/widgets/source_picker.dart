import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'app_snack.dart';

import '../di/injection.dart';
import '../models/provider_info.dart';
import '../provider/provider_manager.dart';
import '../provider/provider_registry.dart';
import '../provider/provider_repo_registry.dart';
import '../repository/provider_repository.dart';
import '../state/active_source_cubit.dart';
import '../theme/app_colors.dart';

/// Two-tab source picker (All / Manga / Novel). Sources are grouped by
/// the repo they were installed from. Spyou's default repo (whatever
/// `DEFAULT_PROVIDER_REPO` points at) is expanded by default; every
/// other group is collapsed so the sheet stays compact when the user
/// tracks many repos.
///
/// Returns the composite `providerKey` of the chosen source. The active
/// source cubit normalizes that key on persistence; the runtime swap
/// (load chosen JS, unload sibling-from-other-repo) is done here.
Future<String?> showSourcePicker(BuildContext context) async {
  final cubit = sl<ActiveSourceCubit>();
  final providers = sl<ProviderRepository>().providers;
  if (providers.isEmpty) {
    ScaffoldMessenger.of(context).showAppSnack(
      const SnackBar(content: Text('No providers installed.')),
    );
    return null;
  }

  final picked = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: AppColors.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => _SourcePickerSheet(activeKey: cubit.state),
  );
  if (picked != null && picked != cubit.state) {
    // Swap the runtime entry so the chosen repo's JS is the live one
    // for this sourceId. Best-effort: if the load fails, the persisted
    // active key still flips — the user can retry from Sources.
    try {
      await sl<ProviderRegistry>().setRuntimeActive(picked);
    } catch (_) {/* tolerated */}
    cubit.setActive(picked);
  }
  return picked;
}

/// Composite key + provider metadata used by the picker. We resolve
/// [info] up front so we can route to the All / Manga / Novel tabs and
/// label each row before the sheet animates in.
class _TypedSource {
  const _TypedSource({
    required this.providerKey,
    required this.sourceId,
    required this.repoUrl,
    required this.repoDisplayName,
    required this.info,
  });

  final String providerKey;
  final String sourceId;
  final String repoUrl;
  final String repoDisplayName;
  final ProviderInfo info;
}

class _SourcePickerSheet extends StatefulWidget {
  const _SourcePickerSheet({required this.activeKey});
  final String? activeKey;

  @override
  State<_SourcePickerSheet> createState() => _SourcePickerSheetState();
}

class _SourcePickerSheetState extends State<_SourcePickerSheet> {
  late final Future<List<_TypedSource>> _future = _resolve();

  /// Resolves installed registry entries + their cached [ProviderInfo]
  /// (loaded providers only). Entries whose JS is not currently in the
  /// runtime get a synthetic [ProviderInfo] so they still render —
  /// users need a way to swap to them via the picker even when their
  /// sibling-from-another-repo is the active runtime entry.
  Future<List<_TypedSource>> _resolve() async {
    final repo = sl<ProviderRepository>();
    final registry = sl<ProviderRegistry>();
    final reposRegistry = sl<ProviderReposRegistry>();
    // Index every tracked repo's manifest sources by sourceId so the
    // fallback path can recover the source's TYPE (manga / novel /
    // both) and `lang` even when the runtime hasn't loaded the JS yet.
    // Without this, every not-yet-loaded source defaulted to
    // ProviderType.manga and the Novel tab silently dropped half the
    // repo's catalog.
    final manifestBySourceId = <String, RepoSource>{};
    for (final r in reposRegistry.getAll()) {
      for (final s in r.sources) {
        manifestBySourceId[s.id] = s;
      }
    }
    final loadedBySourceId = <String, JsProvider>{
      for (final p in repo.providers) p.sourceId: p,
    };
    final out = <_TypedSource>[];
    for (final entry in registry.getInstalled()) {
      final key = ProviderRegistry.providerKey(entry.originRepoUrl, entry.name);
      final live = loadedBySourceId[entry.name];
      ProviderInfo info;
      if (live != null && live.originRepoUrl == entry.originRepoUrl) {
        try {
          info = await live.getInfo();
        } catch (_) {
          info = _fallbackInfo(entry.name, manifestBySourceId[entry.name]);
        }
      } else {
        // Not currently active in the runtime (a sibling from another
        // repo has the slot, OR the JS failed to load). The row still
        // renders so the user can tap to make it live.
        info = _fallbackInfo(entry.name, manifestBySourceId[entry.name]);
      }
      out.add(_TypedSource(
        providerKey: key,
        sourceId: entry.name,
        repoUrl: entry.originRepoUrl,
        repoDisplayName: entry.displayName.isEmpty
            ? _shortRepoLabel(entry.originRepoUrl)
            : entry.displayName,
        info: info,
      ));
    }
    return out;
  }

  ProviderInfo _fallbackInfo(String sourceId, RepoSource? manifest) {
    final type = _typeFromManifest(manifest?.type);
    return ProviderInfo(
      name: manifest?.name ?? sourceId,
      lang: manifest?.lang ?? '',
      baseUrl: '',
      logo: manifest?.logo,
      type: type,
      version: manifest?.version ?? '?',
    );
  }

  ProviderType _typeFromManifest(String? raw) {
    switch (raw) {
      case 'novel':
        return ProviderType.novel;
      case 'both':
        return ProviderType.both;
      case 'manga':
      default:
        return ProviderType.manga;
    }
  }

  /// Short label for repos whose entry has no snapshotted displayName
  /// — derived from the URL host so the subtitle is still informative.
  String _shortRepoLabel(String repoUrl) {
    if (repoUrl.isEmpty) return 'Unknown repo';
    if (repoUrl == kBundledRepoUrl) return 'Bundled';
    if (repoUrl == kBuiltinRepoUrl) return 'Built-in';
    final uri = Uri.tryParse(repoUrl);
    if (uri == null) return repoUrl;
    return uri.host.isEmpty ? repoUrl : uri.host;
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.8,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 14, 20, 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Select Source',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
              ),
              const TabBar(
                tabs: [
                  Tab(text: 'All'),
                  Tab(text: 'Manga'),
                  Tab(text: 'Novel'),
                ],
                dividerHeight: 0,
                indicatorSize: TabBarIndicatorSize.label,
              ),
              Flexible(
                child: FutureBuilder<List<_TypedSource>>(
                  future: _future,
                  builder: (context, snap) {
                    if (snap.connectionState != ConnectionState.done) {
                      return const Padding(
                        padding: EdgeInsets.all(40),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }
                    final all = snap.data ?? const <_TypedSource>[];
                    final manga = all.where((s) =>
                        s.info.type == ProviderType.manga ||
                        s.info.type == ProviderType.both).toList();
                    final novel = all.where((s) =>
                        s.info.type == ProviderType.novel ||
                        s.info.type == ProviderType.both).toList();
                    return TabBarView(
                      children: [
                        _GroupedSourceList(
                          sources: all,
                          emptyLabel: 'No sources installed.',
                          activeKey: widget.activeKey,
                        ),
                        _GroupedSourceList(
                          sources: manga,
                          emptyLabel: 'No manga sources installed.',
                          activeKey: widget.activeKey,
                        ),
                        _GroupedSourceList(
                          sources: novel,
                          emptyLabel: 'No novel sources installed.',
                          activeKey: widget.activeKey,
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Renders sources grouped by repoUrl. Spyou's default repo (whatever
/// `DEFAULT_PROVIDER_REPO` points at) starts expanded; every other
/// group starts collapsed. The currently-active row highlights inside
/// its group.
class _GroupedSourceList extends StatelessWidget {
  const _GroupedSourceList({
    required this.sources,
    required this.emptyLabel,
    required this.activeKey,
  });
  final List<_TypedSource> sources;
  final String emptyLabel;
  final String? activeKey;

  @override
  Widget build(BuildContext context) {
    if (sources.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(32),
        child: Center(
          child: Text(
            emptyLabel,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 14,
            ),
          ),
        ),
      );
    }
    // Preserve discovery order so Spyou's default repo (seeded first)
    // floats to the top, with manual / third-party repos following.
    // The two synthetic repos `builtin://` (legacy migration fallback)
    // and `bundled://` (loadBundledProviders) are merged into a single
    // "Built-in" group — they both represent "shipped with the APK",
    // so showing them as two adjacent groups was just noise.
    final groups = <String, List<_TypedSource>>{};
    for (final s in sources) {
      final groupKey = (s.repoUrl == kBuiltinRepoUrl ||
              s.repoUrl == kBundledRepoUrl)
          ? kBundledRepoUrl
          : s.repoUrl;
      groups.putIfAbsent(groupKey, () => <_TypedSource>[]).add(s);
    }
    // Within the Built-in group, drop exact duplicate sourceIds — the
    // migration plus `loadBundledProviders` can land both a
    // `builtin://weebcentral` and a `bundled://weebcentral`.
    final builtin = groups[kBundledRepoUrl];
    if (builtin != null) {
      final seen = <String>{};
      builtin.retainWhere((s) => seen.add(s.sourceId));
    }
    final entries = groups.entries.toList(growable: false);
    final defaultRepoUrl =
        dotenv.maybeGet('DEFAULT_PROVIDER_REPO')?.trim() ?? '';
    return ListView.builder(
      padding: const EdgeInsets.only(top: 4, bottom: 16),
      itemCount: entries.length,
      itemBuilder: (_, i) {
        final e = entries[i];
        final repoUrl = e.key;
        final groupSources = e.value;
        final repoLabel = repoUrl == kBundledRepoUrl
            ? 'Built-in'
            : groupSources.first.repoDisplayName;
        // Auto-expand the configured default repo, the merged built-in
        // group, AND any group that contains the currently-active source
        // so the user lands on it directly.
        final containsActive = activeKey != null &&
            groupSources.any((s) => s.providerKey == activeKey);
        final expanded = repoUrl == defaultRepoUrl ||
            repoUrl == kBundledRepoUrl ||
            containsActive;
        return _RepoGroup(
          repoLabel: repoLabel,
          sources: groupSources,
          activeKey: activeKey,
          expandedByDefault: expanded,
        );
      },
    );
  }
}

class _RepoGroup extends StatefulWidget {
  const _RepoGroup({
    required this.repoLabel,
    required this.sources,
    required this.activeKey,
    required this.expandedByDefault,
  });
  final String repoLabel;
  final List<_TypedSource> sources;
  final String? activeKey;
  final bool expandedByDefault;

  @override
  State<_RepoGroup> createState() => _RepoGroupState();
}

class _RepoGroupState extends State<_RepoGroup> {
  late bool _expanded = widget.expandedByDefault;

  @override
  Widget build(BuildContext context) {
    final installedCount = widget.sources.length;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(12),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 10, 14, 10),
                child: Row(
                  children: [
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
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        widget.repoLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Text(
                      '$installedCount',
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              alignment: Alignment.topCenter,
              child: !_expanded
                  ? const SizedBox.shrink()
                  : Column(
                      children: [
                        const Divider(
                            height: 1, color: AppColors.divider),
                        ...widget.sources.map(
                          (s) => _SourceRow(
                            source: s,
                            isActive: s.providerKey == widget.activeKey,
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SourceRow extends StatelessWidget {
  const _SourceRow({required this.source, required this.isActive});
  final _TypedSource source;
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    final s = source;
    final title = s.info.name.isEmpty ? s.sourceId : s.info.name;
    // Subtitle prefers the source's language tag (e.g. "en"). The repo
    // display name is already shown by the group header, so we only
    // fall back to it when language is empty AND the group's name
    // wouldn't be the same redundant string. When everything's empty,
    // drop the subtitle entirely.
    final lang = s.info.lang.trim();
    final showRepoSubtitle = lang.isEmpty &&
        s.repoUrl != kBundledRepoUrl &&
        s.repoUrl != kBuiltinRepoUrl;
    final subtitle = lang.isNotEmpty
        ? lang.toUpperCase()
        : (showRepoSubtitle ? s.repoDisplayName : null);
    return Material(
      color: isActive
          ? AppColors.primary.withValues(alpha: 0.10)
          : Colors.transparent,
      child: InkWell(
        onTap: () => Navigator.pop(context, s.providerKey),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: AppColors.cardElevated,
                child: Text(
                  title.isNotEmpty ? title[0].toUpperCase() : '?',
                  style: const TextStyle(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (isActive)
                const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: Icon(Icons.check, color: AppColors.primary),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
