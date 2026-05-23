import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/di/injection.dart';
import '../../../core/repository/summaries_repository.dart';
import '../../../core/services/ai/ai_client.dart';
import '../../../core/services/ai/ai_models.dart';
import '../../../core/state/ai_prefs_cubit.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/app_snack.dart';
import '../widgets/settings_widgets.dart';

/// `/settings/ai` — AI integration setup.
class AiSettingsScreen extends StatelessWidget {
  const AiSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider.value(
      value: sl<AiPrefsCubit>(),
      child: const _AiSettingsView(),
    );
  }
}

class _AiSettingsView extends StatefulWidget {
  const _AiSettingsView();

  @override
  State<_AiSettingsView> createState() => _AiSettingsViewState();
}

class _AiSettingsViewState extends State<_AiSettingsView> {
  final TextEditingController _keyCtrl = TextEditingController();
  bool _obscureKey = true;
  bool _testing = false;

  @override
  void dispose() {
    _keyCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveKey() async {
    final raw = _keyCtrl.text.trim();
    if (raw.isEmpty) {
      ScaffoldMessenger.of(context)
          .showAppSnackText('Paste your Gemini API key first');
      return;
    }
    final cubit = context.read<AiPrefsCubit>();
    await cubit.setApiKey(raw);
    cubit.setEnabled(true);
    if (!mounted) return;
    _keyCtrl.clear();
    ScaffoldMessenger.of(context).showAppSnackText('API key saved');
  }

  Future<void> _clearKey() async {
    final cubit = context.read<AiPrefsCubit>();
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove API key?'),
        content: const Text(
          'AI features will turn off until you save a key again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await cubit.clearApiKey();
    if (!mounted) return;
    messenger.showAppSnackText('API key removed');
  }

  Future<void> _testConnection() async {
    final cubit = context.read<AiPrefsCubit>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _testing = true);
    try {
      await sl<AiClient>().ping(model: cubit.state.model);
      if (!mounted) return;
      messenger.showAppSnackText(
        'Connected · ${cubit.state.model.displayName}',
      );
    } on AiClientException catch (e) {
      if (!mounted) return;
      messenger.showAppSnackText(e.message);
    } catch (e) {
      if (!mounted) return;
      messenger.showAppSnackText('Connection failed: $e');
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _openAiStudio() async {
    final uri = Uri.parse('https://aistudio.google.com/apikey');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _clearSummaryCache() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear summary cache?'),
        content: const Text(
          'All AI-generated chapter summaries stored on this device '
          'will be deleted. Future summaries will need to be regenerated.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await sl<SummariesRepository>().clear();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showAppSnackText('Summary cache cleared');
  }

  Future<void> _openModelPicker(AiModel current) async {
    final cubit = context.read<AiPrefsCubit>();
    final picked = await showModalBottomSheet<AiModel>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 16, 8, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Pick a model',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                for (final m in AiModel.values)
                  ListTile(
                    title: Text(m.displayName),
                    subtitle: Text(m.tierLabel),
                    trailing: m == current
                        ? const Icon(Icons.check_rounded,
                            color: AppColors.primary)
                        : null,
                    onTap: () => Navigator.pop(ctx, m),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
    if (picked != null) cubit.setModel(picked);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI integration'),
        centerTitle: true,
      ),
      body: BlocBuilder<AiPrefsCubit, AiPrefs>(
        builder: (context, prefs) {
          final cubit = context.read<AiPrefsCubit>();
          return ListView(
            padding: const EdgeInsets.only(top: 4, bottom: 24),
            children: [
              const _AiHeaderCard(),
              SettingsCard(
                children: [
                  SwitchListTile.adaptive(
                    secondary: const Icon(
                      Icons.auto_awesome_outlined,
                      color: AppColors.textSecondary,
                    ),
                    title: const Text('Enable AI features'),
                    subtitle: Text(
                      prefs.apiKeyPresent
                          ? (prefs.enabled ? 'On' : 'Off')
                          : 'Add an API key first',
                    ),
                    value: prefs.enabled && prefs.apiKeyPresent,
                    onChanged: prefs.apiKeyPresent
                        ? (v) => cubit.setEnabled(v)
                        : null,
                  ),
                ],
              ),
              const SettingsSectionLabel('API key'),
              SettingsCard(
                children: [
                  // When a key is saved, show the masked tail so the
                  // user can confirm "yes, my key is there" — common
                  // dashboard convention (Stripe, OpenAI, Google all
                  // do this). The last 4 chars are not sensitive on
                  // their own.
                  if (prefs.apiKeyPresent) const _SavedKeyRow(),
                  Padding(
                    padding:
                        const EdgeInsets.fromLTRB(16, 14, 16, 8),
                    child: TextField(
                      controller: _keyCtrl,
                      obscureText: _obscureKey,
                      autocorrect: false,
                      enableSuggestions: false,
                      keyboardType: TextInputType.visiblePassword,
                      decoration: InputDecoration(
                        labelText: prefs.apiKeyPresent
                            ? 'Replace key'
                            : 'Paste your Gemini API key',
                        hintText: 'AIza...',
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          icon: Icon(_obscureKey
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined),
                          onPressed: () => setState(
                              () => _obscureKey = !_obscureKey),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding:
                        const EdgeInsets.fromLTRB(16, 0, 16, 14),
                    child: Row(
                      children: [
                        Expanded(
                          child: FilledButton(
                            onPressed: _saveKey,
                            child: const Text('Save'),
                          ),
                        ),
                        if (prefs.apiKeyPresent) ...[
                          const SizedBox(width: 8),
                          OutlinedButton(
                            onPressed: _clearKey,
                            child: const Text('Remove'),
                          ),
                        ],
                      ],
                    ),
                  ),
                  SettingsTile(
                    icon: Icons.open_in_new_rounded,
                    title: 'Get a free API key',
                    subtitle: 'aistudio.google.com/apikey',
                    onTap: _openAiStudio,
                  ),
                ],
              ),
              const SettingsSectionLabel('Model'),
              SettingsCard(
                children: [
                  SettingsTile(
                    icon: Icons.psychology_outlined,
                    title: 'Model',
                    subtitle:
                        '${prefs.model.displayName} · ${prefs.model.tierLabel}',
                    onTap: () => _openModelPicker(prefs.model),
                  ),
                  SettingsTile(
                    icon: _testing
                        ? Icons.hourglass_top_rounded
                        : Icons.wifi_tethering_rounded,
                    title: 'Test connection',
                    subtitle: prefs.apiKeyPresent
                        ? 'Verify the key works'
                        : 'Add a key first',
                    onTap: prefs.apiKeyPresent && !_testing
                        ? _testConnection
                        : null,
                  ),
                ],
              ),
              const SettingsSectionLabel('Cache'),
              SettingsCard(
                children: [
                  SettingsTile(
                    icon: Icons.delete_sweep_outlined,
                    title: 'Clear summary cache',
                    subtitle:
                        'Forget all AI-generated chapter summaries',
                    onTap: _clearSummaryCache,
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Confirmation row shown above the paste field when a key is saved.
/// Reads the actual key from secure storage on demand and renders it
/// masked (`••••••••••••ab12`) so the user can tell at a glance which
/// key is active — useful when you maintain multiple Gemini projects.
class _SavedKeyRow extends StatelessWidget {
  const _SavedKeyRow();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String?>(
      future: context.read<AiPrefsCubit>().readApiKey(),
      builder: (_, snap) {
        if (!snap.hasData) {
          return const Padding(
            padding: EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Row(
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
            ),
          );
        }
        final key = snap.data ?? '';
        final masked = _mask(key);
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
          child: Row(
            children: [
              const Icon(
                Icons.check_circle_rounded,
                size: 18,
                color: AppColors.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Saved',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      masked,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                        fontFamily: 'monospace',
                        letterSpacing: 1,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Renders the last 4 chars in clear text and masks the rest with
  /// bullet characters. Caps the displayed width so long keys don't
  /// wrap into multiple lines.
  String _mask(String key) {
    if (key.isEmpty) return '';
    if (key.length <= 4) return '•' * key.length;
    final tail = key.substring(key.length - 4);
    // 12 bullets is enough to read as "long opaque key" without
    // accidentally giving away the actual character count.
    return '${'•' * 12}$tail';
  }
}

/// Soft-tinted intro card. Mirrors the visual weight of
/// `_TrackersHeaderCard` so the AI screen feels part of the same
/// settings family — same border radius, same accent alpha, same
/// padding rhythm.
class _AiHeaderCard extends StatelessWidget {
  const _AiHeaderCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.color;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppColors.primary.withValues(alpha: 0.22),
          width: 0.6,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.auto_awesome_rounded,
            color: AppColors.primary,
            size: 22,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Plug in your Gemini API key to unlock AI-powered reader '
              'features. The key is stored encrypted on this device and '
              "is only sent to Google's API.",
              style: TextStyle(
                color: muted,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
