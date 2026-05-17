import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/book_item.dart';
import '../repository/library_repository.dart';
import '../repository/read_chapters_repository.dart';
import '../state/auth_service.dart';

/// State the [LibrarySyncService] is currently in. UI consumers (e.g. the
/// Library tab's sync badge) subscribe to [LibrarySyncService.statusStream]
/// and switch on this.
enum LibrarySyncStatus { idle, syncing, error }

/// Bi-directional sync between the local Hive `library` box and the
/// Supabase `library_entries` table.
///
/// Design (decisions are in docs/round4-sync-plan.md if you want context):
///
/// * **Push** is debounced. [LibraryRepository] flags every user write in
///   its own `library_sync_dirty` box; this service drains that box on a
///   2-second debounce, batches them into one Supabase `upsert`, then
///   acks the keys.
/// * **Pull** runs at app launch (if signed-in), again on every
///   `signedIn` auth event, and via [refresh] for manual pull-to-refresh.
///   Cloud rows are merged into Hive last-write-wins by `updated_at`.
/// * **Deletions** write a tombstone before the local delete so we still
///   know to delete the cloud row even if the entry is gone. The cloud
///   wins if its row has been updated *after* the tombstone (resurrection
///   from another device).
/// * **Pull writes** go through [LibraryRepository.putFromSync] which
///   bypasses dirty-tracking so a pull doesn't immediately schedule a
///   re-push of everything it just fetched.
///
/// The app remains usable offline: every method swallows network errors
/// and leaves the dirty/tombstone boxes intact so the next successful
/// flush picks up where we left off.
class LibrarySyncService {
  LibrarySyncService({
    required LibraryRepository library,
    required ReadChaptersRepository readChapters,
    required AuthService auth,
  })  : _library = library,
        _readChapters = readChapters,
        _auth = auth;

  static const _table = 'library_entries';
  static const _readChaptersTable = 'read_chapters';
  static const Duration _debounce = Duration(seconds: 2);

  final LibraryRepository _library;
  final ReadChaptersRepository _readChapters;
  final AuthService _auth;

  SupabaseClient? get _client {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  StreamSubscription<AuthChangeEvent>? _authSub;
  Timer? _debounceTimer;
  bool _flushing = false;
  bool _started = false;

  // ---- status reporting ----------------------------------------------
  final StreamController<LibrarySyncStatus> _statusController =
      StreamController<LibrarySyncStatus>.broadcast();
  LibrarySyncStatus _status = LibrarySyncStatus.idle;
  DateTime? _lastSyncedAt;
  String? _lastError;

  /// Broadcasts the current sync status whenever it changes. UI can also
  /// read [status] directly for the synchronous current value.
  Stream<LibrarySyncStatus> get statusStream => _statusController.stream;
  LibrarySyncStatus get status => _status;
  DateTime? get lastSyncedAt => _lastSyncedAt;
  String? get lastError => _lastError;

  void _setStatus(LibrarySyncStatus next, {String? error}) {
    if (next == _status && error == _lastError) return;
    _status = next;
    if (error != null) _lastError = error;
    if (next == LibrarySyncStatus.idle) {
      _lastSyncedAt = DateTime.now();
      _lastError = null;
    }
    if (!_statusController.isClosed) _statusController.add(next);
  }

  /// Subscribe to the local write callback + auth-state stream. Also
  /// kicks an initial pull if the user is already signed in (cold-start
  /// after killing the app).
  Future<void> start() async {
    if (_started) return;
    _started = true;
    _library.onLocalWrite = _kickDebounce;
    _readChapters.onLocalWrite = _kickDebounce;
    _authSub = _auth.authStream.listen((event) {
      if (event == AuthChangeEvent.signedIn ||
          event == AuthChangeEvent.tokenRefreshed) {
        // ignore: unawaited_futures
        pullAll().then((_) => flush());
      }
    });
    if (_auth.isSignedIn) {
      // Fire-and-forget — bootstrap shouldn't block on the network.
      // ignore: unawaited_futures
      pullAll().then((_) => flush());
    }
  }

  /// Cancel subscriptions + cancel any pending debounce. Called from
  /// [AuthService.signOut] so we don't push the previous account's
  /// pending writes under the next account's session.
  Future<void> stop() async {
    _started = false;
    _library.onLocalWrite = null;
    _readChapters.onLocalWrite = null;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    await _authSub?.cancel();
    _authSub = null;
  }

  void _kickDebounce() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounce, () {
      // ignore: unawaited_futures
      flush();
    });
  }

  /// Push every dirty entry + every tombstone to Supabase, then ack them.
  /// Safe to call concurrently — the first call wins and subsequent calls
  /// no-op until it finishes.
  Future<void> flush() async {
    if (_flushing) return;
    final client = _client;
    final userId = _auth.currentUser?.id;
    if (client == null || userId == null) return; // not signed in
    _flushing = true;
    // Only flip to syncing if we actually have something to push — avoids
    // a "syncing…" flash when the debounce timer fires after a no-op.
    final hasWork = _library.dirtyKeys().isNotEmpty ||
        _library.tombstones().isNotEmpty ||
        _readChapters.dirtyKeys().isNotEmpty ||
        _readChapters.tombstones().isNotEmpty;
    if (hasWork) _setStatus(LibrarySyncStatus.syncing);
    try {
      await _pushDirty(client, userId);
      await _pushTombstones(client, userId);
      await _pushReadDirty(client, userId);
      await _pushReadTombstones(client, userId);
      if (hasWork) _setStatus(LibrarySyncStatus.idle);
    } catch (e, st) {
      debugPrint('[sync] flush failed: $e\n$st');
      _setStatus(LibrarySyncStatus.error, error: e.toString());
    } finally {
      _flushing = false;
    }
  }

  Future<void> _pushDirty(SupabaseClient client, String userId) async {
    final dirty = _library.dirtyKeys();
    if (dirty.isEmpty) return;
    final tombstones = _library.tombstones();
    final rows = <Map<String, dynamic>>[];
    final pushed = <String>[];
    for (final key in dirty.keys) {
      // If a tombstone exists for this key, the delete wins — skip the
      // upsert and let _pushTombstones handle it.
      if (tombstones.containsKey(key)) continue;
      final entry = _readByKey(key);
      if (entry == null) continue;
      rows.add(_toRow(entry, userId));
      pushed.add(key);
    }
    if (rows.isEmpty) return;
    debugPrint('[sync] pushing ${rows.length} dirty entries');
    await client.from(_table).upsert(rows);
    await _library.ackDirty(pushed);
  }

  Future<void> _pushTombstones(SupabaseClient client, String userId) async {
    final tombstones = _library.tombstones();
    if (tombstones.isEmpty) return;
    final acks = <String>[];
    for (final key in tombstones.keys) {
      final parts = key.split('::');
      if (parts.length < 2) {
        acks.add(key); // malformed — drop it
        continue;
      }
      final sourceId = parts[0];
      final bookId = parts.sublist(1).join('::');
      try {
        await client
            .from(_table)
            .delete()
            .eq('user_id', userId)
            .eq('source_id', sourceId)
            .eq('book_id', bookId);
        acks.add(key);
      } catch (e) {
        debugPrint('[sync] delete failed for $key: $e');
      }
    }
    await _library.ackTombstones(acks);
  }

  // -- read_chapters push --------------------------------------------------

  Future<void> _pushReadDirty(SupabaseClient client, String userId) async {
    final dirty = _readChapters.dirtyKeys();
    if (dirty.isEmpty) return;
    final tombstones = _readChapters.tombstones();
    final rows = <Map<String, dynamic>>[];
    final pushed = <String>[];
    for (final entry in dirty.entries) {
      final key = entry.key;
      // Tombstone wins — let _pushReadTombstones handle the delete.
      if (tombstones.containsKey(key)) continue;
      final parts = key.split('::');
      if (parts.length < 3) {
        pushed.add(key); // malformed — drop the dirty flag
        continue;
      }
      final sourceId = parts[0];
      final bookId = parts[1];
      final chapterId = parts.sublist(2).join('::');
      final readAt = DateTime.tryParse(entry.value) ?? DateTime.now();
      rows.add({
        'user_id': userId,
        'source_id': sourceId,
        'book_id': bookId,
        'chapter_id': chapterId,
        'read_at': readAt.toIso8601String(),
      });
      pushed.add(key);
    }
    if (rows.isEmpty) {
      if (pushed.isNotEmpty) await _readChapters.ackDirty(pushed);
      return;
    }
    debugPrint('[sync] pushing ${rows.length} read_chapters rows');
    try {
      await client.from(_readChaptersTable).upsert(rows);
      await _readChapters.ackDirty(pushed);
    } catch (e) {
      debugPrint('[sync] read_chapters upsert failed: $e');
    }
  }

  Future<void> _pushReadTombstones(SupabaseClient client, String userId) async {
    final tombstones = _readChapters.tombstones();
    if (tombstones.isEmpty) return;
    final acks = <String>[];
    for (final key in tombstones.keys) {
      final parts = key.split('::');
      if (parts.length < 3) {
        acks.add(key); // malformed — drop it
        continue;
      }
      final sourceId = parts[0];
      final bookId = parts[1];
      final chapterId = parts.sublist(2).join('::');
      try {
        await client
            .from(_readChaptersTable)
            .delete()
            .eq('user_id', userId)
            .eq('source_id', sourceId)
            .eq('book_id', bookId)
            .eq('chapter_id', chapterId);
        acks.add(key);
      } catch (e) {
        debugPrint('[sync] read_chapters delete failed for $key: $e');
      }
    }
    await _readChapters.ackTombstones(acks);
  }

  /// Fetch every row for the current user and merge into Hive by
  /// `updated_at`. The local row wins iff its `updatedAt` is strictly
  /// newer than the cloud's (otherwise cloud wins). Tombstones with
  /// `deletedAt > cloud.updated_at` cause us to delete the cloud row on
  /// the next flush; the inverse (cloud newer than tombstone) resurrects
  /// the row locally.
  Future<void> pullAll() async {
    final client = _client;
    final userId = _auth.currentUser?.id;
    if (client == null || userId == null) return;
    _setStatus(LibrarySyncStatus.syncing);
    var hadError = false;
    try {
      final rows = await client
          .from(_table)
          .select()
          .eq('user_id', userId)
          .order('updated_at', ascending: false)
          .limit(500);
      debugPrint('[sync] pulled ${rows.length} rows');
      final tombstones = _library.tombstones();
      final dirty = _library.dirtyKeys();
      for (final raw in rows) {
        final row = Map<String, dynamic>.from(raw as Map);
        final cloud = _fromRow(row);
        if (cloud == null) continue;
        final key = cloud.key;
        // Tombstone older than cloud → user wants delete; let push handle.
        // Tombstone newer than cloud → user resurrected → drop the
        // tombstone and accept the cloud row.
        final tomb = tombstones[key];
        if (tomb != null) {
          final tombAt = DateTime.tryParse(tomb);
          if (tombAt != null && cloud.updatedAt.isAfter(tombAt)) {
            await _library.ackTombstones([key]);
          } else {
            continue; // delete will be flushed
          }
        }
        // Local dirty entry that's newer than cloud → keep local.
        final localDirty = dirty[key];
        if (localDirty != null) {
          final localAt = DateTime.tryParse(localDirty);
          if (localAt != null && localAt.isAfter(cloud.updatedAt)) continue;
        }
        // Local non-dirty row that's somehow newer (clock skew, manual
        // edit) — still let cloud win as the canonical "latest writer".
        await _library.putFromSync(cloud);
      }
    } catch (e, st) {
      debugPrint('[sync] pullAll failed: $e\n$st');
      hadError = true;
      _setStatus(LibrarySyncStatus.error, error: e.toString());
    }
    try {
      await _pullReadChapters(client, userId);
    } catch (e) {
      debugPrint('[sync] pullReadChapters failed: $e');
      hadError = true;
      _setStatus(LibrarySyncStatus.error, error: e.toString());
    }
    if (!hadError) _setStatus(LibrarySyncStatus.idle);
  }

  /// Pull every `read_chapters` row for the user. Read marks are
  /// append-only, so the only real conflict is "user un-marked locally
  /// after the cloud row was written" — resolved by comparing the
  /// tombstone's deletedAt against the cloud's readAt.
  Future<void> _pullReadChapters(SupabaseClient client, String userId) async {
    try {
      final rows = await client
          .from(_readChaptersTable)
          .select()
          .eq('user_id', userId)
          .order('read_at', ascending: false)
          .limit(2000);
      debugPrint('[sync] pulled ${rows.length} read_chapters rows');
      final tombstones = _readChapters.tombstones();
      for (final raw in rows) {
        final row = Map<String, dynamic>.from(raw as Map);
        final cloud = _readChapterFromRow(row);
        if (cloud == null) continue;
        final key = cloud.key;
        final tomb = tombstones[key];
        if (tomb != null) {
          final tombAt = DateTime.tryParse(tomb);
          // Cloud newer than tombstone → user re-read on another device,
          // accept it. Otherwise keep the tombstone so the delete gets
          // pushed.
          if (tombAt != null && cloud.readAt.isAfter(tombAt)) {
            await _readChapters.ackTombstones([key]);
          } else {
            continue;
          }
        }
        await _readChapters.putFromSync(cloud);
      }
    } catch (e, st) {
      debugPrint('[sync] read_chapters pull failed: $e\n$st');
    }
  }

  /// Pull-to-refresh entry point. Pulls then immediately flushes any
  /// queued local writes.
  Future<void> refresh() async {
    await pullAll();
    await flush();
  }

  // ---------------------------------------------------------------------
  // Serialization
  // ---------------------------------------------------------------------

  Map<String, dynamic> _toRow(LibraryEntry e, String userId) => {
        'user_id': userId,
        'source_id': e.book.sourceId,
        'book_id': e.book.id,
        'book_json': e.book.toJson(),
        'status': e.status.name,
        'added_at': e.addedAt.toIso8601String(),
        'updated_at': e.updatedAt.toIso8601String(),
        'last_chapter_index': e.lastChapterIndex,
        'last_chapter_progress': e.lastChapterProgress,
      };

  LibraryEntry? _fromRow(Map<String, dynamic> row) {
    try {
      final bookJson = Map<String, dynamic>.from(row['book_json'] as Map);
      final book = BookItem.fromJson(bookJson);
      final status = LibraryStatus.values.firstWhere(
        (s) => s.name == row['status'],
        orElse: () => LibraryStatus.reading,
      );
      return LibraryEntry(
        book: book,
        status: status,
        addedAt: DateTime.parse(row['added_at'] as String),
        updatedAt: DateTime.parse(row['updated_at'] as String),
        lastChapterIndex: (row['last_chapter_index'] as int?) ?? 0,
        lastChapterProgress:
            (row['last_chapter_progress'] as num?)?.toDouble(),
      );
    } catch (e) {
      debugPrint('[sync] failed to parse row: $e ($row)');
      return null;
    }
  }

  LibraryEntry? _readByKey(String key) {
    final parts = key.split('::');
    if (parts.length < 2) return null;
    final sourceId = parts[0];
    final bookId = parts.sublist(1).join('::');
    return _library.get(sourceId, bookId);
  }

  ReadChapter? _readChapterFromRow(Map<String, dynamic> row) {
    try {
      return ReadChapter(
        sourceId: row['source_id'] as String,
        bookId: row['book_id'] as String,
        chapterId: row['chapter_id'] as String,
        readAt: DateTime.parse(row['read_at'] as String),
      );
    } catch (e) {
      debugPrint('[sync] failed to parse read_chapters row: $e ($row)');
      return null;
    }
  }
}
