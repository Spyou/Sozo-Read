import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hive/hive.dart';

import '../../../core/di/injection.dart';
import '../../../core/state/active_source_cubit.dart';
import '../../../core/theme/app_colors.dart';
import '../../home/bloc/home_bloc.dart';
import '../../home/bloc/home_event.dart';

/// Animated splash. Plays for ~1.6s after the native splash ends, then routes
/// the user to /onboarding (first run) or /home.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  // Curves for the staged animation.
  late final Animation<double> _logoScale;   // 0.6 → 1.0 elastic
  late final Animation<double> _logoOpacity; // 0 → 1
  late final Animation<double> _sozoSlide;   // 12 → 0 px, with fade
  late final Animation<double> _sozoOpacity;
  late final Animation<double> _readSlide;
  late final Animation<double> _readOpacity;
  late final Animation<double> _underline;   // 0 → 1 width fraction
  late final Animation<double> _exitFade;    // 0 → 1 at the very end

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );

    _logoOpacity = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.0, 0.25, curve: Curves.easeOut),
    );
    _logoScale = Tween(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: const Interval(0.0, 0.40, curve: Curves.elasticOut),
      ),
    );

    _sozoOpacity = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.25, 0.50, curve: Curves.easeOut),
    );
    _sozoSlide = Tween(begin: 12.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: const Interval(0.25, 0.50, curve: Curves.easeOut),
      ),
    );
    _readOpacity = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.35, 0.60, curve: Curves.easeOut),
    );
    _readSlide = Tween(begin: 12.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: const Interval(0.35, 0.60, curve: Curves.easeOut),
      ),
    );

    _underline = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.55, 0.78, curve: Curves.easeOutCubic),
    );

    _exitFade = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.88, 1.0, curve: Curves.easeIn),
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
    return Scaffold(
      backgroundColor: AppColors.background,
      body: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) {
          return Opacity(
            opacity: 1 - _exitFade.value,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Logo image
                  Opacity(
                    opacity: _logoOpacity.value,
                    child: Transform.scale(
                      scale: _logoScale.value,
                      child: Container(
                        width: 132,
                        height: 132,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(28),
                          boxShadow: [
                            BoxShadow(
                              color: accent.withValues(alpha: 0.32),
                              blurRadius: 48,
                              spreadRadius: -8,
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(28),
                          child: Image.asset(
                            // Force the default red logo; icon-variant feature
                            // is currently disabled in Settings.
                            'assets/branding/sozo_logo_red.png',
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 22),
                  // Wordmark
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Transform.translate(
                        offset: Offset(0, _sozoSlide.value),
                        child: Opacity(
                          opacity: _sozoOpacity.value,
                          child: Text(
                            'SOZO',
                            style: TextStyle(
                              color: accent,
                              fontSize: 26,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 1.6,
                              height: 1,
                            ),
                          ),
                        ),
                      ),
                      Opacity(
                        opacity: (_sozoOpacity.value + _readOpacity.value) / 2,
                        child: Text(
                          '-',
                          style: TextStyle(
                            color: AppColors.textTertiary,
                            fontSize: 26,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1.6,
                            height: 1,
                          ),
                        ),
                      ),
                      Transform.translate(
                        offset: Offset(0, _readSlide.value),
                        child: Opacity(
                          opacity: _readOpacity.value,
                          child: const Text(
                            'READ',
                            style: TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 26,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 1.6,
                              height: 1,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  // Animated underline
                  SizedBox(
                    width: 140,
                    height: 2,
                    child: Align(
                      alignment: Alignment.center,
                      child: FractionallySizedBox(
                        widthFactor: _underline.value,
                        child: Container(
                          decoration: BoxDecoration(
                            color: accent,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
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
