import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../repository/voices_repository.dart';
import 'sherpa_tts_engine.dart';
import 'voice_catalog.dart';

/// Base type for one snapshot of a [VoiceDownloader.download] stream.
/// Concrete subclasses model the lifecycle phases — listeners switch
/// on the runtime type ( `is VoiceDownloading` ... ).
sealed class VoiceDownloadEvent {
  const VoiceDownloadEvent();
}

/// Bytes are still arriving from the network. [progress] is 0..1.
class VoiceDownloading extends VoiceDownloadEvent {
  const VoiceDownloading(this.progress);
  final double progress;
}

/// Download finished, tar+bz2 is being unpacked into the docs dir.
/// We don't surface progress here — tar extraction would need a
/// preflight pass to estimate total entries, which isn't worth the
/// extra I/O for ~60-120 MB voices.
class VoiceExtracting extends VoiceDownloadEvent {
  const VoiceExtracting();
}

/// Terminal success — the voice is registered with the repo and
/// ready for the TTS engine to load.
class VoiceInstalled extends VoiceDownloadEvent {
  const VoiceInstalled();
}

/// Terminal failure. [message] is the upstream error message,
/// surfaced verbatim in the catalog UI's error row.
class VoiceFailed extends VoiceDownloadEvent {
  const VoiceFailed(this.message);
  final String message;
}

/// Fetches + extracts a Piper voice bundle from the sherpa-onnx
/// GitHub release, then registers it with [VoicesRepository] so the
/// TTS engine can load it.
///
/// One downloader instance per app — held as a singleton in the DI
/// graph. Multiple concurrent downloads are supported (each
/// `download()` returns its own stream + uses its own temp files).
class VoiceDownloader {
  VoiceDownloader({required Dio dio, required VoicesRepository repo})
      : _dio = dio,
        _repo = repo;

  final Dio _dio;
  final VoicesRepository _repo;

  /// Kicks off a download + extract + install for [voice]. The
  /// returned stream emits one event per phase; callers should listen
  /// until they see [VoiceInstalled] or [VoiceFailed] (both terminal).
  Stream<VoiceDownloadEvent> download(NeuralVoice voice) {
    final ctrl = StreamController<VoiceDownloadEvent>();
    // Run the actual work in a microtask so errors land on the stream
    // rather than as synchronous throws that bypass the listener.
    // ignore: discarded_futures
    _run(voice, ctrl);
    return ctrl.stream;
  }

  Future<void> _run(
    NeuralVoice voice,
    StreamController<VoiceDownloadEvent> ctrl,
  ) async {
    String? tarPath;
    String? installDirPath;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final cache = await getTemporaryDirectory();
      installDirPath = '${docs.path}/neural_voices/${voice.id}';
      tarPath = '${cache.path}/sozo_voice_${voice.id}.tar.bz2';

      // Wipe any partial install from a previous failed attempt so
      // the extract step writes into a clean tree.
      final installDir = Directory(installDirPath);
      if (installDir.existsSync()) {
        await installDir.delete(recursive: true);
      }
      await installDir.create(recursive: true);

      // ---- Download ----
      ctrl.add(const VoiceDownloading(0));
      await _dio.download(
        voice.archiveUrl,
        tarPath,
        onReceiveProgress: (received, total) {
          if (total <= 0) return;
          final ratio = (received / total).clamp(0.0, 1.0);
          ctrl.add(VoiceDownloading(ratio));
        },
      );

      // ---- Extract ----
      ctrl.add(const VoiceExtracting());
      final paths = await _extract(
        tarPath: tarPath,
        installDir: installDir,
      );
      if (paths == null) {
        throw StateError('voice bundle missing model.onnx / tokens.txt');
      }

      final sizeBytes = await _dirSize(installDir);
      await _repo.markInstalled(voice.id, paths, sizeBytes);

      // ---- Cleanup tarball ----
      try {
        final f = File(tarPath);
        if (f.existsSync()) await f.delete();
      } catch (_) {
        // Best-effort — the tar lives in the OS temp dir, which is
        // periodically cleaned by the platform anyway.
      }

      ctrl.add(const VoiceInstalled());
    } catch (e) {
      debugPrint('[voice-dl] download("${voice.id}") failed: $e');
      // Roll back the install dir + the partial tarball so the next
      // attempt isn't fooled by half-written state.
      if (installDirPath != null) {
        try {
          final d = Directory(installDirPath);
          if (d.existsSync()) await d.delete(recursive: true);
        } catch (_) {}
      }
      if (tarPath != null) {
        try {
          final f = File(tarPath);
          if (f.existsSync()) await f.delete();
        } catch (_) {}
      }
      ctrl.add(VoiceFailed(e.toString()));
    } finally {
      await ctrl.close();
    }
  }

  /// Removes an installed voice. Wraps the repo's `remove` (which
  /// already deletes the on-disk dir) but also handles the rare case
  /// where the metadata row is missing but a directory exists from a
  /// crashed install — walks the canonical layout as a fallback.
  Future<void> remove(NeuralVoice voice) async {
    await _repo.remove(voice.id);
    try {
      final docs = await getApplicationDocumentsDirectory();
      final fallback = Directory('${docs.path}/neural_voices/${voice.id}');
      if (fallback.existsSync()) {
        await fallback.delete(recursive: true);
      }
    } catch (e) {
      debugPrint('[voice-dl] remove("${voice.id}") fs cleanup failed: $e');
    }
  }

  /// Decodes `.tar.bz2`, writes every regular file under [installDir],
  /// then locates the three sherpa-onnx inputs by recursive walk.
  Future<SherpaVoicePaths?> _extract({
    required String tarPath,
    required Directory installDir,
  }) async {
    final bz2Bytes = await File(tarPath).readAsBytes();
    // bz2 decode runs in-memory — sherpa-onnx voices peak around
    // ~60 MB compressed / ~120 MB uncompressed (high-quality), which
    // is acceptable for a one-shot extract on a mid-range phone but
    // would be worth streaming if voices ever cross ~500 MB.
    final tarBytes = BZip2Decoder().decodeBytes(bz2Bytes);
    final archive = TarDecoder().decodeBytes(tarBytes);

    for (final entry in archive) {
      if (!entry.isFile) continue;
      // Strip the archive's top-level folder so we land everything
      // directly under installDir/. The release tarballs ship a
      // single `vits-piper-<id>/` root; flattening it keeps the
      // path layout predictable regardless of the upstream naming.
      final relative = _flattenPath(entry.name);
      if (relative.isEmpty) continue;
      final outPath = '${installDir.path}/$relative';
      final outFile = File(outPath);
      await outFile.parent.create(recursive: true);
      await outFile.writeAsBytes(entry.content as List<int>, flush: false);
    }

    // Recursive walk to find the three required inputs. We don't
    // hard-code the internal layout because some Piper releases ship
    // espeak-ng-data nested deeper than others.
    String? modelOnnx;
    String? tokens;
    String? espeakDir;
    await for (final ent
        in installDir.list(recursive: true, followLinks: false)) {
      if (ent is File) {
        final name = ent.uri.pathSegments.last;
        if (modelOnnx == null && name.endsWith('.onnx')) {
          modelOnnx = ent.path;
        } else if (tokens == null && name == 'tokens.txt') {
          tokens = ent.path;
        }
      } else if (ent is Directory) {
        final segs = ent.uri.pathSegments.where((p) => p.isNotEmpty).toList();
        if (segs.isEmpty) continue;
        if (espeakDir == null && segs.last == 'espeak-ng-data') {
          espeakDir = ent.path;
        }
      }
    }

    if (modelOnnx == null || tokens == null || espeakDir == null) {
      return null;
    }
    return SherpaVoicePaths(
      model: modelOnnx,
      tokens: tokens,
      dataDir: espeakDir,
    );
  }

  /// Drops the single top-level archive folder from [name]. Returns
  /// the empty string for the bare folder entry itself so callers
  /// can skip it.
  String _flattenPath(String name) {
    final cleaned = name.replaceAll('\\', '/');
    final idx = cleaned.indexOf('/');
    if (idx < 0) return '';
    return cleaned.substring(idx + 1);
  }

  Future<int> _dirSize(Directory dir) async {
    var total = 0;
    try {
      await for (final ent in dir.list(recursive: true, followLinks: false)) {
        if (ent is File) {
          try {
            total += await ent.length();
          } catch (_) {/* ignore unreadable */}
        }
      }
    } catch (_) {/* best-effort */}
    return total;
  }
}
