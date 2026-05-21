import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:hive/hive.dart';

import '../repository/downloads_repository.dart';
import '../router/app_router.dart';
import 'notification_service.dart';

/// Renders a single persistent system notification that summarises the
/// current download queue, refreshed (throttled) on every Hive box event.
///
/// The notification mirrors the in-flight chapter — title is one of
/// `Downloading… / Paused / Queued` depending on the dominant state, the
/// body shows `bookTitle — chapterTitle`, and an ongoing progress bar
/// reflects `completed / total` for the chapter currently being fetched.
/// When the queue empties (no `queued`, `downloading`, or `paused`
/// entries remain) the notification is cancelled.
///
/// Tapping the notification deep-links to `/downloads` via
/// [parseSozoReadDeepLink] — the payload is the literal
/// `sozoread://downloads` URI.
///
/// Throttling: page-completed events fire on every page boundary (~5-10
/// per second on a fast link) which would spam the system; we use a
/// 500ms timer + dirty-flag pattern so the render happens at most twice
/// a second.
class DownloadNotificationService {
  DownloadNotificationService({
    required DownloadsRepository downloads,
    required NotificationService notifications,
  })  : _downloads = downloads,
        _notifications = notifications;

  final DownloadsRepository _downloads;
  // Held only so DI / the caller can ensure NotificationService.init()
  // ran before we attempt to fire notifications — the plugin we drive
  // is our own FlutterLocalNotificationsPlugin instance because
  // `flutter_local_notifications` doesn't expose the inner one from
  // `NotificationService`.
  // ignore: unused_field
  final NotificationService _notifications;

  /// Channel used for the persistent downloads notification. Distinct
  /// from `sozoread_new_chapters` so a user who muted new-chapter
  /// alerts still sees download progress (and vice versa).
  static const String channelId = 'sozo_downloads';
  static const String channelName = 'Downloads';
  static const String channelDescription =
      'Shows the active manga / novel download queue.';

  /// Stable notification id. A single persistent notification is reused
  /// — `show()` replaces in-place rather than stacking entries.
  static const int notificationId = 0x10; // 16

  /// Payload that triggers `parseSozoReadDeepLink` → `/downloads`.
  static const String _payload = 'sozoread://downloads';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialised = false;
  bool _started = false;
  StreamSubscription<BoxEvent>? _sub;
  Timer? _throttle;
  bool _dirty = false;

  /// Begin listening for download box events. Idempotent — calling twice
  /// is a no-op so bootstrap retries don't double-subscribe.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    try {
      await _ensureInitialised();
    } catch (e, st) {
      debugPrint('[downloads-notif] init failed: $e\n$st');
      // Fall through — we still attach the subscription so a later
      // permission grant / replatform doesn't strand us.
    }
    try {
      _sub = _watchBox().listen(
        (_) => _markDirty(),
        onError: (e, st) =>
            debugPrint('[downloads-notif] box stream error: $e\n$st'),
      );
      // Render the initial state immediately — the box may already
      // contain `downloading` entries from a previous launch.
      _markDirty();
    } catch (e, st) {
      debugPrint('[downloads-notif] failed to attach to downloads box: '
          '$e\n$st');
    }
  }

  /// Stop the subscription and hide the notification. Safe to call even
  /// if [start] was never invoked.
  Future<void> stop() async {
    _started = false;
    await _sub?.cancel();
    _sub = null;
    _throttle?.cancel();
    _throttle = null;
    _dirty = false;
    try {
      await _plugin.cancel(notificationId);
    } catch (e) {
      debugPrint('[downloads-notif] stop/cancel failed: $e');
    }
  }

  // -------------------------------------------------------------------
  // Internals
  // -------------------------------------------------------------------

  /// Stream of mutations to the downloads Hive box. The foundations
  /// agent is expected to expose a typed `downloads.watch()` returning
  /// `Stream<BoxEvent>` — until then we tap the underlying Hive box
  /// directly via [DownloadsRepository.boxName]. Either way the
  /// resulting stream fires once per download mutation, which is what
  /// we throttle in [_markDirty].
  Stream<BoxEvent> _watchBox() {
    return Hive.box<Map>(DownloadsRepository.boxName).watch();
  }

  Future<void> _ensureInitialised() async {
    if (_initialised) return;
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings(
      // The new-chapter notification service already prompted the user
      // for permission during boot — we just need the plugin wired up.
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const settings = InitializationSettings(android: androidInit, iOS: iosInit);
    await _plugin.initialize(
      settings,
      onDidReceiveNotificationResponse: _onTap,
      onDidReceiveBackgroundNotificationResponse: downloadsNotifTapBackground,
    );

    final androidImpl = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (androidImpl != null) {
      await androidImpl.createNotificationChannel(
        const AndroidNotificationChannel(
          channelId,
          channelName,
          description: channelDescription,
          // Low importance so the device doesn't ping / vibrate on every
          // progress update — the notification is informational, not
          // attention-demanding.
          importance: Importance.low,
        ),
      );
    }

    _initialised = true;
  }

  void _markDirty() {
    _dirty = true;
    if (_throttle != null) return;
    _throttle = Timer(const Duration(milliseconds: 500), () {
      _throttle = null;
      if (!_dirty) return;
      _dirty = false;
      // ignore: discarded_futures
      _render();
    });
  }

  /// Inspects the box state and either shows or cancels the persistent
  /// notification.
  Future<void> _render() async {
    if (!_initialised) {
      await _ensureInitialised();
      if (!_initialised) return; // platform doesn't support notifications
    }

    final entries = _downloads.all();
    // Filter out terminal states — `done` / `failed` shouldn't pin the
    // notification open.
    final active = entries.where((e) =>
        e.status == DownloadStatus.downloading ||
        e.status == DownloadStatus.queued ||
        e.status == DownloadStatus.paused).toList();

    if (active.isEmpty) {
      try {
        await _plugin.cancel(notificationId);
      } catch (e) {
        debugPrint('[downloads-notif] cancel failed: $e');
      }
      return;
    }

    // Pick a "dominant" entry to display in the body / progress bar.
    // Preference order:
    //   1. An actively downloading entry (the page count is moving)
    //   2. A queued entry (about to start)
    //   3. A paused entry (user can resume from the screen)
    DownloadEntry? dominant = active
        .where((e) => e.status == DownloadStatus.downloading)
        .fold<DownloadEntry?>(null, _newerOf);
    dominant ??= active
        .where((e) => e.status == DownloadStatus.queued)
        .fold<DownloadEntry?>(null, _newerOf);
    dominant ??= active
        .where((e) => e.status == DownloadStatus.paused)
        .fold<DownloadEntry?>(null, _newerOf);
    dominant ??= active.first;

    final title = _titleFor(dominant.status);
    final body = '${dominant.bookTitle} — ${dominant.chapterTitle}';
    final remaining = active.length - 1;
    final subText = remaining <= 0
        ? null
        : '$remaining chapter${remaining == 1 ? '' : 's'} left in queue';

    // Clamp completed ≤ total so the system bar doesn't render an
    // overflow.
    final total = dominant.total <= 0 ? 1 : dominant.total;
    final completed = dominant.completed.clamp(0, total);
    final indeterminate = dominant.status == DownloadStatus.queued &&
        dominant.completed == 0;

    final androidDetails = AndroidNotificationDetails(
      channelId,
      channelName,
      channelDescription: channelDescription,
      importance: Importance.low,
      priority: Priority.low,
      onlyAlertOnce: true,
      ongoing: dominant.status != DownloadStatus.paused,
      autoCancel: false,
      category: AndroidNotificationCategory.progress,
      showProgress: true,
      maxProgress: total,
      progress: completed,
      indeterminate: indeterminate,
      subText: subText,
    );
    final iosDetails = const DarwinNotificationDetails(
      presentAlert: false,
      presentBadge: false,
      presentSound: false,
    );
    final details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    try {
      await _plugin.show(notificationId, title, body, details,
          payload: _payload);
    } catch (e) {
      debugPrint('[downloads-notif] show failed: $e');
    }
  }

  String _titleFor(DownloadStatus s) {
    switch (s) {
      case DownloadStatus.downloading:
        return 'Sozo Read · Downloading…';
      case DownloadStatus.paused:
        return 'Sozo Read · Paused';
      case DownloadStatus.queued:
        return 'Sozo Read · Queued';
      case DownloadStatus.done:
      case DownloadStatus.failed:
        // Shouldn't be picked as dominant, but cover the enum.
        return 'Sozo Read';
    }
  }

  /// Folder helper — keeps whichever entry was updated most recently
  /// so the notification reflects what the user just saw move.
  DownloadEntry? _newerOf(DownloadEntry? a, DownloadEntry b) {
    if (a == null) return b;
    return a.updatedAt.isAfter(b.updatedAt) ? a : b;
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
    } catch (e) {
      debugPrint('[downloads-notif] tap handler failed: $e');
    }
  }
}

/// Top-level entry point required by `flutter_local_notifications` for
/// background-isolate taps. The active foreground handler covers the
/// warm-resume path; cold-start launches are picked up by
/// `_resolveInitialLocation` in app_router.dart.
@pragma('vm:entry-point')
void downloadsNotifTapBackground(NotificationResponse response) {
  // Intentionally empty — see comment above.
}
