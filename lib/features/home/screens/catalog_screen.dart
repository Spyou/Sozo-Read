import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/di/injection.dart';
import '../../../core/models/book_item.dart';
import '../../../core/repository/provider_repository.dart';
import '../../../core/state/active_source_cubit.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/book_card.dart';
import '../widgets/book_card_action_sheet.dart';

/// Full-screen paginated catalog for a single home section
/// (`popular` / `latest` / `trending`).
///
/// Reached from a "See all" tap on a SectionRow header. Calls the active
/// provider's `search('', page, category: sectionId)` — the same call the
/// home BLoC uses, just paginated. Providers that don't honor the
/// category fall back to their default catalog (latest), which is fine.
class CatalogScreen extends StatefulWidget {
  const CatalogScreen({
    super.key,
    required this.sectionId,
    required this.title,
  });

  final String sectionId;
  final String title;

  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen> {
  final _repo = sl<ProviderRepository>();
  final _scroll = ScrollController();
  final _seen = <String>{};

  final List<BookItem> _items = [];
  int _page = 1;
  bool _loading = false;
  bool _done = false;
  String? _error;
  String? _sourceId;

  @override
  void initState() {
    super.initState();
    _sourceId = sl<ActiveSourceCubit>().activeSourceId;
    _scroll.addListener(_onScroll);
    _loadNext();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_loading || _done) return;
    if (_scroll.position.pixels >=
        _scroll.position.maxScrollExtent - 600) {
      _loadNext();
    }
  }

  Future<void> _loadNext() async {
    final src = _sourceId;
    if (src == null) {
      setState(() {
        _error = 'No source selected.';
        _loading = false;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    final result = await _repo.search(
      src,
      '',
      page: _page,
      category: widget.sectionId,
    );
    if (!mounted) return;
    result.fold(
      (failure) {
        setState(() {
          _loading = false;
          _error = failure.message;
        });
      },
      (books) {
        // Strip duplicates the provider may repeat across pages (or vs.
        // earlier sections on the home screen). If the page returns no
        // new items, treat it as the end — pagination doesn't go further.
        final fresh = books.where((b) => _seen.add(b.id)).toList();
        setState(() {
          _items.addAll(fresh);
          _loading = false;
          if (fresh.isEmpty) _done = true;
          _page += 1;
        });
      },
    );
  }

  void _openDetail(BookItem book) {
    context.pushNamed(
      'detail',
      pathParameters: {'sourceId': book.sourceId, 'bookId': book.id},
      extra: book,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_items.isEmpty && _loading) {
      return GridView.builder(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          childAspectRatio: 0.52,
          crossAxisSpacing: 10,
          mainAxisSpacing: 14,
        ),
        itemCount: 12,
        itemBuilder: (_, _) => const BookCardShimmer(width: double.infinity),
      );
    }
    if (_items.isEmpty && _error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () {
                  _page = 1;
                  _done = false;
                  _loadNext();
                },
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    if (_items.isEmpty) {
      return const Center(
        child: Text(
          'No items.',
          style: TextStyle(color: AppColors.textSecondary, fontSize: 14),
        ),
      );
    }

    // +1 trailing slot for the loader / end marker when more is loading or
    // we've finished and want to show "no more results" subtly.
    final hasFooter = _loading || _done;
    final count = _items.length + (hasFooter ? 1 : 0);

    return GridView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: 0.52,
        crossAxisSpacing: 10,
        mainAxisSpacing: 14,
      ),
      itemCount: count,
      itemBuilder: (_, i) {
        if (i >= _items.length) {
          if (_loading) {
            return const BookCardShimmer(width: double.infinity);
          }
          // _done: an empty cell at the end of the grid is fine — the user
          // already understands they've hit the bottom.
          return const SizedBox.shrink();
        }
        final b = _items[i];
        return BookCard(
          book: b,
          width: double.infinity,
          onTap: () => _openDetail(b),
          onLongPress: () => showBookCardActionSheet(context, b),
        );
      },
    );
  }
}
