import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

/// Compact search field shown at the top of the Library.
/// Emits raw text changes; the BLoC handles debouncing.
class LibrarySearchBar extends StatefulWidget {
  const LibrarySearchBar({
    super.key,
    required this.onChanged,
    this.initial = '',
  });

  final ValueChanged<String> onChanged;
  final String initial;

  @override
  State<LibrarySearchBar> createState() => _LibrarySearchBarState();
}

class _LibrarySearchBarState extends State<LibrarySearchBar> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _clear() {
    _controller.clear();
    widget.onChanged('');
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(12),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            const Icon(Icons.search_rounded,
                size: 18, color: AppColors.textTertiary),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _controller,
                onChanged: (v) {
                  widget.onChanged(v);
                  setState(() {});
                },
                textInputAction: TextInputAction.search,
                cursorColor: AppColors.primary,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 14,
                ),
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: 'Search your library',
                  hintStyle: TextStyle(
                    color: AppColors.textTertiary,
                    fontSize: 14,
                  ),
                  contentPadding: EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
            if (_controller.text.isNotEmpty)
              GestureDetector(
                onTap: _clear,
                behavior: HitTestBehavior.opaque,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                  child: Icon(Icons.close_rounded,
                      size: 18, color: AppColors.textSecondary),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
