import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import '../../../core/services/image_cache_manager.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hive/hive.dart';

import '../../../core/di/injection.dart';
import '../../../core/repository/library_repository.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/state_views.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  late final LibraryRepository _repo;
  StreamSubscription<BoxEvent>? _sub;
  List<LibraryEntry> _entries = const [];

  @override
  void initState() {
    super.initState();
    _repo = sl<LibraryRepository>();
    _reload();
    _sub = _repo.watch().listen((_) {
      if (mounted) _reload();
    });
  }

  void _reload() {
    final all = _repo.getAll()
        .where((e) => e.lastChapterProgress != null)
        .toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    setState(() => _entries = all);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(title: const Text('Reading History')),
      body: _entries.isEmpty
          ? const EmptyView(
              message: 'Nothing read yet',
              icon: Icons.menu_book_rounded,
            )
          : _buildList(context),
    );
  }

  Widget _buildList(BuildContext context) {
    final now = DateTime.now();
    final groups = <String, List<LibraryEntry>>{
      'Today': [],
      'Yesterday': [],
      'This week': [],
      'This month': [],
      'Earlier': [],
    };
    for (final e in _entries) {
      groups[_bucket(e.updatedAt, now)]!.add(e);
    }

    final children = <Widget>[];
    for (final label in groups.keys) {
      final list = groups[label]!;
      if (list.isEmpty) continue;
      children.add(_SectionHeader(label));
      for (final e in list) {
        children.add(_HistoryRow(entry: e));
      }
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: children,
    );
  }

  String _bucket(DateTime t, DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    final d = DateTime(t.year, t.month, t.day);
    final diff = today.difference(d).inDays;
    if (diff <= 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    if (diff < 7) return 'This week';
    if (diff < 31) return 'This month';
    return 'Earlier';
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w700,
          fontSize: 11,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.entry});
  final LibraryEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final book = entry.book;
    final progress = (entry.lastChapterProgress ?? 0).clamp(0.0, 1.0);
    return InkWell(
      onTap: () => context.pushNamed(
        'detail',
        pathParameters: {'sourceId': book.sourceId, 'bookId': book.id},
        extra: book,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 46,
                height: 64,
                child: book.cover != null
                    ? CachedNetworkImage(
                        cacheManager: sozoCacheManagerFor(context),
                        imageUrl: book.cover!,
                        httpHeaders: book.coverHeaders,
                        fit: BoxFit.cover,
                        placeholder: (_, _) =>
                            Container(color: AppColors.card),
                        errorWidget: (_, _, _) => Container(
                          color: AppColors.card,
                          child: const Icon(
                            Icons.broken_image_outlined,
                            color: AppColors.textTertiary,
                            size: 20,
                          ),
                        ),
                      )
                    : Container(
                        color: AppColors.card,
                        child: const Icon(
                          Icons.menu_book_rounded,
                          color: AppColors.textTertiary,
                          size: 20,
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    book.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(height: 1.2),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Chapter ${entry.lastChapterIndex + 1}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      minHeight: 2.5,
                      value: progress,
                      backgroundColor:
                          theme.dividerColor.withValues(alpha: 0.6),
                      valueColor:
                          AlwaysStoppedAnimation(theme.colorScheme.primary),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
