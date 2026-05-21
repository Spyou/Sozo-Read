import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:hive/hive.dart';

import '../repository/downloads_repository.dart';

/// Anchors an Android foreground service so the main isolate's
/// downloads worker pool keeps running when the user backgrounds the
/// app or swipes the activity away.
///
/// The downloads themselves still happen in the main isolate
/// (`DownloadsRepository._processOne`); this service exists purely as
/// a sticky-notification host that asks Android to keep the process
/// alive. The plugin's `onStart` entry point is intentionally a no-op
/// for that reason — we don't move any work into the service isolate.
///
/// Lifecycle:
///   * [initialize] is called from `AppBootstrap.initialize()`. It
///     registers the channel + callbacks with the plugin but does not
///     start the service (`autoStart` = false).
///   * [ensureRunning] is called when the queue transitions from empty
///     to non-empty (typically by the lifecycle binder below). It
///     starts the service if it isn't already alive — Android then
///     pins the foreground notification and the process stays resident.
///   * [stopIfIdle] is called whenever the queue becomes empty. It
///     sends a `stop` event over the plugin's IPC channel which the
///     service's `onStart` handler listens for and uses to detach the
///     foreground notification.
///
/// iOS deliberately gets the plugin's defaults — Apple does not allow
/// open-ended background work for apps like this. We get ~30 seconds
/// of grace after backgrounding, which the plugin handles automatically.
class DownloadsBackgroundService {
  DownloadsBackgroundService._();

  /// Distinct notification channel so the sticky service icon doesn't
  /// share styling / priority with either the progress notification
  /// ([DownloadNotificationService]) or the new-chapter channel
  /// ([NotificationService]).
  static const String channelId = 'sozo_downloads_service';

  /// Stable id for the foreground service notification. Picked far away
  /// from the progress notification id (`0x10`) to avoid any collision.
  static const int foregroundNotificationId = 7919;

  /// IPC event name the service listens for to tear itself down.
  static const String stopEvent = 'stop';

  /// One-time plugin configuration — registers the channel, the entry
  /// point and the foreground-mode flag. Idempotent.
  static Future<void> initialize() async {
    try {
      final service = FlutterBackgroundService();
      await service.configure(
        androidConfiguration: AndroidConfiguration(
          onStart: _onStart,
          // We control start ourselves so the service only spins up
          // when there's actually work to keep alive.
          autoStart: false,
          isForegroundMode: true,
          notificationChannelId: channelId,
          initialNotificationTitle: 'Sozo Read',
          initialNotificationContent: 'Downloads ready',
          foregroundServiceNotificationId: foregroundNotificationId,
        ),
        iosConfiguration: IosConfiguration(
          autoStart: false,
          onForeground: _onStart,
        ),
      );
    } catch (e, st) {
      // Plugin failures (missing native side, desktop / test env)
      // should not crash bootstrap. The progress notification still
      // works without the foreground service — Android will just be
      // more aggressive about killing the process.
      debugPrint('[downloads-bg] initialize failed: $e\n$st');
    }
  }

  /// Start the service if it isn't already alive. Call this when the
  /// `queued` / `downloading` count goes from zero to one.
  static Future<void> ensureRunning() async {
    try {
      final service = FlutterBackgroundService();
      if (await service.isRunning()) return;
      await service.startService();
    } catch (e) {
      debugPrint('[downloads-bg] ensureRunning failed: $e');
    }
  }

  /// Ask the service to detach the foreground notification and exit.
  /// Safe to call when the service isn't running.
  static Future<void> stopIfIdle() async {
    try {
      final service = FlutterBackgroundService();
      if (!await service.isRunning()) return;
      service.invoke(stopEvent);
    } catch (e) {
      debugPrint('[downloads-bg] stopIfIdle failed: $e');
    }
  }

  /// Background-isolate entry point. Must be a top-level / static
  /// function annotated `@pragma('vm:entry-point')` so the Dart
  /// tree-shaker keeps it in release builds.
  ///
  /// We do NOT spin up download workers here — the main isolate's
  /// `DownloadsRepository` is the single source of truth for transfers,
  /// and running a second worker pool here would re-fetch every page.
  /// The job is purely to hold the foreground notification slot.
  @pragma('vm:entry-point')
  static void _onStart(ServiceInstance service) {
    // Listen for the explicit shutdown signal from the main isolate.
    service.on(stopEvent).listen((_) {
      if (service is AndroidServiceInstance) {
        // Drop the foreground attribute first so Android doesn't keep
        // the process pinned after we stop.
        // ignore: discarded_futures
        service.setAsBackgroundService();
      }
      service.stopSelf();
    });
  }
}

/// Subscribes to the downloads Hive box and starts / stops the
/// foreground service in lockstep with the active queue.
///
/// Returns a [StreamSubscription] the caller can cancel during
/// teardown (e.g. tests). The actual side effects happen inside the
/// listener.
///
/// Why not push this into the repository? The repo intentionally
/// stays UI-framework / platform-plugin independent (no
/// `flutter_background_service` import) so it remains testable in a
/// pure Dart environment.
StreamSubscription<BoxEvent> bindDownloadsBackgroundLifecycle(
  DownloadsRepository downloads,
) {
  var lastActive = false;

  bool isActive(DownloadEntry e) =>
      e.status == DownloadStatus.downloading ||
      e.status == DownloadStatus.queued ||
      e.status == DownloadStatus.paused;

  Future<void> tick() async {
    final active = downloads.all().any(isActive);
    if (active == lastActive) return;
    lastActive = active;
    if (active) {
      await DownloadsBackgroundService.ensureRunning();
    } else {
      await DownloadsBackgroundService.stopIfIdle();
    }
  }

  // Seed the initial state — the box may already contain an in-flight
  // entry from a previous launch.
  // ignore: discarded_futures
  tick();

  // The foundations agent will (eventually) expose a typed
  // `downloads.watch()` returning `Stream<BoxEvent>` from the box; if
  // that signature lands later this still compiles unchanged. Today,
  // we tap the underlying Hive box directly using the public
  // `boxName` constant — that's the cheapest way to get a stream that
  // fires on every download mutation without coupling to the repo's
  // internal `_box` getter.
  return Hive.box<Map>(DownloadsRepository.boxName).watch().listen(
    (_) {
      // ignore: discarded_futures
      tick();
    },
    onError: (Object e, StackTrace st) {
      debugPrint('[downloads-bg] box watch error: $e\n$st');
    },
  );
}
