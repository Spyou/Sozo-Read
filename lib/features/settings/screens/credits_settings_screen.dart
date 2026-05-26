import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/utils/avatar_palette.dart';

/// `/settings/credits` — testers, suggestion-givers, and other
/// contributors who shape the app via feedback but don't ship code.
/// Sister screen to [DevelopersSettingsScreen].
class CreditsSettingsScreen extends StatelessWidget {
  const CreditsSettingsScreen({super.key});

  /// Add new entries here. Telegram handle is required so the tap-row
  /// links somewhere meaningful; name + role are how they appear in
  /// the card. Order is preserved as written.
  static const _contributors = <_Contributor>[
    _Contributor(
      name: 'AndreaHRwife',
      role: 'Tester · Suggestions',
      telegram: 'AndreaHRwife',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final divider = Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Container(
        height: 1,
        color: theme.dividerColor.withValues(alpha: 0.7),
      ),
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('Credits'),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.only(top: 4, bottom: 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
            child: Text(
              'Thanks to the people whose testing, bug reports, and '
              'suggestions shape Sozo Read.',
              style: TextStyle(
                color: theme.textTheme.bodySmall?.color
                    ?.withValues(alpha: 0.85),
                fontSize: 12.5,
                height: 1.4,
              ),
            ),
          ),
          Container(
            margin: const EdgeInsets.fromLTRB(16, 6, 16, 16),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest
                  .withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < _contributors.length; i++) ...[
                  _ContributorBlock(c: _contributors[i]),
                  if (i < _contributors.length - 1) divider,
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Contributor {
  const _Contributor({
    required this.name,
    required this.role,
    required this.telegram,
  });
  final String name;
  final String role;
  final String telegram;
}

/// Visual mirror of `_DeveloperBlock` from the developers screen but
/// trimmed for non-coding contributors: tinted-initial avatar instead
/// of a GitHub one (Telegram doesn't expose a public avatar URL),
/// no description line, single Telegram link row.
class _ContributorBlock extends StatelessWidget {
  const _ContributorBlock({required this.c});
  final _Contributor c;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.color;
    final divider = theme.dividerColor.withValues(alpha: 0.4);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _InitialsAvatar(
                initials: AvatarPalette.initialsFor(name: c.name),
                seed: c.telegram,
                size: 48,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      c.name,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        letterSpacing: -0.2,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      c.role,
                      style: TextStyle(
                        color: muted,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Divider(height: 1, thickness: 0.5, color: divider),
        _TelegramRow(handle: c.telegram),
      ],
    );
  }
}

class _InitialsAvatar extends StatelessWidget {
  const _InitialsAvatar({
    required this.initials,
    required this.seed,
    required this.size,
  });
  final String initials;
  final String seed;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = AvatarPalette.colorFor(seed);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: 0.25),
      ),
      child: Text(
        initials,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w800,
          fontSize: size * 0.38,
        ),
      ),
    );
  }
}

class _TelegramRow extends StatelessWidget {
  const _TelegramRow({required this.handle});
  final String handle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.color;
    return InkWell(
      onTap: () async {
        final uri = Uri.parse('https://t.me/$handle');
        if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
          await launchUrl(uri, mode: LaunchMode.platformDefault);
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            const Text(
              'Telegram',
              style: TextStyle(fontWeight: FontWeight.w500, fontSize: 14.5),
            ),
            const Spacer(),
            Text(
              '@$handle',
              style: TextStyle(color: muted, fontSize: 13),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.arrow_outward_rounded,
              size: 16,
              color: muted?.withValues(alpha: 0.6),
            ),
          ],
        ),
      ),
    );
  }
}
