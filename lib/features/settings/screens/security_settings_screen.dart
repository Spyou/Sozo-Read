import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/di/injection.dart';
import '../../../core/security/app_lock_cubit.dart';
import '../../../core/security/biometric_service.dart';
import '../../../core/security/pin_storage.dart';
import '../../../core/services/image_cache_manager.dart';
import '../../../core/state/incognito_cubit.dart';
import '../../../core/theme/app_colors.dart';
import '../widgets/settings_widgets.dart';

/// `/settings/security`. Configures App Lock mode (off / PIN / biometric),
/// inactivity timeout, FLAG_SECURE toggle, and the Set/Change/Remove PIN
/// flow.
class SecuritySettingsScreen extends StatelessWidget {
  const SecuritySettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider.value(
      value: sl<AppLockCubit>(),
      child: const _SecuritySettingsView(),
    );
  }
}

class _SecuritySettingsView extends StatefulWidget {
  const _SecuritySettingsView();

  @override
  State<_SecuritySettingsView> createState() => _SecuritySettingsViewState();
}

class _SecuritySettingsViewState extends State<_SecuritySettingsView> {
  bool _biometricAvailable = false;

  @override
  void initState() {
    super.initState();
    // ignore: discarded_futures
    _resolveBiometric();
  }

  Future<void> _resolveBiometric() async {
    final ok = await sl<BiometricService>().available();
    if (!mounted) return;
    setState(() => _biometricAvailable = ok);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Security'), centerTitle: true),
      body: BlocBuilder<AppLockCubit, AppLockState>(
        builder: (context, state) {
          final hasPinFuture = sl<PinStorage>().hasPin();
          return ListView(
            padding: const EdgeInsets.only(top: 4, bottom: 24),
            children: [
              SettingsCard(
                children: [
                  SettingsTile(
                    icon: Icons.lock_outline_rounded,
                    title: 'Lock mode',
                    subtitle: AppLockCubit.modeLabel(state.mode),
                    onTap: () => _openModeSheet(state),
                  ),
                  SettingsTile(
                    icon: Icons.timer_outlined,
                    title: 'Auto-lock',
                    subtitle: AppLockCubit.timeoutLabel(state.timeout),
                    onTap: state.mode == LockMode.off
                        ? null
                        : () => _openTimeoutSheet(state),
                  ),
                ],
              ),
              FutureBuilder<bool>(
                future: hasPinFuture,
                builder: (context, snap) {
                  final hasPin = snap.data ?? false;
                  return SettingsCard(
                    children: [
                      SettingsTile(
                        icon: Icons.pin_outlined,
                        title: hasPin ? 'Change PIN' : 'Set PIN',
                        onTap: () => _openSetPinFlow(),
                      ),
                      if (hasPin)
                        SettingsTile(
                          icon: Icons.lock_open_outlined,
                          title: 'Remove PIN',
                          destructive: true,
                          onTap: _confirmRemovePin,
                        ),
                    ],
                  );
                },
              ),
              SettingsCard(
                children: [
                  _HideAppPreviewRow(
                    on: state.flagSecure,
                    onToggle: () => context
                        .read<AppLockCubit>()
                        .setFlagSecure(!state.flagSecure),
                  ),
                  // Incognito belongs in the Security/Privacy screen
                  // (it's a privacy feature) — kept out of the top-level
                  // Settings list to avoid duplicating the toggle in two
                  // places.
                  const _IncognitoRow(),
                ],
              ),
              if (!_biometricAvailable && state.mode == LockMode.biometric)
                const Padding(
                  padding: EdgeInsets.fromLTRB(24, 0, 24, 12),
                  child: Text(
                    'Biometric is unavailable on this device — PIN will be '
                    'used as the fallback.',
                    style: TextStyle(
                      color: AppColors.warning,
                      fontSize: 12,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  void _openModeSheet(AppLockState state) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) {
        return SettingsSheetShell(
          title: 'Lock mode',
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final m in LockMode.values)
                ListTile(
                  title: Text(AppLockCubit.modeLabel(m)),
                  trailing: m == state.mode
                      ? const Icon(Icons.check, color: AppColors.primary)
                      : null,
                  onTap: () async {
                    Navigator.of(sheetCtx).pop();
                    // Picking PIN or biometric without a stored PIN drops
                    // the user into the set-PIN flow before flipping mode.
                    if (m != LockMode.off) {
                      final hasPin = await sl<PinStorage>().hasPin();
                      if (!hasPin) {
                        if (!mounted) return;
                        await _openSetPinFlow(pendingMode: m);
                        return;
                      }
                    }
                    if (!mounted) return;
                    await context.read<AppLockCubit>().setMode(m);
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  void _openTimeoutSheet(AppLockState state) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) {
        return SettingsSheetShell(
          title: 'Auto-lock',
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final t in LockTimeout.values)
                ListTile(
                  title: Text(AppLockCubit.timeoutLabel(t)),
                  trailing: t == state.timeout
                      ? const Icon(Icons.check, color: AppColors.primary)
                      : null,
                  onTap: () {
                    Navigator.of(sheetCtx).pop();
                    context.read<AppLockCubit>().setTimeout(t);
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  /// Two-step PIN entry: pick a PIN, then re-enter to confirm. On success
  /// hands off to [AppLockCubit.setPin] and flips mode to [pendingMode]
  /// if the caller is mid mode-swap.
  Future<void> _openSetPinFlow({LockMode? pendingMode}) async {
    final first = await _promptPin(title: 'Set PIN');
    if (first == null || first.isEmpty) return;
    if (!mounted) return;
    final second = await _promptPin(title: 'Confirm PIN');
    if (second == null) return;
    if (first != second) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("PINs don't match — try again.")),
      );
      return;
    }
    if (!mounted) return;
    final cubit = context.read<AppLockCubit>();
    await cubit.setPin(first);
    if (pendingMode != null) {
      await cubit.setMode(pendingMode);
    }
    if (!mounted) return;
    setState(() {});
  }

  Future<String?> _promptPin({required String title}) {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => _PinEntryDialog(title: title),
    );
  }

  Future<void> _confirmRemovePin() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Remove PIN?'),
        content: const Text(
          'This will also disable App Lock until you set a new PIN.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            child: const Text(
              'Remove',
              style: TextStyle(color: AppColors.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;
    await context.read<AppLockCubit>().removePin();
    if (!mounted) return;
    setState(() {});
  }
}

/// Modal text-field dialog for capturing a 4-6 digit PIN. Kept inline in
/// the security screen — there's no other consumer.
class _PinEntryDialog extends StatefulWidget {
  const _PinEntryDialog({required this.title});
  final String title;

  @override
  State<_PinEntryDialog> createState() => _PinEntryDialogState();
}

class _PinEntryDialogState extends State<_PinEntryDialog> {
  final TextEditingController _ctrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _ctrl.text.trim();
    if (value.length < 4 || value.length > 6) {
      setState(() => _error = 'PIN must be 4 to 6 digits.');
      return;
    }
    if (!RegExp(r'^\d+$').hasMatch(value)) {
      setState(() => _error = 'Digits only.');
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        obscureText: true,
        keyboardType: TextInputType.number,
        maxLength: 6,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(
          hintText: '4 to 6 digits',
          errorText: _error,
          counterText: '',
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _submit,
          child: const Text('OK'),
        ),
      ],
    );
  }
}

/// FLAG_SECURE toggle (hide app preview in the task switcher + block
/// screenshots). Stacked title/subtitle layout — SettingsTile renders
/// them side-by-side, which squeezes the title to invisibility when
/// the subtitle is long.
class _HideAppPreviewRow extends StatelessWidget {
  const _HideAppPreviewRow({required this.on, required this.onToggle});
  final bool on;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.color;
    return InkWell(
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(
              Icons.no_photography_outlined,
              color: on ? AppColors.primary : muted,
              size: 22,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Hide app preview',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Blank task-switcher + block screenshots',
                    style: TextStyle(
                      color: muted,
                      fontSize: 12,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Switch.adaptive(
              value: on,
              activeThumbColor: AppColors.primary,
              onChanged: (_) => onToggle(),
            ),
          ],
        ),
      ),
    );
  }
}

/// Session-only Incognito toggle nested inside the Security screen.
/// Stacked title-above-subtitle layout so neither gets squeezed by the
/// trailing Switch.
class _IncognitoRow extends StatelessWidget {
  const _IncognitoRow();

  @override
  Widget build(BuildContext context) {
    final on = context.watch<IncognitoCubit>().state;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.color;
    return InkWell(
      onTap: () => _toggle(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(
              on
                  ? Icons.visibility_off_rounded
                  : Icons.visibility_off_outlined,
              color: on ? AppColors.primary : muted,
              size: 22,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Incognito',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    on
                        ? 'On — not saving history or caching covers'
                        : "Don't save history or cache covers this session",
                    style: TextStyle(
                      color: muted,
                      fontSize: 12,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Switch.adaptive(
              value: on,
              activeThumbColor: AppColors.primary,
              onChanged: (_) => _toggle(context),
            ),
          ],
        ),
      ),
    );
  }

  void _toggle(BuildContext context) {
    context.read<IncognitoCubit>().toggle();
    // Purge any cover snippets the throwaway cache picked up before
    // the toggle so neither direction leaks artefacts.
    // ignore: discarded_futures
    appMemoryOnlyImageCacheManager.purge();
  }
}
