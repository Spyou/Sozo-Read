import 'package:dio/dio.dart';

import '../tracker_entry.dart';
import 'mal_auth.dart';

class MalApiException implements Exception {
  MalApiException(this.message);
  final String message;
  @override
  String toString() => 'MalApiException: $message';
}

/// Thin REST client over the MAL v2 API. Every authenticated call goes
/// through [_get] / [_patch] which transparently refreshes the access
/// token via [MalAuth.ensureValidAccessToken] before hitting the wire.
class MalApi {
  MalApi({required this.dio, required this.auth});

  final Dio dio;
  final MalAuth auth;

  static const String _base = 'https://api.myanimelist.net/v2';

  // ------------------------------------------------------------------
  // Public surface (mirrors AniListApi as closely as the MAL endpoints
  // allow so the [Tracker] facade above us can dispatch uniformly).
  // ------------------------------------------------------------------

  /// Returns the authenticated viewer or `null` if unauthenticated.
  Future<({int id, String name, String? avatar})?> fetchViewer() async {
    final token = await auth.ensureValidAccessToken();
    if (token == null) return null;
    try {
      final data = await _get('/users/@me', token, query: {
        'fields': 'name,picture',
      });
      final id = data['id'];
      final name = data['name'];
      if (id is! int || name is! String) return null;
      final avatar = data['picture'] as String?;
      return (id: id, name: name, avatar: avatar);
    } on MalApiException {
      return null;
    }
  }

  /// Search MAL for manga matching [title], up to 15 results.
  Future<List<TrackerEntry>> searchManga(String title) async {
    final token = await auth.ensureValidAccessToken();
    if (token == null) return const [];
    final data = await _get('/manga', token, query: {
      'q': title,
      'limit': '15',
      // `nsfw=true` returns adult-tagged series in search results. Without
      // this MAL silently filters them, so any ecchi/adult manga the user
      // is reading would auto-match on AniList but never on MAL.
      'nsfw': 'true',
      'fields': 'id,title,alternative_titles,main_picture,num_chapters,status,my_list_status',
    });
    final items = data['data'] as List<dynamic>? ?? const [];
    return items
        .whereType<Map<String, dynamic>>()
        .map((wrap) => wrap['node'] as Map<String, dynamic>?)
        .whereType<Map<String, dynamic>>()
        .map(_nodeToEntry)
        .toList(growable: false);
  }

  /// Returns the user's list entry for [mediaId], or `null` if not on
  /// their list. We pull the manga details (incl. `my_list_status`) and
  /// map missing list status to "not on list".
  Future<TrackerEntry?> fetchMediaListEntry(int mediaId) async {
    final token = await auth.ensureValidAccessToken();
    if (token == null) return null;
    try {
      final data = await _get('/manga/$mediaId', token, query: {
        'fields': 'id,title,alternative_titles,main_picture,num_chapters,status,my_list_status',
      });
      if (data['my_list_status'] == null) return null;
      return _nodeToEntry(data);
    } on MalApiException {
      return null;
    }
  }

  /// Upserts the authenticated user's list entry for [mediaId]. Only
  /// the non-null fields are sent. PATCHing the my_list_status endpoint
  /// auto-creates the entry if the user doesn't have one yet.
  Future<void> saveMediaListEntry({
    required int mediaId,
    int? progress,
    TrackerStatus? status,
    double? score,
  }) async {
    final token = await auth.ensureValidAccessToken();
    if (token == null) {
      throw MalApiException('Not authenticated');
    }
    final body = <String, dynamic>{};
    if (status != null) {
      body['status'] = _statusToRemote(status);
      // MAL has no "rereading" bucket — it's represented as
      // `status: reading` + `is_rereading: true`.
      if (status == TrackerStatus.rereading) {
        body['is_rereading'] = true;
      } else if (status == TrackerStatus.reading) {
        // Make sure we don't leave a stale is_rereading flag from a
        // prior rereading state.
        body['is_rereading'] = false;
      }
    }
    if (progress != null) body['num_chapters_read'] = progress;
    if (score != null) {
      // MAL stores scores as integers 0..10 (no decimals). Round half-up.
      body['score'] = score.round().clamp(0, 10);
    }
    await _patch('/manga/$mediaId/my_list_status', token, body: body);
  }

  /// Returns the full manga list across every status bucket.
  Future<List<TrackerEntry>> fetchUserMangaList() async {
    final token = await auth.ensureValidAccessToken();
    if (token == null) return const [];
    final out = <TrackerEntry>[];
    String? path = '/users/@me/mangalist';
    var query = <String, String>{
      'fields': 'list_status,num_chapters,status',
      'limit': '100',
      'nsfw': 'true',
    };
    // MAL pages via a `next` URL on each response; we walk it until
    // there are no more pages.
    while (path != null) {
      final data = await _get(path, token, query: query);
      final items = data['data'] as List<dynamic>? ?? const [];
      for (final wrap in items.whereType<Map<String, dynamic>>()) {
        final node = wrap['node'] as Map<String, dynamic>?;
        final listStatus = wrap['list_status'] as Map<String, dynamic>?;
        if (node == null) continue;
        // Inject the user's list status into the node so [_nodeToEntry]
        // can re-use the same mapping it does for search results.
        node['my_list_status'] = listStatus;
        out.add(_nodeToEntry(node));
      }
      final paging = data['paging'] as Map<String, dynamic>?;
      final next = paging?['next'] as String?;
      if (next == null) break;
      // `next` is an absolute URL; strip the base + query and pass the
      // path back into _get. The query string carries the cursor.
      final nextUri = Uri.parse(next);
      path = nextUri.path.replaceFirst('/v2', '');
      query = nextUri.queryParameters
          .map((k, v) => MapEntry(k, v.toString()));
    }
    return out;
  }

  // ------------------------------------------------------------------
  // Mapping helpers
  // ------------------------------------------------------------------

  /// Converts a `node` (search) or `manga/{id}` (detail) JSON blob into
  /// our internal [TrackerEntry]. Both shapes contain the same keys
  /// (id/title/main_picture/num_chapters/status[/my_list_status]).
  ///
  /// Title preference: `alternative_titles.en` > `title` (which is
  /// typically the Japanese romaji). MAL exposes only one canonical
  /// `title` field, so without the English alt the fuzzy matcher would
  /// miss any series with very different EN/JP names (Frieren vs
  /// Sousou no Frieren, Spy × Family vs Spy Family, etc).
  TrackerEntry _nodeToEntry(Map<String, dynamic> node) {
    final id = node['id'] as int;
    final altTitles = node['alternative_titles'] as Map<String, dynamic>?;
    final altEn = altTitles?['en'] as String?;
    final canonical = node['title'] as String? ?? '';
    final title = (altEn != null && altEn.trim().isNotEmpty)
        ? altEn.trim()
        : canonical;
    final picture = node['main_picture'] as Map<String, dynamic>?;
    final cover = picture?['medium'] as String? ?? picture?['large'] as String?;
    final chapters = node['num_chapters'] as int? ?? 0;
    final seriesStatus = _seriesStatusFromRemote(node['status'] as String?);

    final listStatus = node['my_list_status'] as Map<String, dynamic>?;
    var status = TrackerStatus.planToRead;
    var progress = 0;
    double? score;
    DateTime? updatedAt;
    if (listStatus != null) {
      final isRereading = listStatus['is_rereading'] as bool? ?? false;
      status = isRereading
          ? TrackerStatus.rereading
          : _statusFromRemote(listStatus['status'] as String?);
      progress = listStatus['num_chapters_read'] as int? ?? 0;
      final rawScore = listStatus['score'];
      if (rawScore is num && rawScore > 0) score = rawScore.toDouble();
      final ts = listStatus['updated_at'] as String?;
      if (ts != null) updatedAt = DateTime.tryParse(ts);
    }

    return TrackerEntry(
      trackerId: 'mal',
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

  String _statusToRemote(TrackerStatus s) {
    switch (s) {
      case TrackerStatus.reading:
      case TrackerStatus.rereading:
        return 'reading';
      case TrackerStatus.planToRead:
        return 'plan_to_read';
      case TrackerStatus.completed:
        return 'completed';
      case TrackerStatus.onHold:
        return 'on_hold';
      case TrackerStatus.dropped:
        return 'dropped';
    }
  }

  TrackerStatus _statusFromRemote(String? raw) {
    switch (raw) {
      case 'reading':
        return TrackerStatus.reading;
      case 'plan_to_read':
        return TrackerStatus.planToRead;
      case 'completed':
        return TrackerStatus.completed;
      case 'on_hold':
        return TrackerStatus.onHold;
      case 'dropped':
        return TrackerStatus.dropped;
      default:
        return TrackerStatus.planToRead;
    }
  }

  SeriesReleaseStatus _seriesStatusFromRemote(String? raw) {
    switch (raw) {
      case 'finished':
        return SeriesReleaseStatus.finished;
      case 'currently_publishing':
        return SeriesReleaseStatus.releasing;
      case 'not_yet_published':
        return SeriesReleaseStatus.notYetReleased;
      default:
        return SeriesReleaseStatus.unknown;
    }
  }

  // ------------------------------------------------------------------
  // HTTP transport
  // ------------------------------------------------------------------

  Future<Map<String, dynamic>> _get(
    String path,
    String token, {
    Map<String, String> query = const {},
  }) async {
    try {
      final response = await dio.get<Map<String, dynamic>>(
        '$_base$path',
        queryParameters: query,
        options: Options(
          headers: {'Authorization': 'Bearer $token'},
          responseType: ResponseType.json,
        ),
      );
      final body = response.data;
      if (body == null) throw MalApiException('Empty response');
      return body;
    } on DioException catch (e) {
      throw MalApiException(
        'HTTP ${e.response?.statusCode ?? '?'} on GET $path: '
        '${e.message ?? e.toString()}',
      );
    }
  }

  Future<Map<String, dynamic>> _patch(
    String path,
    String token, {
    Map<String, dynamic> body = const {},
  }) async {
    try {
      final response = await dio.patch<Map<String, dynamic>>(
        '$_base$path',
        // MAL's PATCH endpoints expect form-url-encoded bodies, NOT JSON.
        data: body,
        options: Options(
          headers: {'Authorization': 'Bearer $token'},
          contentType: Headers.formUrlEncodedContentType,
          responseType: ResponseType.json,
        ),
      );
      final res = response.data;
      if (res == null) throw MalApiException('Empty response');
      return res;
    } on DioException catch (e) {
      throw MalApiException(
        'HTTP ${e.response?.statusCode ?? '?'} on PATCH $path: '
        '${e.message ?? e.toString()}',
      );
    }
  }
}
