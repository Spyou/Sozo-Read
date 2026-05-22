import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/state/novel_prefs_cubit.dart';
import '../../../../core/theme/app_colors.dart';

/// Per-book font picker. Each row shows the font label rendered in
/// that font so the user can compare at a glance. Tapping a row writes
/// the per-book override; an "Use global" tile clears it.
class FontPickerSheet extends StatelessWidget {
  const FontPickerSheet({
    super.key,
    required this.sourceId,
    required this.bookId,
  });

  final String sourceId;
  final String bookId;

  static Future<void> show(
    BuildContext context, {
    required String sourceId,
    required String bookId,
  }) {
    final cubit = context.read<NovelPrefsCubit>();
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => BlocProvider.value(
        value: cubit,
        child: FontPickerSheet(sourceId: sourceId, bookId: bookId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<NovelPrefsCubit, NovelPrefs>(
      builder: (context, prefs) {
        final cubit = context.read<NovelPrefsCubit>();
        final key = NovelPrefsCubit.bookKey(sourceId, bookId);
        final override = prefs.perBookFontFamily[key];
        final effective = override ?? prefs.fontFamily;
        return Container(
          decoration: const BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: SafeArea(
            top: false,
            child: DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.6,
              maxChildSize: 0.92,
              minChildSize: 0.4,
              builder: (_, scrollCtrl) {
                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 14, 12, 4),
                      child: Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Font',
                              style: TextStyle(
                                color: AppColors.textPrimary,
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          if (override != null)
                            TextButton(
                              onPressed: () {
                                cubit.setFontForBook(sourceId, bookId, null);
                              },
                              child: const Text('Use global'),
                            ),
                          IconButton(
                            icon: const Icon(Icons.close_rounded,
                                color: AppColors.textSecondary),
                            onPressed: () => Navigator.of(context).pop(),
                          ),
                        ],
                      ),
                    ),
                    const Divider(color: AppColors.divider, height: 1),
                    Expanded(
                      child: ListView(
                        controller: scrollCtrl,
                        padding: EdgeInsets.zero,
                        children: [
                          for (final label
                              in NovelPrefsCubit.familyOptions)
                            _FontRow(
                              label: label,
                              selected: label == effective,
                              onTap: () {
                                cubit.setFontForBook(
                                    sourceId, bookId, label);
                              },
                            ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }
}

class _FontRow extends StatelessWidget {
  const _FontRow({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final base = const TextStyle(
      color: AppColors.textPrimary,
      fontSize: 17,
      height: 1.35,
    );
    final preview = NovelPrefsCubit.applyFontLabel(label, base);
    return ListTile(
      onTap: onTap,
      title: Text(
        label,
        style: preview.copyWith(
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          'The quick brown fox jumps over the lazy dog.',
          style: preview,
        ),
      ),
      trailing: selected
          ? Icon(Icons.check_rounded,
              color: Theme.of(context).colorScheme.primary)
          : null,
    );
  }
}
