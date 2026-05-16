import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/di/injection.dart';
import '../../../core/provider/provider_registry.dart';
import '../../../core/repository/provider_repository.dart';
import '../../../core/theme/app_colors.dart';
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

class _SourcesView extends StatelessWidget {
  const _SourcesView();

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
              decoration: const InputDecoration(labelText: 'Name (e.g. mangadex)'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: urlCtrl,
              decoration: const InputDecoration(labelText: 'JS raw URL'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Install')),
        ],
      ),
    );
    if (ok == true && nameCtrl.text.trim().isNotEmpty && urlCtrl.text.trim().isNotEmpty) {
      if (!context.mounted) return;
      context.read<SourcesBloc>().add(
            SourceInstalled(name: nameCtrl.text.trim(), url: urlCtrl.text.trim()),
          );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Sources'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => context.read<SourcesBloc>().add(const SourcesRefreshed()),
          ),
        ],
      ),
      floatingActionButton: Builder(
        builder: (ctx) => FloatingActionButton(
          backgroundColor: AppColors.primary,
          onPressed: () => _showInstallDialog(ctx),
          child: const Icon(Icons.add),
        ),
      ),
      body: BlocBuilder<SourcesBloc, SourcesState>(
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
      ),
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
        title: Text(item.info?.name ?? item.name),
        subtitle: Text(
          subtitle,
          style: TextStyle(
            color: item.error != null ? AppColors.error : AppColors.textSecondary,
            fontSize: 12,
          ),
        ),
        trailing: PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
          color: AppColors.surface,
          onSelected: (v) {
            final bloc = context.read<SourcesBloc>();
            if (v == 'update') bloc.add(SourceUpdated(item.name));
            if (v == 'remove') bloc.add(SourceUninstalled(item.name));
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'update', child: Text('Update')),
            PopupMenuItem(value: 'remove', child: Text('Remove')),
          ],
        ),
      ),
    );
  }
}
