import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

/// One row inside a [SettingsCard]. Compact, icon + title + optional
/// subtitle/value + chevron. Keep `subtitle` short — long subtitles are
/// what made the old Settings feel cluttered.
class SettingsTile extends StatelessWidget {
  const SettingsTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.destructive = false,
  });

  final IconData icon;
  final String title;
  final String? subtitle;

  /// Optional widget rendered on the right (color swatch, value chip, etc).
  /// If null, a chevron is drawn when [onTap] is set.
  final Widget? trailing;
  final VoidCallback? onTap;

  /// Renders the row in a "danger" red tint (sign-out, clear cache, ...).
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.color;
    final fg = destructive ? const Color(0xFFE57373) : null;
    final trailingWidget = trailing ??
        (onTap == null
            ? null
            : Icon(
                Icons.chevron_right_rounded,
                color: muted?.withValues(alpha: 0.8),
                size: 22,
              ));
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(icon, color: fg ?? muted, size: 22),
            const SizedBox(width: 14),
            // Title is Expanded so it claims ALL remaining horizontal space.
            // The subtitle that follows takes its intrinsic width and the
            // trailing chevron is non-flex — this guarantees the chevron
            // lands at the same far-right position whether or not a
            // subtitle is present (otherwise short subtitles like
            // "weebcentral" pull the chevron left).
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  color: fg,
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(width: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 200),
                child: Text(
                  subtitle!,
                  style: TextStyle(
                    color: muted,
                    fontSize: 13,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
            if (trailingWidget != null) ...[
              const SizedBox(width: 8),
              trailingWidget,
            ],
          ],
        ),
      ),
    );
  }
}

/// Visually groups a set of [SettingsTile]s into a rounded card with a thin
/// hairline divider between each row. Mirrors the iOS Settings look.
class SettingsCard extends StatelessWidget {
  const SettingsCard({super.key, required this.children, this.margin});

  final List<Widget> children;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final separated = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      separated.add(children[i]);
      if (i < children.length - 1) {
        separated.add(Divider(
          height: 1,
          thickness: 0.5,
          indent: 52,
          endIndent: 0,
          color: theme.dividerColor.withValues(alpha: 0.4),
        ));
      }
    }
    return Container(
      margin: margin ?? const EdgeInsets.fromLTRB(16, 6, 16, 16),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest
            .withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: separated,
      ),
    );
  }
}

/// Optional small uppercase label drawn above a card. Use sparingly — most
/// top-level groups don't need a label.
class SettingsSectionLabel extends StatelessWidget {
  const SettingsSectionLabel(this.label, {super.key});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 18, 20, 6),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          color: Theme.of(context).textTheme.labelSmall?.color,
          fontWeight: FontWeight.w600,
          fontSize: 11,
          letterSpacing: 1.1,
        ),
      ),
    );
  }
}

/// Bottom-sheet shell shared by the various pickers. Rounded top, drag
/// handle, surface fill.
class SettingsSheetShell extends StatelessWidget {
  const SettingsSheetShell({
    super.key,
    required this.title,
    required this.child,
  });

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 6),
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: (theme.textTheme.labelSmall?.color ??
                          AppColors.textTertiary)
                      .withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
              ),
            ),
            child,
          ],
        ),
      ),
    );
  }
}

/// Color swatch used inside the accent-color picker.
class AccentSwatch extends StatelessWidget {
  const AccentSwatch({
    super.key,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? Colors.white : Colors.transparent,
            width: 1.6,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: color.withValues(alpha: 0.45),
                    blurRadius: 10,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
        child: selected
            ? const Icon(Icons.check, color: Colors.white, size: 20)
            : null,
      ),
    );
  }
}
