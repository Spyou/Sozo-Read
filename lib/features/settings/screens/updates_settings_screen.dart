import 'package:flutter/material.dart';
import 'package:hive/hive.dart';

import '../../../core/di/injection.dart';
import '../../../core/services/update_service.dart';
import '../../../core/theme/app_colors.dart';
import '../widgets/settings_widgets.dart';
import '../widgets/update_available_sheet.dart';

/// `/settings/updates` — toggle auto-check and beta channel; manual check-now.
///
/// Persists two prefs in the shared `settings` Hive box:
///   • `update.auto_check`   bool, default true
///   • `update.beta_channel` bool, default false
class UpdatesSettingsScreen extends StatefulWidget {
  const UpdatesSettingsScreen({super.key});

  @override
  State<UpdatesSettingsScreen> createState() => _UpdatesSettingsScreenState();
}

class _UpdatesSettingsScreenState extends State<UpdatesSettingsScreen> {
  late final Box _box = Hive.box('settings');
  bool _checking = false;
  String? _statusLine;

  bool get _autoCheck =>
      (_box.get(UpdateService.kAutoCheck) as bool?) ?? true;
  bool get _beta =>
      (_box.get(UpdateService.kBetaChannel) as bool?) ?? false;

  Future<void> _setAutoCheck(bool v) async {
    await _box.put(UpdateService.kAutoCheck, v);
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _setBeta(bool v) async {
    await _box.put(UpdateService.kBetaChannel, v);
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _checkNow() async {
    setState(() {
      _checking = true;
      _statusLine = null;
    });
    try {
      final release = await sl<UpdateService>().checkForUpdate(
        includeBeta: _beta,
        forceRefresh: true,
      );
      await sl<UpdateService>().markCheckedNow();
      if (!mounted) return;
      if (release == null) {
        setState(() => _statusLine = 'You are on the latest version.');
      } else {
        setState(() => _statusLine = 'Update available: ${release.tagName}');
        await UpdateAvailableSheet.show(context, release);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _statusLine = 'Check failed: $e');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final last = sl<UpdateService>().lastCheckedAt();
    return Scaffold(
      appBar: AppBar(title: const Text('Updates'), centerTitle: true),
      body: ListView(
        padding: const EdgeInsets.only(top: 4, bottom: 24),
        children: [
          SettingsCard(
            children: [
              SettingsTile(
                icon: Icons.update_rounded,
                title: 'Auto-check on launch',
                subtitle: _autoCheck ? 'On' : 'Off',
                trailing: Switch(
                  value: _autoCheck,
                  onChanged: _setAutoCheck,
                ),
                onTap: () => _setAutoCheck(!_autoCheck),
              ),
              SettingsTile(
                icon: Icons.science_outlined,
                title: 'Beta channel',
                subtitle: _beta ? 'Includes prereleases' : 'Stable only',
                trailing: Switch(
                  value: _beta,
                  onChanged: _setBeta,
                ),
                onTap: () => _setBeta(!_beta),
              ),
            ],
          ),
          SettingsCard(
            children: [
              SettingsTile(
                icon: Icons.cloud_download_outlined,
                title: 'Check now',
                subtitle: last == null
                    ? 'Never checked'
                    : 'Last: ${_formatRelative(last)}',
                trailing: _checking
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
                onTap: _checking ? null : _checkNow,
              ),
            ],
          ),
          if (_statusLine != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
              child: Text(
                _statusLine!,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                ),
              ),
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 16, 24, 0),
            child: Text(
              'Updates are fetched from GitHub Releases. Installing an APK '
              'requires the system "Install unknown apps" permission for '
              'Sozo Read — Android will prompt the first time.',
              style: TextStyle(
                color: AppColors.textTertiary,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _formatRelative(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} h ago';
    return '${diff.inDays} d ago';
  }
}
