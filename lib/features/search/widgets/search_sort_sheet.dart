import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../bloc/search_state.dart';

/// Slim bottom-sheet mirroring the reader settings sheet aesthetic — lists
/// search sort options with a primary-coloured check on the active one.
class SearchSortSheet extends StatelessWidget {
  const SearchSortSheet({
    super.key,
    required this.current,
    required this.onSelected,
  });

  final SearchSort current;
  final ValueChanged<SearchSort> onSelected;

  static Future<void> show(
    BuildContext context, {
    required SearchSort current,
    required ValueChanged<SearchSort> onSelected,
  }) {
    return showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => SearchSortSheet(current: current, onSelected: onSelected),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.textTertiary.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 2),
                child: Text(
                  'Sort by',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              for (final s in SearchSort.values)
                _SortRow(
                  label: s.label,
                  selected: s == current,
                  accent: cs.primary,
                  onTap: () {
                    Navigator.of(context).maybePop();
                    onSelected(s);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SortRow extends StatelessWidget {
  const _SortRow({
    required this.label,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 14),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: selected ? AppColors.textPrimary : AppColors.textSecondary,
                  fontSize: 14,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ),
            if (selected) Icon(Icons.check_rounded, color: accent, size: 20),
          ],
        ),
      ),
    );
  }
}
