import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../models/github_release.dart';
import 'apk_installer.dart';
import 'changelog_service.dart';

/// Auto-updater: GitHub releases → APK download → system installer.
///
/// Reuses [ChangelogService] for the underlying `/releases` fetch so we share
/// one 24h cache + ETag + the same 60req/IP/hr GitHub budget. The download
/// step streams via Dio with a [CancelToken] so the UI can cancel mid-pull.
///
/// NOTE: Google Play forbids self-update; if a Play build is ever shipped,
/// feature-flag every call to this service off.
class UpdateService {
  UpdateService({
    required ChangelogService changelog,
    required Dio dio,
    required ApkInstaller installer,
    required String boxName,
  })  : _changelog = changelog,
        _dio = dio,
        _installer = installer,
        _boxName = boxName;

  final ChangelogService _changelog;
  final Dio _dio;
  final ApkInstaller _installer;
  final String _boxName;

  static const String kSkippedVersion = 'update.skipped_version';
  static const String kRemindAfterMs = 'update.remind_after_ms';
  static const String kAutoCheck = 'update.auto_check';
  static const String kBetaChannel = 'update.beta_channel';
  static const String kLastCheckMs = 'update.last_check_ms';

  Box get _box => Hive.box(_boxName);

  /// Fetches the latest release and returns it if it's newer than the
  /// running app's version. Skips prereleases unless [includeBeta] is true.
  Future<GitHubRelease?> checkForUpdate({
    bool includeBeta = false,
    bool forceRefresh = false,
  }) async {
    try {
      final releases = await _changelog.all(forceRefresh: forceRefresh);
      if (releases.isEmpty) return null;
      final candidates = includeBeta
          ? releases
          : releases.where((r) => !r.prerelease).toList();
      if (candidates.isEmpty) return null;
      // releases come newest-first from ChangelogService.
      final latest = candidates.first;
      final pkg = await PackageInfo.fromPlatform();
      if (_isNewer(latest.tagName, pkg.version)) return latest;
      return null;
    } catch (e) {
      debugPrint('[update] check failed: $e');
      return null;
    }
  }

  /// True when [release] should pop a sheet: not skipped, past the
  /// remind-later window.
  bool shouldPrompt(GitHubRelease release) {
    final skipped = _box.get(kSkippedVersion);
    if (skipped is String && skipped.isNotEmpty && skipped == release.tagName) {
      return false;
    }
    final remindAfter = _box.get(kRemindAfterMs);
    if (remindAfter is int &&
        DateTime.now().millisecondsSinceEpoch < remindAfter) {
      return false;
    }
    return true;
  }

  /// Picks the best APK asset for this device.
  ///
  /// Strategy:
  ///   1. Prefer an asset whose name contains the device's primary ABI
  ///      (e.g. `arm64-v8a` on a modern phone → `SozoRead-v1.3-arm64.apk`).
  ///   2. Else prefer an asset whose name contains `universal` (the
  ///      fat fallback build).
  ///   3. Else fall back to the release's first `.apk` ([release.apkAsset]).
  ///
  /// Filename matching is case-insensitive. The ABI string from
  /// [ApkInstaller.primaryAbi] is matched against the asset name with a
  /// stripped form too (`arm64-v8a` also matches assets named just
  /// `arm64`), so we don't strictly require the full ABI tag in the
  /// release's filename — common short labels work.
  Future<GitHubReleaseAsset?> resolveApkAsset(GitHubRelease release) async {
    final apks = release.assets
        .where((a) => a.name.toLowerCase().endsWith('.apk'))
        .toList();
    if (apks.isEmpty) return null;
    if (apks.length == 1) return apks.first;
    final abi = (await _installer.primaryAbi())?.toLowerCase();
    if (abi != null && abi.isNotEmpty) {
      // `arm64-v8a` → also accept `arm64`. `armeabi-v7a` → `armv7` /
      // `armeabi`. `x86_64` keeps itself.
      final aliases = <String>{abi};
      if (abi == 'arm64-v8a') aliases.add('arm64');
      if (abi == 'armeabi-v7a') {
        aliases.add('armv7');
        aliases.add('armeabi');
      }
      for (final a in apks) {
        final n = a.name.toLowerCase();
        if (aliases.any(n.contains)) return a;
      }
    }
    for (final a in apks) {
      if (a.name.toLowerCase().contains('universal')) return a;
    }
    return apks.first;
  }

  /// Streams progress 0..1 while downloading the best-matching APK asset
  /// to [targetPath]. Throws if the release has no APK.
  Stream<double> downloadApk(
    GitHubRelease release, {
    required String targetPath,
    CancelToken? cancelToken,
  }) {
    final controller = StreamController<double>();
    // Run the download off the stream subscription so the caller gets
    // progress events as soon as Dio reports them. Asset selection is
    // async (it hops to the platform channel for the device's ABI) so
    // the resolver call lives inside this future.
    () async {
      try {
        final asset = await resolveApkAsset(release);
        if (asset == null || asset.browserDownloadUrl.isEmpty) {
          if (!controller.isClosed) {
            controller
                .addError(StateError('No APK asset on ${release.tagName}'));
            await controller.close();
          }
          return;
        }
        await _dio.download(
          asset.browserDownloadUrl,
          targetPath,
          cancelToken: cancelToken,
          options: Options(
            followRedirects: true,
            // GitHub asset URLs 302 to S3; let Dio chase the redirect.
            headers: {'Accept': 'application/octet-stream'},
            // Treat any 2xx as success.
            validateStatus: (s) => s != null && s >= 200 && s < 300,
          ),
          onReceiveProgress: (received, total) {
            if (controller.isClosed) return;
            if (total <= 0) {
              controller.add(0);
            } else {
              controller.add(received / total);
            }
          },
        );
        if (!controller.isClosed) {
          controller.add(1);
          await controller.close();
        }
      } catch (e) {
        if (!controller.isClosed) {
          controller.addError(e);
          await controller.close();
        }
      }
    }();
    return controller.stream;
  }

  /// Hands the downloaded APK to the OS installer prompt.
  Future<void> install(String apkPath) => _installer.installApk(apkPath);

  /// Persist the "skip this version" preference. The user won't be prompted
  /// for [release] again unless a newer one shows up.
  Future<void> skipVersion(GitHubRelease release) async {
    await _box.put(kSkippedVersion, release.tagName);
  }

  /// Snooze prompts for [duration].
  Future<void> remindLater({Duration duration = const Duration(hours: 24)}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _box.put(kRemindAfterMs, now + duration.inMilliseconds);
  }

  /// Used by the launch-time throttle so we don't hit GitHub every cold
  /// start during the same 6h window.
  Future<void> markCheckedNow() async {
    await _box.put(kLastCheckMs, DateTime.now().millisecondsSinceEpoch);
  }

  /// Last successful check timestamp, or null if never.
  DateTime? lastCheckedAt() {
    final raw = _box.get(kLastCheckMs);
    if (raw is int) return DateTime.fromMillisecondsSinceEpoch(raw);
    return null;
  }

  /// True when `[remote]` is strictly newer than `[local]`. Tolerates a
  /// leading `v`, build metadata after `+`, and a `-beta.N` / `-rc.N`
  /// suffix. Pre-release tags rank below the same numeric base (1.2.0-rc.1
  /// < 1.2.0), matching SemVer 2.0.0 precedence rules.
  static bool _isNewer(String remote, String local) =>
      _compareSemver(remote, local) > 0;

  // ~30 LOC inline comparator — pulling a semver dep is overkill for one call.
  static int _compareSemver(String a, String b) {
    final pa = _parseSemver(a);
    final pb = _parseSemver(b);
    for (var i = 0; i < 3; i++) {
      final cmp = pa.parts[i].compareTo(pb.parts[i]);
      if (cmp != 0) return cmp;
    }
    // Per SemVer: a version WITHOUT pre-release outranks the same base WITH one.
    if (pa.pre.isEmpty && pb.pre.isNotEmpty) return 1;
    if (pa.pre.isNotEmpty && pb.pre.isEmpty) return -1;
    if (pa.pre.isEmpty && pb.pre.isEmpty) return 0;
    return pa.pre.compareTo(pb.pre);
  }

  static _Semver _parseSemver(String raw) {
    var s = raw.trim();
    if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
    // Strip build metadata after `+`.
    final plus = s.indexOf('+');
    if (plus >= 0) s = s.substring(0, plus);
    String pre = '';
    final dash = s.indexOf('-');
    if (dash >= 0) {
      pre = s.substring(dash + 1);
      s = s.substring(0, dash);
    }
    final segs = s.split('.');
    final parts = <int>[0, 0, 0];
    for (var i = 0; i < 3 && i < segs.length; i++) {
      parts[i] = int.tryParse(segs[i]) ?? 0;
    }
    return _Semver(parts, pre);
  }
}

class _Semver {
  const _Semver(this.parts, this.pre);
  final List<int> parts;
  final String pre;
}
