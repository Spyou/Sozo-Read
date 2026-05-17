import 'package:flutter/material.dart';

import '../../../core/state/novel_prefs_cubit.dart';
import '../../../core/theme/app_colors.dart';

/// 4-segment row that lets the reader pick a [ReadingBgMode].
class ReadingBgPicker extends StatelessWidget {
  const ReadingBgPicker({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final ReadingBgMode value;
  final ValueChanged<ReadingBgMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          for (final mode in ReadingBgMode.values)
            Expanded(
              child: GestureDetector(
                onTap: () => onChanged(mode),
                behavior: HitTestBehavior.opaque,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: value == mode ? AppColors.primary : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _Swatch(mode: mode, selected: value == mode),
                      const SizedBox(width: 8),
                      Text(
                        ReadingBg.label(mode),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: value == mode
                              ? Colors.white
                              : AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.mode, required this.selected});
  final ReadingBgMode mode;
  final bool selected;

  Color get _color {
    switch (mode) {
      case ReadingBgMode.white:
        return const Color(0xFFFAFAF7);
      case ReadingBgMode.sepia:
        return const Color(0xFFF4ECD8);
      case ReadingBgMode.black:
        return Colors.black;
      case ReadingBgMode.system:
        return const Color(0xFF777777);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        color: _color,
        shape: BoxShape.circle,
        border: Border.all(
          color: selected ? Colors.white : AppColors.textTertiary,
          width: 1,
        ),
      ),
      child: mode == ReadingBgMode.system
          ? Icon(Icons.auto_mode,
              size: 9,
              color: selected ? Colors.white : AppColors.textSecondary)
          : null,
    );
  }
}
