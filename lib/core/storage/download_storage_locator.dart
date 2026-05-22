import 'dart:io';

import 'package:hive/hive.dart';

import 'download_storage.dart';
import 'internal_download_storage.dart';
import 'saf_download_storage.dart';

/// Looks up the active [DownloadStorage] based on the user's persisted
/// preference in the shared `settings` Hive box. The key
/// `downloads.root_uri` holds either:
///   * the empty string / missing  → internal storage (legacy default)
///   * an Android SAF tree URI    → [SafDownloadStorage] wrapping it
///
/// Caches the resolved instance so the worker pool doesn't rebuild the
/// backend on every page. Call [invalidate] after the user picks a new
/// location so the next access rebuilds against the new URI.
class DownloadStorageLocator {
  DownloadStorageLocator._();

  static const String settingsBoxName = 'settings';
  static const String rootUriKey = 'downloads.root_uri';

  static DownloadStorage? _cached;
  static String? _cachedUri;

  /// Current storage backend. Cheap to call repeatedly — does not touch
  /// Hive on cache hits.
  static DownloadStorage get current {
    final uri = _readUri();
    if (_cached != null && _cachedUri == uri) {
      return _cached!;
    }
    final next = _build(uri);
    _cached = next;
    _cachedUri = uri;
    return next;
  }

  /// User-facing label for the current location. Used by the storage
  /// settings tile. We don't try to humanize the SAF tree URI (it's a
  /// content:// path that the system picker chose) — showing the URI is
  /// good enough for a "this is where your files go" affordance.
  static String get currentLabel {
    final uri = _readUri();
    if (uri == null || uri.isEmpty) return 'Internal storage';
    return uri;
  }

  /// True iff the user has explicitly picked an SAF location. Drives the
  /// "Migrate downloads" tile visibility on the storage settings screen.
  static bool get hasCustomLocation {
    final uri = _readUri();
    return uri != null && uri.isNotEmpty;
  }

  /// True on Android only. iOS does not expose SAF; the picker button is
  /// hidden / shows a toast on non-Android platforms.
  static bool get safSupported => Platform.isAndroid;

  /// Persists [uri] (or empty string to revert to internal) and clears the
  /// cache so the next [current] read rebuilds.
  static Future<void> setRootUri(String? uri) async {
    final box = Hive.box(settingsBoxName);
    if (uri == null || uri.isEmpty) {
      await box.delete(rootUriKey);
    } else {
      await box.put(rootUriKey, uri);
    }
    invalidate();
  }

  /// Drop the cached backend. The next [current] read resolves from Hive.
  static void invalidate() {
    _cached = null;
    _cachedUri = null;
  }

  static String? _readUri() {
    if (!Hive.isBoxOpen(settingsBoxName)) return null;
    final raw = Hive.box(settingsBoxName).get(rootUriKey);
    if (raw is String && raw.isNotEmpty) return raw;
    return null;
  }

  static DownloadStorage _build(String? uri) {
    if (uri != null && uri.isNotEmpty && Platform.isAndroid) {
      return SafDownloadStorage(uri);
    }
    return InternalDownloadStorage();
  }
}
