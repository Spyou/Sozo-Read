import 'dart:async';

import '../models/book_item.dart';
import '../provider/provider_manager.dart';
import '../repository/provider_repository.dart';
import '../utils/string_similarity.dart';

/// One candidate match returned from a cross-source title search. Wraps
/// the discovered [book] plus its similarity [score] against the source
/// title. The [sourceId] / [repoUrl] pair uniquely identifies the
/// provider that produced it (multiple repos can ship the same sourceId).
class MatchCandidate {
  const MatchCandidate({
    required this.sourceId,
    required this.repoUrl,
    required this.book,
    required this.score,
  });

  final String sourceId;
  final String repoUrl;
  final BookItem book;
  final double score;
}

/// Searches every loaded provider (except the source's own) for a title
/// matching [source.title] and returns the highest-scoring candidate
/// above [threshold], or null if none clear the bar. Each provider's
/// search is wrapped in a per-source timeout so a dead host can't stall
/// the whole fanout.
///
/// Matches the per-source 10s fanout pattern used by [SearchBloc]. The
/// caller is expected to gate this behind an explicit user opt-in (see
/// [AutoSwitchPrefs]) — false positives on sequels, translations, and
/// ambiguous one-word titles are mitigated by the 0.78 default threshold
/// and explicit user confirmation in the UI before any navigation.
class CrossSourceMatcher {
  CrossSourceMatcher({required ProviderRepository repository})
      : _repo = repository;

  final ProviderRepository _repo;

  Future<MatchCandidate?> findMatch({
    required BookItem source,
    double threshold = 0.78,
    Duration timeoutPerSource = const Duration(seconds: 10),
  }) async {
    final providers = _repo.providers
        .where((p) => p.sourceId != source.sourceId)
        .toList();
    if (providers.isEmpty) return null;

    final results = await Future.wait(providers.map((p) async {
      return _searchOne(p, source, timeoutPerSource);
    }));

    MatchCandidate? best;
    for (final c in results) {
      if (c == null) continue;
      if (c.score < threshold) continue;
      if (best == null || c.score > best.score) best = c;
    }
    return best;
  }

  Future<MatchCandidate?> _searchOne(
    JsProvider provider,
    BookItem source,
    Duration timeout,
  ) async {
    try {
      final items = await provider
          .search(source.title, 1)
          .timeout(timeout);
      if (items.isEmpty) return null;
      // Score every candidate and pick the best within this source.
      MatchCandidate? bestForSource;
      for (final item in items) {
        final score = similarity(source.title, item.title);
        if (bestForSource == null || score > bestForSource.score) {
          bestForSource = MatchCandidate(
            sourceId: provider.sourceId,
            repoUrl: provider.originRepoUrl,
            book: item,
            score: score,
          );
        }
      }
      return bestForSource;
    } catch (_) {
      // Timeout, network, JS runtime error — caller treats source as failed.
      return null;
    }
  }

  /// Cache-key helper. Mirrors the pattern used by [BookDetailCache] —
  /// `<sourceId>::<bookId>`.
  String? matchKey(String sourceId, String bookId) =>
      '$sourceId::$bookId';
}
