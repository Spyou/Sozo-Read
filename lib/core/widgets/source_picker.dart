import 'package:flutter/material.dart';

import '../di/injection.dart';
import '../repository/provider_repository.dart';
import '../state/active_source_cubit.dart';
import '../theme/app_colors.dart';

/// Shared bottom-sheet that lists installed providers and updates the active
/// source via [ActiveSourceCubit]. Returns the picked sourceId or null.
Future<String?> showSourcePicker(BuildContext context) async {
  final cubit = sl<ActiveSourceCubit>();
  final active = cubit.state;
  final sourceIds = sl<ProviderRepository>().providers.map((p) => p.sourceId).toList();
  if (sourceIds.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('No providers installed.')),
    );
    return null;
  }
  final picked = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 18, 20, 12),
            child: Row(children: [
              Text(
                'Select Source',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
            ]),
          ),
          for (final id in sourceIds)
            ListTile(
              onTap: () => Navigator.pop(ctx, id),
              leading: CircleAvatar(
                radius: 18,
                backgroundColor: AppColors.card,
                child: Text(
                  id.isNotEmpty ? id[0].toUpperCase() : '?',
                  style: const TextStyle(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              title: Text(id),
              trailing: id == active
                  ? const Icon(Icons.check, color: AppColors.primary)
                  : null,
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (picked != null && picked != active) cubit.setActive(picked);
  return picked;
}
