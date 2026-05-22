import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/di/injection.dart';
import '../../core/security/app_lock_cubit.dart';
import '../../core/security/biometric_service.dart';
import '../../core/theme/app_colors.dart';

/// Full-screen lock gate painted over the router whenever
/// [AppLockState.isLocked] (or `isUnconfigured` on a fresh enable).
///
/// Hosts a 6-digit PIN pad and an optional biometric prompt button. The PIN
/// pad accepts 4-6 digits; verify fires automatically once the user types
/// enough digits (>=4) AND taps the check, OR fills all 6.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  static const int _minLen = 4;
  static const int _maxLen = 6;

  final List<int> _digits = <int>[];
  bool _busy = false;
  String? _error;
  bool _biometricAvailable = false;

  AppLockCubit get _cubit => context.read<AppLockCubit>();

  @override
  void initState() {
    super.initState();
    _resolveBiometric();
  }

  Future<void> _resolveBiometric() async {
    final ok = await sl<BiometricService>().available();
    if (!mounted) return;
    setState(() => _biometricAvailable = ok);
    // Auto-prompt on cold start when the user picked biometric mode.
    final mode = _cubit.state.mode;
    if (ok && mode == LockMode.biometric && _cubit.state.isLocked) {
      // ignore: discarded_futures
      _tryBiometric();
    }
  }

  Future<void> _tryBiometric() async {
    if (_busy) return;
    setState(() => _busy = true);
    final ok = await _cubit.unlockWithBiometric('Unlock Sozo Read');
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!ok) _error = 'Biometric cancelled — enter your PIN.';
    });
  }

  void _pushDigit(int d) {
    if (_busy) return;
    if (_digits.length >= _maxLen) return;
    HapticFeedback.selectionClick();
    setState(() {
      _error = null;
      _digits.add(d);
    });
    // Auto-submit at max length only — between min and max the user must
    // tap the confirm button (so a 4-digit PIN doesn't auto-submit on the
    // 5th tap when they meant to keep typing).
    if (_digits.length == _maxLen) {
      // ignore: discarded_futures
      _submit();
    }
  }

  void _popDigit() {
    if (_busy || _digits.isEmpty) return;
    HapticFeedback.selectionClick();
    setState(() {
      _error = null;
      _digits.removeLast();
    });
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (_digits.length < _minLen) return;
    setState(() => _busy = true);
    final pin = _digits.join();
    final ok = await _cubit.unlockWithPin(pin);
    if (!mounted) return;
    if (!ok) {
      HapticFeedback.heavyImpact();
      setState(() {
        _busy = false;
        _error = 'Incorrect PIN';
        _digits.clear();
      });
    } else {
      // Cubit emit will tear this widget down — no need to setState.
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AppLockCubit, AppLockState>(
      bloc: _cubit,
      builder: (context, state) {
        if (state.isUnconfigured) {
          return const _UnconfiguredView();
        }
        return _buildPinView(state);
      },
    );
  }

  Widget _buildPinView(AppLockState state) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            children: [
              const Spacer(),
              const Icon(
                Icons.lock_outline_rounded,
                color: AppColors.textPrimary,
                size: 48,
              ),
              const SizedBox(height: 16),
              Text(
                'Sozo Read locked',
                style: theme.textTheme.titleLarge?.copyWith(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Enter your PIN to continue',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 28),
              _PinDots(filled: _digits.length, total: _maxLen),
              const SizedBox(height: 12),
              SizedBox(
                height: 20,
                child: _error == null
                    ? null
                    : Text(
                        _error!,
                        style: const TextStyle(
                          color: AppColors.error,
                          fontSize: 13,
                        ),
                      ),
              ),
              const SizedBox(height: 16),
              _PinPad(
                onDigit: _pushDigit,
                onBackspace: _popDigit,
                onSubmit: _digits.length >= _minLen ? _submit : null,
              ),
              const SizedBox(height: 12),
              if (state.mode == LockMode.biometric && _biometricAvailable)
                TextButton.icon(
                  onPressed: _busy ? null : _tryBiometric,
                  icon: const Icon(
                    Icons.fingerprint_rounded,
                    color: AppColors.textPrimary,
                  ),
                  label: const Text(
                    'Use biometric',
                    style: TextStyle(color: AppColors.textPrimary),
                  ),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shown when the user enabled App Lock but no PIN is stored (e.g. fresh
/// install with a setting toggled in via Hive surgery). Walks them to
/// `/settings/security` to set one — meanwhile the gate is closed.
class _UnconfiguredView extends StatelessWidget {
  const _UnconfiguredView();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.lock_clock_outlined,
                  color: AppColors.warning,
                  size: 48,
                ),
                const SizedBox(height: 16),
                const Text(
                  'App Lock is on but no PIN is set',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Set a PIN to finish enabling the lock, or disable it.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.textSecondary),
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: () => context.read<AppLockCubit>().setMode(
                        LockMode.off,
                      ),
                  child: const Text('Disable App Lock'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PinDots extends StatelessWidget {
  const _PinDots({required this.filled, required this.total});
  final int filled;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < total; i++)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 6),
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: i < filled
                  ? AppColors.textPrimary
                  : AppColors.cardElevated,
              border: Border.all(
                color: i < filled
                    ? AppColors.textPrimary
                    : AppColors.divider,
                width: 1,
              ),
            ),
          ),
      ],
    );
  }
}

class _PinPad extends StatelessWidget {
  const _PinPad({
    required this.onDigit,
    required this.onBackspace,
    required this.onSubmit,
  });

  final void Function(int digit) onDigit;
  final VoidCallback onBackspace;
  final VoidCallback? onSubmit;

  @override
  Widget build(BuildContext context) {
    // 1..9 then [submit, 0, backspace] — submit only enabled when min hit.
    final rows = <List<Widget>>[
      [_DigitKey(1, onDigit), _DigitKey(2, onDigit), _DigitKey(3, onDigit)],
      [_DigitKey(4, onDigit), _DigitKey(5, onDigit), _DigitKey(6, onDigit)],
      [_DigitKey(7, onDigit), _DigitKey(8, onDigit), _DigitKey(9, onDigit)],
      [
        _ActionKey(
          icon: Icons.check_rounded,
          onPressed: onSubmit,
          tint: AppColors.primary,
        ),
        _DigitKey(0, onDigit),
        _ActionKey(
          icon: Icons.backspace_outlined,
          onPressed: onBackspace,
        ),
      ],
    ];
    return Column(
      children: [
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final cell in row)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: cell,
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _DigitKey extends StatelessWidget {
  const _DigitKey(this.digit, this.onTap);
  final int digit;
  final void Function(int) onTap;

  @override
  Widget build(BuildContext context) {
    return _KeyBase(
      onPressed: () => onTap(digit),
      child: Text(
        '$digit',
        style: const TextStyle(
          color: AppColors.textPrimary,
          fontSize: 24,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _ActionKey extends StatelessWidget {
  const _ActionKey({required this.icon, required this.onPressed, this.tint});
  final IconData icon;
  final VoidCallback? onPressed;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return _KeyBase(
      onPressed: onPressed,
      child: Icon(
        icon,
        color: enabled
            ? (tint ?? AppColors.textPrimary)
            : AppColors.textTertiary,
        size: 24,
      ),
    );
  }
}

class _KeyBase extends StatelessWidget {
  const _KeyBase({required this.onPressed, required this.child});
  final VoidCallback? onPressed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 72,
      height: 72,
      child: Material(
        color: AppColors.card,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: Center(child: child),
        ),
      ),
    );
  }
}
