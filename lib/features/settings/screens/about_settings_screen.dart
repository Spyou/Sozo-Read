import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../widgets/settings_widgets.dart';

/// `/settings/about` — minimal About page for end-users.
///
/// Deliberately user-facing: no mention of the tech stack, no library
/// credits, no internal architecture. Just the app's name, version, a
/// short one-liner about what it does, and a support channel.
class AboutSettingsScreen extends StatelessWidget {
  const AboutSettingsScreen({super.key});

  static const _appName = 'Sozo Read';
  static const _appVersion = 'v1.0.0';
  static const _tagline = 'Read manga and novels anytime, anywhere.';
  static const _telegramHandle = 'sozo_disscussion';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.color;

    return Scaffold(
      appBar: AppBar(
        title: const Text('About'),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(0, 24, 0, 32),
        children: [
          Center(
            child: Container(
              width: 96,
              height: 96,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(22),
              ),
              child: Image.asset(
                'assets/branding/sozo_logo_red.png',
                fit: BoxFit.contain,
              ),
            ),
          ),
          const SizedBox(height: 22),
          const Center(
            child: Text(
              _appName,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 22,
                letterSpacing: -0.3,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Center(
            child: Text(
              _appVersion,
              style: TextStyle(
                color: muted,
                fontSize: 13,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.2,
              ),
            ),
          ),
          const SizedBox(height: 22),
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                _tagline,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: muted,
                  fontSize: 14.5,
                  height: 1.45,
                ),
              ),
            ),
          ),
          const SizedBox(height: 32),
          SettingsCard(
            children: [
              SettingsTile(
                icon: Icons.forum_rounded,
                title: 'Community & feedback',
                subtitle: '@$_telegramHandle',
                onTap: () => _openTelegram(context),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                '© ${DateTime.now().year}  $_appName',
                style: TextStyle(
                  color: muted?.withValues(alpha: 0.7),
                  fontSize: 12,
                  letterSpacing: 0.3,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openTelegram(BuildContext context) async {
    final uri = Uri.parse('https://t.me/$_telegramHandle');
    // externalApplication prefers the Telegram app if installed, otherwise
    // falls back to the system browser (which redirects to t.me's web view).
    try {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        await launchUrl(uri, mode: LaunchMode.platformDefault);
      }
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Couldn't open Telegram: $e")),
      );
    }
  }
}
