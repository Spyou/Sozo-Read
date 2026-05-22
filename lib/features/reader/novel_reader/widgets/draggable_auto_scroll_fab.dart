import 'dart:math' as math;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';

/// Single-icon circular button overlaid on the novel reader whenever
/// per-book auto-scroll is on. Draggable within the reader screen
/// bounds; tapping opens the auto-scroll sheet (speed slider).
///
/// Mirrors `_DraggableAutoScrollFab` in the manga reader — pan is
/// paint-only via Transform.translate + a RepaintBoundary'd icon, with
/// `DragStartBehavior.down` so the drag follows the finger from the
/// first pixel.
class DraggableNovelAutoScrollFab extends StatefulWidget {
  const DraggableNovelAutoScrollFab({super.key, required this.onTap});
  final VoidCallback onTap;

  @override
  State<DraggableNovelAutoScrollFab> createState() =>
      _DraggableNovelAutoScrollFabState();
}

class _DraggableNovelAutoScrollFabState
    extends State<DraggableNovelAutoScrollFab> {
  static const double _size = 44;
  static const double _margin = 16;

  final ValueNotifier<Offset?> _offset = ValueNotifier<Offset?>(null);

  @override
  void dispose() {
    _offset.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        if (_offset.value == null && w > _size && h > _size) {
          _offset.value = Offset(w - _size - _margin, h * 0.45);
        }
        final maxX = math.max(0.0, w - _size);
        final maxY = math.max(0.0, h - _size);
        return ValueListenableBuilder<Offset?>(
          valueListenable: _offset,
          builder: (context, o, child) {
            if (o == null) return const SizedBox.shrink();
            return Transform.translate(
              offset: o,
              child: Align(
                alignment: Alignment.topLeft,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  dragStartBehavior: DragStartBehavior.down,
                  onTap: widget.onTap,
                  onPanUpdate: (d) {
                    final next = o + d.delta;
                    _offset.value = Offset(
                      next.dx.clamp(0.0, maxX),
                      next.dy.clamp(0.0, maxY),
                    );
                  },
                  child: child,
                ),
              ),
            );
          },
          child: const RepaintBoundary(child: _NovelAutoScrollFabIcon()),
        );
      },
    );
  }
}

class _NovelAutoScrollFabIcon extends StatelessWidget {
  const _NovelAutoScrollFabIcon();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      decoration: const BoxDecoration(
        color: Color(0x8C000000),
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Color(0x55000000),
            blurRadius: 6,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: const Center(
        child: Icon(
          Icons.play_circle_rounded,
          color: AppColors.primary,
          size: 26,
        ),
      ),
    );
  }
}
