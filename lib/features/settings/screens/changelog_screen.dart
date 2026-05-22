import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../../../core/di/injection.dart';
import '../../../core/models/github_release.dart';
import '../../../core/services/changelog_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/state_views.dart' show EmptyView, ErrorView, LoadingView;

/// `/settings/changelog` — full history of GitHub release notes for
/// the app's own repo. Pull-to-refresh forces a network refetch even
/// when the 24h cache is still warm.
class ChangelogScreen extends StatefulWidget {
  const ChangelogScreen({super.key});

  @override
  State<ChangelogScreen> createState() => _ChangelogScreenState();
}

class _ChangelogScreenState extends State<ChangelogScreen> {
  late Future<List<GitHubRelease>> _future;

  @override
  void initState() {
    super.initState();
    _future = sl<ChangelogService>().all();
  }

  Future<void> _refresh() async {
    setState(() {
      _future = sl<ChangelogService>().all(forceRefresh: true);
    });
    await _future;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Release notes'),
        centerTitle: true,
      ),
      body: FutureBuilder<List<GitHubRelease>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const LoadingView();
          }
          if (snap.hasError) {
            return ErrorView(
              message: 'Could not load release notes.',
              onRetry: _refresh,
            );
          }
          final releases = snap.data ?? const [];
          if (releases.isEmpty) {
            return const EmptyView(
              icon: Icons.history_rounded,
              message: 'No release notes available yet.',
            );
          }
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              itemCount: releases.length,
              separatorBuilder: (_, _) =>
                  const Divider(color: AppColors.divider, height: 32),
              itemBuilder: (_, i) => _ReleaseCard(release: releases[i]),
            ),
          );
        },
      ),
    );
  }
}

class _ReleaseCard extends StatelessWidget {
  const _ReleaseCard({required this.release});
  final GitHubRelease release;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                release.tagName,
                style: const TextStyle(
                  color: AppColors.primary,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _formatDate(release.publishedAt),
                style: const TextStyle(
                  color: AppColors.textTertiary,
                  fontSize: 12,
                ),
              ),
            ),
            if (release.prerelease)
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.warning.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  'beta',
                  style: TextStyle(
                    color: AppColors.warning,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        MarkdownBody(
          data: release.body.isEmpty
              ? '_No release notes provided._'
              : release.body,
          selectable: true,
          styleSheet: MarkdownStyleSheet(
            p: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 14,
              height: 1.4,
            ),
            h1: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 17,
              fontWeight: FontWeight.w800,
            ),
            h2: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
            h3: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
            code: TextStyle(
              backgroundColor: AppColors.card.withValues(alpha: 0.6),
              color: AppColors.textPrimary,
              fontFamily: 'monospace',
              fontSize: 13,
            ),
          ),
        ),
      ],
    );
  }

  static String _formatDate(DateTime dt) {
    final local = dt.toLocal();
    final months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[local.month - 1]} ${local.day}, ${local.year}';
  }
}
