// MangaDex provider — uses the official MangaDex REST API (no scraping).
// Docs: https://api.mangadex.org/docs/

var SOURCE_ID = 'mangadex';
var API = 'https://api.mangadex.org';
var COVER_BASE = 'https://uploads.mangadex.org/covers';
var SITE = 'https://mangadex.org';
var LANG = 'en';

function getInfo() {
  return {
    name: 'MangaDex',
    lang: LANG,
    baseUrl: SITE,
    logo: 'https://mangadex.org/img/brand/mangadex-logo.svg',
    type: 'manga',
    version: '1.0.0'
  };
}

function _coverUrl(mangaId, fileName) {
  if (!fileName) return null;
  return COVER_BASE + '/' + mangaId + '/' + fileName + '.512.jpg';
}

function _findCover(manga) {
  if (!manga.relationships) return null;
  for (var i = 0; i < manga.relationships.length; i++) {
    var rel = manga.relationships[i];
    if (rel.type === 'cover_art' && rel.attributes && rel.attributes.fileName) {
      return _coverUrl(manga.id, rel.attributes.fileName);
    }
  }
  return null;
}

function _findAuthors(manga) {
  if (!manga.relationships) return [];
  var out = [];
  for (var i = 0; i < manga.relationships.length; i++) {
    var rel = manga.relationships[i];
    if ((rel.type === 'author' || rel.type === 'artist') && rel.attributes && rel.attributes.name) {
      if (out.indexOf(rel.attributes.name) === -1) out.push(rel.attributes.name);
    }
  }
  return out;
}

function _localized(obj) {
  if (!obj) return '';
  if (obj[LANG]) return obj[LANG];
  if (obj.en) return obj.en;
  for (var k in obj) {
    if (obj.hasOwnProperty(k)) return obj[k];
  }
  return '';
}

function _statusOf(s) {
  if (!s) return 'unknown';
  s = String(s).toLowerCase();
  if (s === 'ongoing') return 'ongoing';
  if (s === 'completed') return 'completed';
  if (s === 'hiatus') return 'hiatus';
  if (s === 'cancelled') return 'cancelled';
  return 'unknown';
}

function _mangaUrl(id) {
  return SITE + '/title/' + id;
}

function _toBookItem(manga) {
  return {
    id: manga.id,
    title: _localized(manga.attributes && manga.attributes.title),
    cover: _findCover(manga),
    url: _mangaUrl(manga.id),
    type: 'manga'
  };
}

function search(query, page) {
  page = page || 1;
  var limit = 20;
  var offset = (page - 1) * limit;
  var hasQuery = query && String(query).trim().length > 0;
  var params = [
    'limit=' + limit,
    'offset=' + offset,
    'includes%5B%5D=cover_art',
    'includes%5B%5D=author',
    'includes%5B%5D=artist',
    'availableTranslatedLanguage%5B%5D=' + LANG,
    'contentRating%5B%5D=safe',
    'contentRating%5B%5D=suggestive',
    'hasAvailableChapters=true'
  ];
  if (hasQuery) {
    params.push('order%5Brelevance%5D=desc');
    params.push('title=' + encodeURIComponent(String(query).trim()));
  } else {
    // No query => browse "popular" — but filter to Japanese-origin manga.
    // Korean manhwa (Solo Leveling, etc.) dominate MangaDex's followedCount
    // ranking but are licensed, so their chapters have no images. Filtering
    // by originalLanguage=ja yields titles that are usually fully hosted.
    params.push('order%5BfollowedCount%5D=desc');
    params.push('originalLanguage%5B%5D=ja');
  }
  var url = API + '/manga?' + params.join('&');
  console.log('mangadex search url: ' + url);
  return fetch(url).then(function(res) {
    console.log('mangadex search status: ' + res.status + ' bodyLen: ' + (res.body || '').length);
    if (!res.body) return [];
    var json;
    try { json = JSON.parse(res.body); }
    catch (e) { console.error('JSON parse failed: ' + e + ' first200=' + res.body.substring(0, 200)); return []; }
    console.log('mangadex search result count: ' + (json.data ? json.data.length : 'no data') + ' total: ' + json.total);
    if (!json || !json.data) return [];
    return json.data.map(_toBookItem);
  });
}

function _idFromUrl(url) {
  var m = String(url).match(/title\/([0-9a-f-]+)/i);
  return m ? m[1] : url;
}

function getDetail(url) {
  var id = _idFromUrl(url);
  var u = API + '/manga/' + id + '?includes[]=cover_art&includes[]=author&includes[]=artist';
  return fetch(u).then(function(r) { return r.json(); }).then(function(json) {
    if (!json || !json.data) throw new Error('manga not found');
    var manga = json.data;
    var attrs = manga.attributes || {};
    var genres = (attrs.tags || []).map(function(t) {
      return _localized(t.attributes && t.attributes.name);
    }).filter(Boolean);

    return getChapters(url).then(function(chapters) {
      return {
        id: manga.id,
        title: _localized(attrs.title),
        cover: _findCover(manga),
        url: _mangaUrl(manga.id),
        description: _localized(attrs.description),
        status: _statusOf(attrs.status),
        genres: genres,
        authors: _findAuthors(manga),
        chapters: chapters,
        type: 'manga'
      };
    });
  });
}

function _fetchChapterPage(mangaId, offset) {
  var params = [
    'limit=500',
    'offset=' + offset,
    'translatedLanguage%5B%5D=' + LANG,
    'order%5Bvolume%5D=desc',
    'order%5Bchapter%5D=desc',
    'includeFutureUpdates=0',
    'contentRating%5B%5D=safe',
    'contentRating%5B%5D=suggestive',
    'contentRating%5B%5D=erotica',
    'contentRating%5B%5D=pornographic'
  ];
  var u = API + '/manga/' + mangaId + '/feed?' + params.join('&');
  console.log('mangadex feed url: ' + u);
  return fetch(u).then(function(r) {
    console.log('mangadex feed status: ' + r.status + ' bodyLen: ' + (r.body || '').length);
    return JSON.parse(r.body || '{}');
  });
}

function getChapters(url) {
  var id = _idFromUrl(url);
  var all = [];
  function loop(offset) {
    return _fetchChapterPage(id, offset).then(function(json) {
      if (!json || !json.data) return all;
      for (var i = 0; i < json.data.length; i++) {
        var ch = json.data[i];
        var a = ch.attributes || {};
        var num = a.chapter ? parseFloat(a.chapter) : null;
        var titleParts = [];
        if (a.chapter) titleParts.push('Chapter ' + a.chapter);
        if (a.title) titleParts.push(a.title);
        all.push({
          id: ch.id,
          title: titleParts.join(' - ') || 'Oneshot',
          number: isNaN(num) ? null : num,
          url: SITE + '/chapter/' + ch.id,
          date: a.publishAt || a.readableAt || null
        });
      }
      var total = json.total || all.length;
      var nextOffset = offset + json.data.length;
      if (json.data.length === 0 || nextOffset >= total) return all;
      return loop(nextOffset);
    });
  }
  return loop(0);
}

function _chapterIdFromUrl(url) {
  var m = String(url).match(/chapter\/([0-9a-f-]+)/i);
  return m ? m[1] : url;
}

function getPages(chapterUrl) {
  var id = _chapterIdFromUrl(chapterUrl);
  var u = API + '/at-home/server/' + id;
  console.log('mangadex pages url: ' + u);
  return fetch(u).then(function(r) {
    console.log('mangadex pages status: ' + r.status);
    if (r.status === 404) throw new Error('Chapter not hosted on MangaDex (external/licensed)');
    var json;
    try { json = JSON.parse(r.body || '{}'); }
    catch (e) { throw new Error('Bad at-home JSON: ' + (r.body || '').substring(0, 200)); }
    if (!json.chapter) throw new Error('No pages in response: ' + JSON.stringify(json).substring(0, 200));
    var base = json.baseUrl;
    var hash = json.chapter.hash;
    var files = json.chapter.data || [];
    var folder = 'data';
    // Some chapters (e.g. licensed teasers) only have dataSaver entries.
    if ((!files || files.length === 0) && json.chapter.dataSaver && json.chapter.dataSaver.length > 0) {
      files = json.chapter.dataSaver;
      folder = 'data-saver';
      console.log('mangadex pages: using dataSaver fallback');
    }
    if (!files || files.length === 0) {
      throw new Error('Chapter has no images (licensed/external on MangaDex)');
    }
    return files.map(function(f, i) {
      return {
        url: base + '/' + folder + '/' + hash + '/' + f,
        index: i,
        headers: { 'Referer': SITE + '/' }
      };
    });
  });
}

function getChapterContent(chapterUrl) {
  return { text: 'MangaDex is a manga-only source.', nextUrl: null };
}
