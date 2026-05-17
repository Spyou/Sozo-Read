import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../models/book_item.dart';
import '../router/app_router.dart';

/// Thin wrapper around `flutter_local_notifications` that owns the
/// `sozoread_new_chapters` Android channel and translates new-chapter
/// alerts into deep-linkable notifications.
///
/// Lifecycle:
///   * [init] runs once during app boot (and again inside the Workmanager
///     headless isolate). Requests POST_NOTIFICATIONS on Android 13+ and
///     the user-presented alert/badge/sound prompt on iOS.
///   * [showNewChapters] is fired by [ChapterCheckService] when a library
///     entry's source has more chapters than we observed last run. The
///     payload encodes a `sozoread://manga/...` deep link so tapping the
///     notification opens the book detail.
///   * [cancelAll] clears every pending alert — handy for sign-out / a
///     "test" toggle in settings.
///
/// The class is intentionally inert until [init] succeeds; failing to
/// initialise the plugin (e.g. a sandboxed test runner) logs and
/// degrades to a no-op rather than crashing.
class NotificationService {
  NotificationService();

  static const String channelId = 'sozoread_new_chapters';
  static const String channelName = 'New chapters';
  static const String channelDescription =
      'Alerts when a saved book has new chapters.';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialised = false;

  Future<void> init() async {
    if (_initialised) return;
    try {
      const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
      const iosInit = DarwinInitializationSettings(
        // Defer the runtime permission prompt to the explicit request
        // call below — iOS only shows it once, and we want a chance to
        // surface a friendly explanation later if needed.
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      );
      const settings = InitializationSettings(
        android: androidInit,
        iOS: iosInit,
      );
      await _plugin.initialize(
        settings,
        onDidReceiveNotificationResponse: _onTap,
        // Background-launched taps land here (app cold-started by the
        // notification itself). _onTap reads `appRouter` which the
        // cold-start path also consults, so we route through the same
        // handler.
        onDidReceiveBackgroundNotificationResponse:
            notificationTapBackground,
      );

      // Channel creation is a no-op on Android < 8 and ignored on iOS.
      final androidImpl = _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      if (androidImpl != null) {
        await androidImpl.createNotificationChannel(
          const AndroidNotificationChannel(
            channelId,
            channelName,
            description: channelDescription,
            importance: Importance.high,
          ),
        );
        // POST_NOTIFICATIONS prompt (Android 13+). Older versions
        // auto-grant; the call is harmless there.
        try {
          await androidImpl.requestNotificationsPermission();
        } catch (e) {
          debugPrint('[notifications] Android permission request failed: $e');
        }
      }

      final iosImpl = _plugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      if (iosImpl != null) {
        try {
          await iosImpl.requestPermissions(
            alert: true,
            badge: true,
            sound: true,
          );
        } catch (e) {
          debugPrint('[notifications] iOS permission request failed: $e');
        }
      }

      _initialised = true;
    } catch (e, st) {
      debugPrint('[notifications] init failed: $e\n$st');
    }
  }

  /// Fires a single high-priority alert for [book]. [newCount] is the
  /// number of *new* chapters (delta), not the total.
  Future<void> showNewChapters({
    required BookItem book,
    required int newCount,
  }) async {
    if (!_initialised) {
      // Late init on a code path that skipped boot (e.g. workmanager
      // dispatcher) — try once more.
      await init();
      if (!_initialised) return;
    }
    final s = newCount == 1 ? '' : 's';
    final title = book.title;
    final body = '$newCount new chapter$s available';
    final payload = _buildPayload(book);

    // Stable id per book so subsequent alerts for the same title replace
    // the previous one instead of stacking.
    final id = _idFor(book);

    const androidDetails = AndroidNotificationDetails(
      channelId,
      channelName,
      channelDescription: channelDescription,
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.message,
    );
    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    try {
      await _plugin.show(id, title, body, details, payload: payload);
    } catch (e) {
      debugPrint('[notifications] show failed for ${book.title}: $e');
    }
  }

  Future<void> cancelAll() async {
    try {
      await _plugin.cancelAll();
    } catch (e) {
      debugPrint('[notifications] cancelAll failed: $e');
    }
  }

  // -------------------------------------------------------------------
  // Internals
  // -------------------------------------------------------------------

  /// Builds the `sozoread://manga/{sourceId}/{bookId}?url=...` link that
  /// [parseSozoReadDeepLink] knows how to dispatch.
  String _buildPayload(BookItem book) {
    final src = Uri.encodeComponent(book.sourceId);
    final id = Uri.encodeComponent(book.id);
    final url = Uri.encodeQueryComponent(book.url);
    return 'sozoread://manga/$src/$id?url=$url';
  }

  /// Hashes the key into a 31-bit positive int (platform notification ids
  /// are signed 32-bit).
  int _idFor(BookItem book) {
    final key = '${book.sourceId}::${book.id}';
    final h = key.hashCode & 0x7fffffff;
    return h;
  }

  void _onTap(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null || payload.isEmpty) return;
    try {
      final parsed = parseSozoReadDeepLink(Uri.parse(payload));
      if (parsed == null) return;
      final router = appRouter;
      if (router != null) {
        router.push(parsed);
      }
      // If `appRouter` is still null we're being launched from a fully
      // terminated state — `buildRouter()`'s `_resolveInitialLocation`
      // reads `PlatformDispatcher.defaultRouteName` for the cold-start
      // link, which the OS sets when the notification launches the
      // activity. Nothing more to do here.
    } catch (e) {
      debugPrint('[notifications] tap handler failed: $e');
    }
  }
}

/// Top-level handler for taps that arrive while the app is fully
/// backgrounded. Required by `flutter_local_notifications` to be a
/// top-level / static function. Currently a no-op — the live tap handler
/// already covers the warm-resume path, and cold launches are picked up
/// by `_resolveInitialLocation`.
@pragma('vm:entry-point')
void notificationTapBackground(NotificationResponse response) {
  // Intentionally empty. See doc above.
}
