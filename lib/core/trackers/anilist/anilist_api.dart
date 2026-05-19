import 'package:dio/dio.dart';

import '../tracker_entry.dart';
import 'anilist_auth.dart';

/// Raised when the AniList GraphQL endpoint returns a transport-level or
/// `errors`-payload failure, or when the response shape is unexpected.
class AniListException implements Exception {
  AniListException(this.message);
  final String message;

  @override
  String toString() => 'AniListException: $message';
}

/// Thin GraphQL client over Dio targeting `https://graphql.anilist.co`.
///
/// All public methods return parsed Dart objects (never raw JSON) and throw
/// [AniListException] on failure. The authenticated user's `id` is cached
/// after the first successful [fetchViewer] call so subsequent operations
/// that need a `userId` don't re-roundtrip.
class AniListApi {
  AniListApi({required this.dio, required this.auth});

  final Dio dio;
  final AniListAuth auth;

  static const String _endpoint = 'https://graphql.anilist.co';

  int? _cachedViewerId;

  /// Returns the authenticated viewer (id, display name, avatar URL) or
  /// `null` when there's no cached token / the request is unauthenticated.
  ///
  /// Caches the viewer's `id` for subsequent userId-keyed queries.
  Future<({int id, String name, String? avatar})?> fetchViewer() async {
    final token = await auth.readToken();
    if (token == null || token.isEmpty) return null;

    const query = 'query { Viewer { id name avatar { medium } } }';

    try {
      final data = await _query(query, const {});
      final viewer = data['Viewer'] as Map<String, dynamic>?;
      if (viewer == null) return null;

      final id = viewer['id'] as int;
      final name = viewer['name'] as String;
      final avatar =
          (viewer['avatar'] as Map<String, dynamic>?)?['medium'] as String?;

      _cachedViewerId = id;
      return (id: id, name: name, avatar: avatar);
    } on AniListException {
      // Most likely an invalid/expired token — bubble up `null` so callers
      // treat the user as logged out.
      return null;
    }
  }

  /// Search AniList for manga matching [title], up to 15 results.
  ///
  /// Each result's `status` / `progress` / `score` reflect the
  /// authenticated user's existing entry on their list (`mediaListEntry`),
  /// or sensible defaults when the series isn't on their list yet.
  Future<List<TrackerEntry>> searchManga(String title) async {
    const query = r'''
      query ($search: String) {
        Page(perPage: 15) {
          media(search: $search, type: MANGA) {
            id
            title { romaji english native }
            coverImage { medium }
            chapters
            status
            mediaListEntry {
              status
              progress
              score(format: POINT_10_DECIMAL)
              updatedAt
            }
          }
        }
      }
    ''';

    final data = await _query(query, {'search': title});
    final page = data['Page'] as Map<String, dynamic>?;
    final media = page?['media'] as List<dynamic>? ?? const [];

    return media
        .whereType<Map<String, dynamic>>()
        .map(_mediaToEntry)
        .toList(growable: false);
  }

  /// Returns the user's list entry for [mediaId], or `null` if the series
  /// isn't on their list. Requires a logged-in viewer.
  Future<TrackerEntry?> fetchMediaListEntry(int mediaId) async {
    final userId = await _resolveViewerId();
    if (userId == null) return null;

    const query = r'''
      query ($mediaId: Int, $userId: Int) {
        MediaList(mediaId: $mediaId, userId: $userId) {
          status
          progress
          score(format: POINT_10_DECIMAL)
          updatedAt
          media {
            id
            title { romaji english native }
            coverImage { medium }
            chapters
            status
          }
        }
      }
    ''';

    try {
      final data = await _query(query, {'mediaId': mediaId, 'userId': userId});
      final entry = data['MediaList'] as Map<String, dynamic>?;
      if (entry == null) return null;
      return _mediaListToEntry(entry);
    } on AniListException {
      // AniList returns an error (not null) when the user has no entry for
      // this media — treat that as "not on list".
      return null;
    }
  }

  /// Upserts the authenticated user's list entry for [mediaId]. Only the
  /// non-null parameters are sent to AniList; everything else is left
  /// unchanged server-side.
  Future<void> saveMediaListEntry({
    required int mediaId,
    int? progress,
    TrackerStatus? status,
    double? score,
  }) async {
    const mutation = r'''
      mutation (
        $mediaId: Int,
        $status: MediaListStatus,
        $progress: Int,
        $score: Float
      ) {
        SaveMediaListEntry(
          mediaId: $mediaId,
          status: $status,
          progress: $progress,
          score: $score
        ) {
          id
        }
      }
    ''';

    final variables = <String, dynamic>{'mediaId': mediaId};
    if (status != null) variables['status'] = _statusToRemote(status);
    if (progress != null) variables['progress'] = progress;
    // Score is sent as the user's 0–10 value (matches what we read back via
    // POINT_10_DECIMAL). AniList stores it in the user's preferred format.
    if (score != null) variables['score'] = score;

    await _query(mutation, variables);
  }

  /// Returns the authenticated user's full manga list across every status
  /// bucket, flattened. Requires a logged-in viewer.
  Future<List<TrackerEntry>> fetchUserMangaList() async {
    final userId = await _resolveViewerId();
    if (userId == null) return const [];

    const query = r'''
      query ($userId: Int) {
        MediaListCollection(userId: $userId, type: MANGA) {
          lists {
            entries {
              status
              progress
              score(format: POINT_10_DECIMAL)
              updatedAt
              media {
                id
                title { romaji english native }
                coverImage { medium }
                chapters
              }
            }
          }
        }
      }
    ''';

    final data = await _query(query, {'userId': userId});
    final collection = data['MediaListCollection'] as Map<String, dynamic>?;
    final lists = collection?['lists'] as List<dynamic>? ?? const [];

    final result = <TrackerEntry>[];
    for (final list in lists.whereType<Map<String, dynamic>>()) {
      final entries = list['entries'] as List<dynamic>? ?? const [];
      for (final entry in entries.whereType<Map<String, dynamic>>()) {
        result.add(_mediaListToEntry(entry));
      }
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  /// Returns the cached viewer id, fetching the viewer once if needed.
  /// `null` when no token is available or the lookup fails.
  Future<int?> _resolveViewerId() async {
    final cached = _cachedViewerId;
    if (cached != null) return cached;
    final viewer = await fetchViewer();
    return viewer?.id;
  }

  /// POSTs the GraphQL `query` + `variables` to AniList and returns the
  /// `data` field of the response. Attaches `Authorization: Bearer <token>`
  /// when a token is cached. Throws [AniListException] on HTTP errors,
  /// GraphQL `errors`, or malformed responses.
  Future<Map<String, dynamic>> _query(
    String query,
    Map<String, dynamic> variables,
  ) async {
    final token = await auth.readToken();
    final headers = <String, dynamic>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      if (token != null && token.isNotEmpty)
        'Authorization': 'Bearer $token',
    };

    try {
      final response = await dio.post<Map<String, dynamic>>(
        _endpoint,
        data: {'query': query, 'variables': variables},
        options: Options(
          headers: headers,
          responseType: ResponseType.json,
        ),
      );

      final body = response.data;
      if (body == null) {
        throw AniListException('Empty response from AniList');
      }

      final errors = body['errors'] as List<dynamic>?;
      if (errors != null && errors.isNotEmpty) {
        final first = errors.first;
        final message = first is Map<String, dynamic>
            ? (first['message'] as String? ?? 'Unknown GraphQL error')
            : first.toString();
        throw AniListException(message);
      }

      final data = body['data'] as Map<String, dynamic>?;
      if (data == null) {
        throw AniListException('AniList response has no `data` field');
      }
      return data;
    } on DioException catch (e) {
      throw AniListException(
        'HTTP ${e.response?.statusCode ?? '?'}: ${e.message ?? e.toString()}',
      );
    }
  }

  /// Maps an AniList `Media { ... mediaListEntry }` shape — used by search —
  /// into a [TrackerEntry]. The user's existing list state populates the
  /// status/progress/score; defaults are used otherwise.
  TrackerEntry _mediaToEntry(Map<String, dynamic> media) {
    final id = media['id'] as int;
    final title = _pickTitle(media['title'] as Map<String, dynamic>?);
    final cover =
        (media['coverImage'] as Map<String, dynamic>?)?['medium'] as String?;
    final chapters = media['chapters'] as int? ?? 0;
    final seriesStatus = _seriesStatusFromRemote(media['status'] as String?);

    final listEntry = media['mediaListEntry'] as Map<String, dynamic>?;

    var status = TrackerStatus.planToRead;
    var progress = 0;
    double? score;
    DateTime? updatedAt;

    if (listEntry != null) {
      status = _statusFromRemote(listEntry['status'] as String?);
      progress = listEntry['progress'] as int? ?? 0;
      final rawScore = listEntry['score'];
      if (rawScore is num && rawScore > 0) score = rawScore.toDouble();
      final ts = listEntry['updatedAt'];
      if (ts is int && ts > 0) {
        updatedAt = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
      }
    }

    return TrackerEntry(
      trackerId: 'anilist',
      remoteId: id,
      title: title,
      coverUrl: cover,
      status: status,
      progress: progress,
      totalChapters: chapters,
      score: score,
      updatedAt: updatedAt,
      seriesStatus: seriesStatus,
    );
  }

  /// Maps an AniList `MediaList { ..., media { ... } }` shape — used by
  /// fetch-entry and the full-list query — into a [TrackerEntry].
  TrackerEntry _mediaListToEntry(Map<String, dynamic> entry) {
    final media = entry['media'] as Map<String, dynamic>? ?? const {};
    final id = media['id'] as int;
    final title = _pickTitle(media['title'] as Map<String, dynamic>?);
    final cover =
        (media['coverImage'] as Map<String, dynamic>?)?['medium'] as String?;
    final chapters = media['chapters'] as int? ?? 0;
    final seriesStatus = _seriesStatusFromRemote(media['status'] as String?);

    final status = _statusFromRemote(entry['status'] as String?);
    final progress = entry['progress'] as int? ?? 0;

    double? score;
    final rawScore = entry['score'];
    if (rawScore is num && rawScore > 0) score = rawScore.toDouble();

    DateTime? updatedAt;
    final ts = entry['updatedAt'];
    if (ts is int && ts > 0) {
      updatedAt = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
    }

    return TrackerEntry(
      trackerId: 'anilist',
      remoteId: id,
      title: title,
      coverUrl: cover,
      status: status,
      progress: progress,
      totalChapters: chapters,
      score: score,
      updatedAt: updatedAt,
      seriesStatus: seriesStatus,
    );
  }

  /// Maps AniList's `MediaStatus` enum into our internal release status.
  SeriesReleaseStatus _seriesStatusFromRemote(String? raw) {
    switch (raw) {
      case 'FINISHED':
        return SeriesReleaseStatus.finished;
      case 'RELEASING':
        return SeriesReleaseStatus.releasing;
      case 'NOT_YET_RELEASED':
        return SeriesReleaseStatus.notYetReleased;
      case 'CANCELLED':
        return SeriesReleaseStatus.cancelled;
      case 'HIATUS':
        return SeriesReleaseStatus.hiatus;
      default:
        return SeriesReleaseStatus.unknown;
    }
  }

  /// Picks the best-available human-readable title from AniList's
  /// `{ romaji, english, native }` block, preferring english.
  String _pickTitle(Map<String, dynamic>? title) {
    if (title == null) return '';
    final english = title['english'] as String?;
    if (english != null && english.isNotEmpty) return english;
    final romaji = title['romaji'] as String?;
    if (romaji != null && romaji.isNotEmpty) return romaji;
    final native = title['native'] as String?;
    if (native != null && native.isNotEmpty) return native;
    return '';
  }

  /// Maps a [TrackerStatus] to AniList's `MediaListStatus` enum string.
  String _statusToRemote(TrackerStatus status) {
    switch (status) {
      case TrackerStatus.reading:
        return 'CURRENT';
      case TrackerStatus.planToRead:
        return 'PLANNING';
      case TrackerStatus.completed:
        return 'COMPLETED';
      case TrackerStatus.onHold:
        return 'PAUSED';
      case TrackerStatus.dropped:
        return 'DROPPED';
      case TrackerStatus.rereading:
        return 'REPEATING';
    }
  }

  /// Maps an AniList `MediaListStatus` enum string back into a
  /// [TrackerStatus]. Defaults to [TrackerStatus.planToRead] for null or
  /// unrecognised values.
  TrackerStatus _statusFromRemote(String? remote) {
    switch (remote) {
      case 'CURRENT':
        return TrackerStatus.reading;
      case 'PLANNING':
        return TrackerStatus.planToRead;
      case 'COMPLETED':
        return TrackerStatus.completed;
      case 'PAUSED':
        return TrackerStatus.onHold;
      case 'DROPPED':
        return TrackerStatus.dropped;
      case 'REPEATING':
        return TrackerStatus.rereading;
      default:
        return TrackerStatus.planToRead;
    }
  }
}
