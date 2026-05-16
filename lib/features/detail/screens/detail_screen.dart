import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/di/injection.dart';
import '../../../core/models/book_detail.dart';
import '../../../core/models/book_item.dart';
import '../../../core/models/chapter.dart';
import '../../../core/repository/library_repository.dart';
import '../../../core/repository/provider_repository.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/state_views.dart';
import '../bloc/detail_bloc.dart';
import '../bloc/detail_event.dart';
import '../bloc/detail_state.dart';

class DetailScreen extends StatelessWidget {
  const DetailScreen({super.key, required this.sourceId, required this.url, this.placeholder});

  final String sourceId;
  final String url;
  final BookItem? placeholder;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => DetailBloc(
        providerRepo: sl<ProviderRepository>(),
        libraryRepo: sl<LibraryRepository>(),
      )..add(DetailLoaded(sourceId: sourceId, url: url)),
      child: _DetailView(placeholder: placeholder),
    );
  }
}

class _DetailView extends StatelessWidget {
  const _DetailView({this.placeholder});
  final BookItem? placeholder;

  void _openReader(BuildContext context, BookDetail book, int chapterIndex) {
    final isManga = book.type.name != 'novel';
    context.pushNamed(
      isManga ? 'manga-reader' : 'novel-reader',
      pathParameters: {'sourceId': book.sourceId, 'bookId': book.id},
      extra: {
        'book': book,
        'chapterIndex': chapterIndex,
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: BlocBuilder<DetailBloc, DetailState>(
        builder: (context, state) {
          if (state.status == DetailStatus.loading && state.book == null) {
            return _SkeletonDetail(placeholder: placeholder);
          }
          if (state.status == DetailStatus.error && state.book == null) {
            return ErrorView(
              message: state.error ?? 'Failed to load',
              onRetry: () => context.read<DetailBloc>().add(const DetailReloaded()),
            );
          }
          final book = state.book;
          if (book == null) return const LoadingView();
          return _DetailBody(
            book: book,
            inLibrary: state.inLibrary,
            lastChapterIndex: state.library?.lastChapterIndex ?? 0,
            onToggleLibrary: () => context.read<DetailBloc>().add(const DetailLibraryToggled()),
            onOpenChapter: (i) => _openReader(context, book, i),
          );
        },
      ),
    );
  }
}

class _DetailBody extends StatelessWidget {
  const _DetailBody({
    required this.book,
    required this.inLibrary,
    required this.lastChapterIndex,
    required this.onToggleLibrary,
    required this.onOpenChapter,
  });

  final BookDetail book;
  final bool inLibrary;
  final int lastChapterIndex;
  final VoidCallback onToggleLibrary;
  final void Function(int chapterIndex) onOpenChapter;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        SliverAppBar(
          expandedHeight: 340,
          pinned: true,
          backgroundColor: AppColors.background,
          flexibleSpace: FlexibleSpaceBar(
            background: _BackdropHeader(book: book),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(book.title, style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _StatusBadge(status: book.status),
                    const SizedBox(width: 8),
                    Text(book.sourceId,
                        style: const TextStyle(color: AppColors.textTertiary, fontSize: 12)),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.play_arrow),
                        label: Text(lastChapterIndex > 0 && lastChapterIndex < book.chapters.length
                            ? 'Continue'
                            : 'Read'),
                        onPressed: book.chapters.isEmpty
                            ? null
                            : () => onOpenChapter(
                                  lastChapterIndex.clamp(0, book.chapters.length - 1),
                                ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    IconButton.filledTonal(
                      onPressed: onToggleLibrary,
                      icon: Icon(inLibrary ? Icons.bookmark : Icons.bookmark_outline),
                    ),
                  ],
                ),
                if (book.description != null && book.description!.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Text(book.description!,
                      maxLines: 6,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium),
                ],
                if (book.genres.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: book.genres
                        .map((g) => Chip(label: Text(g),
                            visualDensity: VisualDensity.compact, padding: EdgeInsets.zero))
                        .toList(),
                  ),
                ],
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Chapters', style: Theme.of(context).textTheme.headlineSmall),
                    Text('${book.chapters.length}',
                        style: const TextStyle(color: AppColors.textTertiary)),
                  ],
                ),
                const SizedBox(height: 4),
              ],
            ),
          ),
        ),
        SliverList.separated(
          itemCount: book.chapters.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (_, i) {
            final Chapter ch = book.chapters[i];
            final read = i < lastChapterIndex;
            return ListTile(
              dense: true,
              onTap: () => onOpenChapter(i),
              title: Text(
                ch.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: read ? AppColors.textTertiary : AppColors.textPrimary,
                  fontWeight: i == lastChapterIndex ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
              subtitle: ch.date != null
                  ? Text(ch.date!, style: const TextStyle(color: AppColors.textTertiary, fontSize: 11))
                  : null,
              trailing: i == lastChapterIndex
                  ? const Icon(Icons.play_circle, color: AppColors.primary, size: 20)
                  : null,
            );
          },
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 32)),
      ],
    );
  }
}

class _BackdropHeader extends StatelessWidget {
  const _BackdropHeader({required this.book});
  final BookDetail book;

  @override
  Widget build(BuildContext context) {
    final cover = book.cover;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (cover != null)
          CachedNetworkImage(
            imageUrl: cover,
            httpHeaders: book.coverHeaders,
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
          )
        else
          Container(color: AppColors.card),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0x00000000),
                Color(0x44000000),
                Color(0xCC0A0A0A),
                AppColors.background,
              ],
              stops: [0.0, 0.45, 0.8, 1.0],
            ),
          ),
        ),
        Positioned(
          bottom: 24,
          left: 20,
          child: SizedBox(
            height: 160,
            child: AspectRatio(
              aspectRatio: 2 / 3,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: cover != null
                    ? CachedNetworkImage(imageUrl: cover, httpHeaders: book.coverHeaders, fit: BoxFit.cover)
                    : Container(color: AppColors.card),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});
  final BookStatus status;
  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      BookStatus.ongoing => AppColors.success,
      BookStatus.completed => AppColors.primary,
      BookStatus.hiatus => AppColors.warning,
      BookStatus.cancelled => AppColors.textTertiary,
      BookStatus.unknown => AppColors.textTertiary,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        status.name.toUpperCase(),
        style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.8),
      ),
    );
  }
}

class _SkeletonDetail extends StatelessWidget {
  const _SkeletonDetail({this.placeholder});
  final BookItem? placeholder;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SizedBox(
          height: 340,
          child: placeholder?.cover != null
              ? Stack(
                  fit: StackFit.expand,
                  children: [
                    CachedNetworkImage(
                      imageUrl: placeholder!.cover!,
                      httpHeaders: placeholder!.coverHeaders,
                      fit: BoxFit.cover,
                    ),
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0x66000000), AppColors.background],
                          stops: [0.5, 1.0],
                        ),
                      ),
                    ),
                  ],
                )
              : Container(color: AppColors.card),
        ),
        const Expanded(child: LoadingView()),
      ],
    );
  }
}
