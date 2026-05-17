import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/utils/avatar_palette.dart';

/// `/settings/developers` — credits page.
///
/// Minimal, monochrome layout. Each contributor lives in their own card:
/// header with GitHub avatar + name + role, then a flat list of social
/// links (GitHub, optional Telegram). No accent colors — just neutral
/// surface, white text, muted secondary text.
class DevelopersSettingsScreen extends StatelessWidget {
  const DevelopersSettingsScreen({super.key});

  static const _developers = <_Developer>[
    _Developer(
      name: 'Krishna Vishwakarma',
      role: 'Lead developer',
      description: 'Web & app developer · UI/UX designer',
      github: 'spyou',
      telegram: 'kbot09',
    ),
    _Developer(
      name: 'Prathmesh Kamble',
      role: 'Co-developer',
      description: 'Web developer',
      github: 'flowstrike',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Merge both developers into one card so they read as a single
    // unified credits list. A visible hairline + small vertical
    // breathing room separates each block.
    final divider = Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Container(
        height: 1,
        color: theme.dividerColor.withValues(alpha: 0.7),
      ),
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('Developers'),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.only(top: 4, bottom: 24),
        children: [
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
                for (var i = 0; i < _developers.length; i++) ...[
                  _DeveloperBlock(dev: _developers[i]),
                  if (i < _developers.length - 1) divider,
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Developer {
  const _Developer({
    required this.name,
    required this.role,
    required this.description,
    required this.github,
    this.telegram,
  });
  final String name;
  final String role;
  final String description;
  final String github;
  final String? telegram;
}

/// One developer's block inside the shared Developers card. Renders the
/// header (avatar + name + role + description) and the social link rows
/// for this person. The outer rounded card + the divider between
/// developers is provided by the parent.
class _DeveloperBlock extends StatelessWidget {
  const _DeveloperBlock({required this.dev});
  final _Developer dev;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.color;
    final divider = theme.dividerColor.withValues(alpha: 0.4);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _GithubAvatar(
                  username: dev.github,
                  initials: AvatarPalette.initialsFor(name: dev.name),
                  size: 60,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        dev.name,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                          letterSpacing: -0.2,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        dev.role,
                        style: TextStyle(
                          color: muted,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        dev.description,
                        style: TextStyle(
                          color: muted?.withValues(alpha: 0.75),
                          fontSize: 12.5,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, thickness: 0.5, color: divider),
          _LinkRow(
            label: 'GitHub',
            handle: '@${dev.github}',
            url: 'https://github.com/${dev.github}',
          ),
          if (dev.telegram != null) ...[
            Divider(
              height: 1,
              thickness: 0.5,
              indent: 16,
              endIndent: 16,
              color: divider,
            ),
            _LinkRow(
              label: 'Telegram',
              handle: '@${dev.telegram}',
              url: 'https://t.me/${dev.telegram}',
            ),
          ],
        ],
    );
  }
}

class _GithubAvatar extends StatelessWidget {
  const _GithubAvatar({
    required this.username,
    required this.initials,
    required this.size,
  });

  final String username;
  final String initials;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mutedBg = theme.colorScheme.surfaceContainerHighest
        .withValues(alpha: 0.6);
    final fgColor = theme.textTheme.bodySmall?.color;
    final url = 'https://github.com/$username.png?size=200';
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(shape: BoxShape.circle, color: mutedBg),
      child: Text(
        initials,
        style: TextStyle(
          color: fgColor,
          fontWeight: FontWeight.w700,
          fontSize: size * 0.36,
        ),
      ),
    );
    return ClipOval(
      child: CachedNetworkImage(
        imageUrl: url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        fadeInDuration: const Duration(milliseconds: 180),
        placeholder: (_, _) => fallback,
        errorWidget: (_, _, _) => fallback,
      ),
    );
  }
}

class _LinkRow extends StatelessWidget {
  const _LinkRow({
    required this.label,
    required this.handle,
    required this.url,
  });

  final String label;
  final String handle;
  final String url;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.color;
    return InkWell(
      onTap: () async {
        final uri = Uri.parse(url);
        if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
          await launchUrl(uri, mode: LaunchMode.platformDefault);
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Text(
              label,
              style: const TextStyle(
                fontWeight: FontWeight.w500,
                fontSize: 14.5,
              ),
            ),
            const Spacer(),
            Text(
              handle,
              style: TextStyle(
                color: muted,
                fontSize: 13.5,
              ),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
            const SizedBox(width: 10),
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
