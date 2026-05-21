import 'package:flutter/foundation.dart';

import '../repository/library_repository.dart';
import '../repository/notifications_repository.dart';
import '../repository/provider_repository.dart';
import '../state/notifications_prefs_cubit.dart';
import 'notification_service.dart';

/// Periodic check that asks each library entry's source for its current
/// chapter list and fires a local notification when the count has grown
/// since the last run.
///
/// Designed to run inside the Workmanager headless isolate, so it must
/// be safe to invoke when the UI is gone and there's no live BLoC
/// hierarchy. The service degrades gracefully:
///
///   * If notifications are disabled in prefs we quick-out.
///   * Each provider call is wrapped — one bad source can't kill the
///     loop.
///   * Failures are logged via `debugPrint('[chapter-check] ...')`,
///     matching the convention used by [LibrarySyncService].
///
/// Calls are intentionally sequential. The JS-runtime-backed providers
/// share a single Dio + concurrency limits; firing fifty parallel
/// `getDetail` requests would tip several scrapers into rate-limit
/// territory.
class ChapterCheckService {
  ChapterCheckService({
    required LibraryRepository library,
    required ProviderRepository providers,
    required NotificationService notifications,
    required NotificationsRepository inbox,
  })  : _library = library,
        _providers = providers,
        _notifications = notifications,
        _inbox = inbox;

  final LibraryRepository _library;
  final ProviderRepository _providers;
  final NotificationService _notifications;
  final NotificationsRepository _inbox;

  /// Iterates every saved book, asks its source for the latest chapter
  /// list, fires a notification when the count has grown, then
  /// persists the new high-watermark. Returns the number of
  /// notifications fired.
  Future<int> checkAllForNewChapters() async {
    if (!NotificationsPrefsCubit.readNewChaptersEnabled()) {
      debugPrint('[chapter-check] notifications disabled — skipping');
      return 0;
    }
    final entries = _library.getAll();
    if (entries.isEmpty) {
      debugPrint('[chapter-check] library empty — nothing to do');
      return 0;
    }
    debugPrint('[chapter-check] scanning ${entries.length} entries');

    var notified = 0;
    for (final entry in entries) {
      try {
        final book = entry.book;
        final provider = _providers.provider(book.sourceId);
        if (provider == null) {
          // Source uninstalled / not loaded in this isolate — skip
          // silently. We don't reset the counter; a future run with the
          // provider available will pick up where we left off.
          continue;
        }
        final result = await _providers.detail(book.sourceId, book.url);
        await result.fold(
          (failure) async {
            debugPrint(
              '[chapter-check] ${book.sourceId}/${book.id} fetch failed: '
              '${failure.runtimeType}',
            );
          },
          (detail) async {
            final current = detail.chapters.length;
            final previous = entry.lastSeenChapterCount;
            if (previous == 0) {
              // First time we've seen this entry — seed the watermark
              // without alerting. We have no baseline to compare
              // against, and we don't want a flood of "X new chapters"
              // alerts on the first background run after upgrading.
              await _library.updateLastSeenChapterCount(
                sourceId: book.sourceId,
                bookId: book.id,
                count: current,
              );
              return;
            }
            if (current > previous) {
              final delta = current - previous;
              await _notifications.showNewChapters(
                book: book,
                newCount: delta,
              );
              // Persist a row in the local inbox so the user can still
              // see the event after dismissing the OS notification.
              // ignore: discarded_futures
              _inbox.add(
                type: 'new_chapter',
                title: book.title,
                body: delta == 1
                    ? 'New chapter available'
                    : '$delta new chapters available',
                sourceId: book.sourceId,
                bookId: book.id,
                coverUrl: book.cover,
              );
              notified++;
              await _library.updateLastSeenChapterCount(
                sourceId: book.sourceId,
                bookId: book.id,
                count: current,
              );
              debugPrint(
                '[chapter-check] ${book.title}: $previous -> $current '
                '(+$delta) notified',
              );
            } else if (current < previous) {
              // Source removed chapters (re-licensing, moderation, ...).
              // Quietly resync the watermark so a future re-upload
              // alerts on the diff against the new floor instead of
              // misreporting.
              await _library.updateLastSeenChapterCount(
                sourceId: book.sourceId,
                bookId: book.id,
                count: current,
              );
            }
          },
        );
      } catch (e, st) {
        debugPrint(
          '[chapter-check] unexpected error for ${entry.key}: $e\n$st',
        );
      }
    }
    debugPrint('[chapter-check] done — $notified notification(s) fired');
    return notified;
  }
}
