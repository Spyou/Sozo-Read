import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hive/hive.dart';

import '../../../core/di/injection.dart';
import '../../../core/state/active_source_cubit.dart';
import '../../../core/theme/app_colors.dart';
import '../../home/bloc/home_bloc.dart';
import '../../home/bloc/home_event.dart';

/// Netflix-style text splash. "S" pops in, "OZO" sweeps out to its right,
/// then " READ" sweeps further right — everything centered. Plays for 2.5s
/// (excluding the OS-level native splash phase), then routes the user to
/// `/onboarding` (first run) or `/home`.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  // Snappy ease curve used for the scale + sweep reveals. Matches the
  // reference's Cubic(0.19, 1.0, 0.22, 1.0) — an aggressive ease-out-quint.
  static const _snappy = Cubic(0.19, 1.0, 0.22, 1.0);

  late final Animation<double> _sScale;       // 0.04 → 1.0
  late final Animation<double> _sOpacity;     // 0 → 1
  late final Animation<double> _ozoWidth;     // 0 → 1 (ClipRect widthFactor)
  late final Animation<double> _ozoOpacity;
  late final Animation<double> _readWidth;    // 0 → 1
  late final Animation<double> _readOpacity;
  late final Animation<double> _fadeOut;      // 1 → 0 at end

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2500),
    );

    // S: scales from microscopic to full size, fading in faster than it grows.
    _sOpacity = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.00, 0.10, curve: Curves.easeIn),
    );
    _sScale = Tween<double>(begin: 0.04, end: 1.0).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: const Interval(0.00, 0.32, curve: _snappy),
      ),
    );

    // OZO: sweeps out to the right of S via ClipRect width factor.
    _ozoOpacity = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.28, 0.40, curve: Curves.easeIn),
    );
    _ozoWidth = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: const Interval(0.28, 0.56, curve: _snappy),
      ),
    );

    // READ: sweeps out further right after a brief beat.
    _readOpacity = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.56, 0.68, curve: Curves.easeIn),
    );
    _readWidth = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: const Interval(0.56, 0.84, curve: _snappy),
      ),
    );

    // Hold the full word for ~150ms, then fade everything to black.
    _fadeOut = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: const Interval(0.90, 1.00, curve: Curves.easeIn),
      ),
    );

    _warmHome();
    _ctrl.forward().whenComplete(_goNext);
  }

  /// Kicks the singleton HomeBloc into loading immediately so its sections
  /// stream in while the splash animation is playing. By the time we route
  /// to /home the data is usually already there — no second spinner.
  void _warmHome() {
    final onboarded = Hive.box('settings').get('onboarded') == true;
    if (!onboarded) return; // first-run: no active source yet
    final activeCubit = sl<ActiveSourceCubit>();
    activeCubit.initializeIfNeeded();
    final src = activeCubit.state;
    if (src == null) return;
    final bloc = sl<HomeBloc>();
    // Idempotent: HomeSourceChanged short-circuits when the source matches and
    // sections are already loaded.
    bloc.add(HomeSourceChanged(src));
  }

  void _goNext() {
    if (!mounted) return;
    // If a cold-start deep link already navigated us off /splash while the
    // splash animation was running, don't clobber that destination. This
    // is the difference between landing on /home and landing on the
    // requested /manga/... or /login-callback page.
    final current = GoRouterState.of(context).matchedLocation;
    if (current != '/splash') return;
    final onboarded = Hive.box('settings').get('onboarded') == true;
    context.go(onboarded ? '/home' : '/onboarding');
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    // Scale the text down on narrow phones so "SOZO READ" never clips.
    final screenW = MediaQuery.of(context).size.width;
    final fontSize = (screenW * 0.14).clamp(42.0, 72.0);
    final textStyle = TextStyle(
      color: accent,
      fontSize: fontSize,
      fontWeight: FontWeight.w900,
      letterSpacing: -3.0,
      height: 1.0,
    );

    return Scaffold(
      backgroundColor: AppColors.background,
      body: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) {
          return Opacity(
            opacity: _fadeOut.value,
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // S — scales from a dot to full size.
                  Opacity(
                    opacity: _sOpacity.value,
                    child: Transform.scale(
                      scale: _sScale.value,
                      alignment: Alignment.center,
                      child: Text('S', style: textStyle),
                    ),
                  ),
                  // OZO — width-clipped reveal left-to-right.
                  ClipRect(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      widthFactor: _ozoWidth.value,
                      child: Opacity(
                        opacity: _ozoOpacity.value,
                        child: Text('OZO', style: textStyle),
                      ),
                    ),
                  ),
                  // " READ" — leading space gives a visible gap between SOZO
                  // and READ once both are revealed. Same sweep treatment.
                  ClipRect(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      widthFactor: _readWidth.value,
                      child: Opacity(
                        opacity: _readOpacity.value,
                        child: Text('  READ', style: textStyle),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
