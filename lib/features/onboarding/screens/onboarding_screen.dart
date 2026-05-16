import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hive/hive.dart';

import '../../../core/di/injection.dart';
import '../../../core/repository/provider_repository.dart';
import '../../../core/state/active_source_cubit.dart';
import '../../../core/theme/app_colors.dart';

/// Single-screen first-run experience: pick a source, mark onboarded,
/// then route to /home.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  String? _selected;

  @override
  Widget build(BuildContext context) {
    final providers = sl<ProviderRepository>().providers;
    final sourceIds = providers.map((p) => p.sourceId).toList();
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Brand — mirrors home_screen's SOZO-READ wordmark.
              RichText(
                text: TextSpan(
                  style: const TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.4,
                    height: 1,
                  ),
                  children: [
                    TextSpan(
                      text: 'SOZO',
                      style: TextStyle(color: theme.colorScheme.primary),
                    ),
                    TextSpan(
                      text: '-',
                      style: TextStyle(
                        color: theme.textTheme.bodySmall?.color ??
                            AppColors.textTertiary,
                      ),
                    ),
                    TextSpan(
                      text: 'READ',
                      style: TextStyle(
                        color: theme.textTheme.bodyLarge?.color ??
                            AppColors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Manga & novels in one place.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.textTheme.bodySmall?.color,
                ),
              ),
              const SizedBox(height: 40),
              Text(
                'Choose your source',
                style: theme.textTheme.headlineSmall,
              ),
              const SizedBox(height: 4),
              Text(
                'You can change this anytime in Settings.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 18),
              Expanded(
                child: sourceIds.isEmpty
                    ? _EmptyState(onSkip: _skip)
                    : ListView.separated(
                        itemCount: sourceIds.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (_, i) {
                          final id = sourceIds[i];
                          final selected = id == _selected;
                          return _SourceCard(
                            sourceId: id,
                            selected: selected,
                            onTap: () => setState(() => _selected = id),
                          );
                        },
                      ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _selected == null ? null : _finish,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text(
                    'Get Started',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _finish() {
    final id = _selected;
    if (id == null) return;
    Hive.box('settings').put('onboarded', true);
    sl<ActiveSourceCubit>().setActive(id);
    if (!mounted) return;
    context.go('/home');
  }

  void _skip() {
    Hive.box('settings').put('onboarded', true);
    if (!mounted) return;
    context.go('/home');
  }
}

class _SourceCard extends StatelessWidget {
  const _SourceCard({
    required this.sourceId,
    required this.selected,
    required this.onTap,
  });

  final String sourceId;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    return Material(
      color: theme.cardTheme.color ?? theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? accent : Colors.transparent,
              width: 1.4,
            ),
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: accent.withValues(alpha: 0.15),
                child: Text(
                  sourceId.isNotEmpty ? sourceId[0].toUpperCase() : '?',
                  style: TextStyle(
                    color: accent,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  sourceId,
                  style: theme.textTheme.titleMedium?.copyWith(fontSize: 15),
                ),
              ),
              if (selected)
                Icon(Icons.check_circle_rounded, color: accent, size: 22)
              else
                Icon(
                  Icons.radio_button_unchecked,
                  color: theme.textTheme.bodySmall?.color,
                  size: 22,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onSkip});
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.extension_off_rounded,
              size: 48, color: theme.textTheme.bodySmall?.color),
          const SizedBox(height: 12),
          Text('No providers installed', style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            'You can install providers from Settings.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 18),
          TextButton(onPressed: onSkip, child: const Text('Skip for now')),
        ],
      ),
    );
  }
}
