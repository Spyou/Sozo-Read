import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import '../../../core/services/image_cache_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/di/injection.dart';
import '../../../core/state/active_source_cubit.dart';
import '../../../core/state/auth_service.dart';
import '../../../core/state/novel_prefs_cubit.dart';
import '../../../core/state/theme_cubit.dart';
import '../../../core/utils/avatar_palette.dart';
import '../../../core/widgets/source_picker.dart';
import '../widgets/settings_widgets.dart';

/// Top-level `/settings` screen.
///
/// Subpage style (option B): a single short list of tappable rows. Each row
/// either opens a dedicated subpage (`/settings/appearance` etc.) or
/// navigates to an existing feature screen (`/history`, `/downloads`,
/// `/sources`). The detail tiles (theme picker, sliders, font family, etc.)
/// live on the subpages.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider.value(value: sl<ActiveSourceCubit>()),
        BlocProvider.value(value: sl<ThemeCubit>()),
        BlocProvider.value(value: sl<NovelPrefsCubit>()),
      ],
      child: const _SettingsView(),
    );
  }
}

class _SettingsView extends StatelessWidget {
  const _SettingsView();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.only(top: 4, bottom: 24),
        children: [
          // Hero account row. Either "Sign in" or the signed-in profile
          // summary; either way it sits in its own card.
          const _AccountSection(),

          // Source picker — single row, opens existing bottom sheet.
          BlocBuilder<ActiveSourceCubit, String?>(
            builder: (context, active) {
              return SettingsCard(
                children: [
                  SettingsTile(
                    icon: Icons.collections_bookmark_rounded,
                    title: 'Source',
                    subtitle: active ?? 'none',
                    onTap: () => showSourcePicker(context),
                  ),
                ],
              );
            },
          ),

          // Configuration subpages.
          SettingsCard(
            children: [
              SettingsTile(
                icon: Icons.palette_outlined,
                title: 'Appearance',
                onTap: () => context.push('/settings/appearance'),
              ),
              SettingsTile(
                icon: Icons.menu_book_rounded,
                title: 'Reading',
                onTap: () => context.push('/settings/reading'),
              ),
              SettingsTile(
                icon: Icons.sd_storage_outlined,
                title: 'Storage',
                onTap: () => context.push('/settings/storage'),
              ),
              SettingsTile(
                icon: Icons.sync_alt_rounded,
                title: 'Trackers',
                subtitle: 'AniList sync',
                onTap: () => context.push('/settings/trackers'),
              ),
            ],
          ),

          // Direct navigation rows for full-screen features that already
          // own their own pages.
          SettingsCard(
            children: [
              SettingsTile(
                icon: Icons.history_rounded,
                title: 'Reading history',
                onTap: () => context.pushNamed('history'),
              ),
              SettingsTile(
                icon: Icons.bookmark_outline,
                title: 'Bookmarks',
                onTap: () => context.pushNamed('bookmarks'),
              ),
              SettingsTile(
                icon: Icons.download_done_rounded,
                title: 'Downloads',
                onTap: () => context.pushNamed('downloads'),
              ),
              SettingsTile(
                icon: Icons.extension_rounded,
                title: 'Providers',
                onTap: () => context.pushNamed('sources'),
              ),
            ],
          ),

          SettingsCard(
            children: [
              SettingsTile(
                icon: Icons.people_outline_rounded,
                title: 'Developers',
                onTap: () => context.push('/settings/developers'),
              ),
              SettingsTile(
                icon: Icons.info_outline,
                title: 'About',
                subtitle: 'v1.0.0',
                onTap: () => context.push('/settings/about'),
              ),
            ],
          ),
        ],
      ),
    );
  }

}

/// Account hero row. Lives in its own card so it visually anchors the
/// top of the screen.
class _AccountSection extends StatefulWidget {
  const _AccountSection();
  @override
  State<_AccountSection> createState() => _AccountSectionState();
}

class _AccountSectionState extends State<_AccountSection> {
  late final AuthService _auth = sl<AuthService>();
  StreamSubscription<AuthChangeEvent>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = _auth.authStream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final signedIn = _auth.isSignedIn;

    if (!signedIn) {
      return SettingsCard(
        children: [
          SettingsTile(
            icon: Icons.account_circle_outlined,
            title: 'Sign in',
            subtitle: 'Sync across devices',
            onTap: () => context.push('/auth'),
          ),
        ],
      );
    }

    final email = _auth.cachedEmail ?? '';
    final name = _auth.displayName ?? email;
    final avatar = _auth.avatarUrl ?? '';
    final color = AvatarPalette.colorFor(_auth.currentUser?.id ?? email);
    final initials = AvatarPalette.initialsFor(
      name: _auth.displayName,
      email: email,
    );
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest
            .withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(14),
      ),
      child: InkWell(
        onTap: () => context.push('/profile'),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
          child: Row(
            children: [
              _ProfileAvatar(url: avatar, initials: initials, color: color),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name.isEmpty ? 'Signed in' : name,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (email.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        email,
                        style: TextStyle(
                          color: theme.textTheme.labelSmall?.color,
                          fontSize: 13,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: theme.iconTheme.color?.withValues(alpha: 0.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProfileAvatar extends StatelessWidget {
  const _ProfileAvatar({
    required this.url,
    required this.initials,
    required this.color,
  });
  final String url;
  final String initials;
  final Color color;

  @override
  Widget build(BuildContext context) {
    const size = 48.0;
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: 0.18),
        border: Border.all(color: color.withValues(alpha: 0.5), width: 1.4),
      ),
      child: Text(
        initials,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w800,
          fontSize: 17,
        ),
      ),
    );
    if (url.isEmpty) return fallback;
    return ClipOval(
      child: CachedNetworkImage(
        cacheManager: appImageCacheManager,
        imageUrl: url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        fadeInDuration: const Duration(milliseconds: 150),
        errorWidget: (_, _, _) => fallback,
        placeholder: (_, _) => fallback,
      ),
    );
  }
}

