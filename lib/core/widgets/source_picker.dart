import 'package:flutter/material.dart';
import 'app_snack.dart';

import '../di/injection.dart';
import '../models/provider_info.dart';
import '../repository/provider_repository.dart';
import '../state/active_source_cubit.dart';
import '../theme/app_colors.dart';

/// Two-tab source picker (Manga / Novel). Pulls each provider's
/// [ProviderInfo] up front so we can group by type — Manga and Both go
/// under the Manga tab, Novel and Both go under the Novel tab (the dual
/// providers appear in both, since either reader can open them).
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
    builder: (ctx) => _SourcePickerSheet(activeSourceId: cubit.state),
  );
  if (picked != null && picked != cubit.state) cubit.setActive(picked);
  return picked;
}

class _SourcePickerSheet extends StatefulWidget {
  const _SourcePickerSheet({required this.activeSourceId});
  final String? activeSourceId;

  @override
  State<_SourcePickerSheet> createState() => _SourcePickerSheetState();
}

class _SourcePickerSheetState extends State<_SourcePickerSheet> {
  late final Future<List<_TypedSource>> _future = _resolve();

  Future<List<_TypedSource>> _resolve() async {
    final repo = sl<ProviderRepository>();
    final out = <_TypedSource>[];
    for (final p in repo.providers) {
      try {
        // getInfo() round-trips through QuickJS but is cheap (<10ms) — and
        // there are typically <10 providers, so the total open-latency is
        // imperceptible.
        final info = await p.getInfo();
        out.add(_TypedSource(sourceId: p.sourceId, info: info));
      } catch (_) {
        // Provider failed to introspect — surface it under Manga as a
        // best-effort default so the user can still see it.
        out.add(_TypedSource(
          sourceId: p.sourceId,
          info: ProviderInfo(
            name: p.sourceId,
            lang: '',
            baseUrl: '',
            logo: null,
            type: ProviderType.manga,
            version: '?',
          ),
        ));
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.7,
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
                        _SourceList(
                          sources: all,
                          emptyLabel: 'No sources installed.',
                          activeSourceId: widget.activeSourceId,
                        ),
                        _SourceList(
                          sources: manga,
                          emptyLabel: 'No manga sources installed.',
                          activeSourceId: widget.activeSourceId,
                        ),
                        _SourceList(
                          sources: novel,
                          emptyLabel: 'No novel sources installed.',
                          activeSourceId: widget.activeSourceId,
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

class _SourceList extends StatelessWidget {
  const _SourceList({
    required this.sources,
    required this.emptyLabel,
    required this.activeSourceId,
  });
  final List<_TypedSource> sources;
  final String emptyLabel;
  final String? activeSourceId;

  @override
  Widget build(BuildContext context) {
    if (sources.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(32),
        child: Center(
          child: Text(
            emptyLabel,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 14,
            ),
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(top: 4, bottom: 16),
      shrinkWrap: true,
      itemCount: sources.length,
      itemBuilder: (_, i) {
        final s = sources[i];
        final isActive = s.sourceId == activeSourceId;
        return ListTile(
          onTap: () => Navigator.pop(context, s.sourceId),
          leading: CircleAvatar(
            radius: 18,
            backgroundColor: AppColors.card,
            child: Text(
              s.info.name.isNotEmpty
                  ? s.info.name[0].toUpperCase()
                  : s.sourceId[0].toUpperCase(),
              style: const TextStyle(
                color: AppColors.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          title: Text(s.info.name.isEmpty ? s.sourceId : s.info.name),
          subtitle: Text(
            s.info.baseUrl.isEmpty ? s.sourceId : s.info.baseUrl,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: isActive
              ? const Icon(Icons.check, color: AppColors.primary)
              : null,
        );
      },
    );
  }
}

class _TypedSource {
  const _TypedSource({required this.sourceId, required this.info});
  final String sourceId;
  final ProviderInfo info;
}
