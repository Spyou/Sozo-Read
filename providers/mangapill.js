// Mangapill provider — https://mangapill.com
// Clean SSR-rendered pages: search results & chapter images both in HTML.

var SOURCE_ID = 'mangapill';
var SITE = 'https://mangapill.com';
var REFERER = SITE + '/';

function getInfo() {
  return {
    name: 'Mangapill',
    lang: 'en',
    baseUrl: SITE,
    logo: SITE + '/static/favicon.ico',
    type: 'manga',
    version: '1.0.0'
  };
}

function _allMatches(html, regex) {
  var out = [];
  var m; regex.lastIndex = 0;
  while ((m = regex.exec(html)) !== null) {
    out.push(m);
    if (m.index === regex.lastIndex) regex.lastIndex++;
  }
  return out;
}

function _clean(s) { return htmlText(s || '').replace(/\s+/g, ' ').trim(); }

function _statusOf(s) {
  s = (s || '').toLowerCase();
  if (s.indexOf('ongoing') !== -1 || s.indexOf('publishing') !== -1) return 'ongoing';
  if (s.indexOf('finished') !== -1 || s.indexOf('completed') !== -1) return 'completed';
  if (s.indexOf('hiatus') !== -1) return 'hiatus';
  if (s.indexOf('discontinued') !== -1 || s.indexOf('cancelled') !== -1) return 'cancelled';
  return 'unknown';
}

function search(query, page, category) {
  page = page || 1;
  category = category || '';
  var hasQuery = query && String(query).trim().length > 0;
  // Mangapill's /search needs a non-empty q for keyword searches; otherwise
  // hit category-specific browse pages.
  var url;
  if (hasQuery) {
    url = SITE + '/search?q=' + encodeURIComponent(String(query).trim()) + '&page=' + page;
  } else if (category === 'latest') {
    url = SITE + '/chapters';
  } else if (category === 'trending') {
    url = SITE + '/'; // Home page features trending in its hero rows.
  } else {
    url = SITE + '/'; // Default popular.
  }
  console.log('mangapill search url: ' + url);
  return fetch(url).then(function(r) {
    console.log('mangapill search status: ' + r.status + ' bodyLen: ' + (r.body || '').length);
    var html = r.body || '';
    var results = [];
    // Each result card has two <a> elements pointing at the same /manga/<id>
    // URL. The first wraps the cover <img>, the second wraps a clean
    // <div class="line-clamp-2">TITLE</div>. We capture title from the second.
    var re = /<a[^>]+href="(\/manga\/\d+\/[^"]+)"[^>]*>\s*<figure[\s\S]*?<img[^>]+(?:data-src|src)="([^"]+)"[\s\S]*?<a[^>]+href="\1"[^>]*>\s*<div[^>]+line-clamp-2[^>]*>([^<]+)<\/div>/g;
    var matches = _allMatches(html, re);
    var seen = {};
    for (var i = 0; i < matches.length; i++) {
      var link = matches[i][1];
      if (seen[link]) continue;
      seen[link] = true;
      var cover = matches[i][2];
      var title = _clean(matches[i][3]);
      var idMatch = link.match(/\/manga\/(\d+)/);
      var id = idMatch ? idMatch[1] : link;
      results.push({
        id: id,
        title: title,
        cover: cover,
        coverHeaders: { 'Referer': REFERER },
        url: SITE + link,
        type: 'manga'
      });
    }
    console.log('mangapill search count: ' + results.length);
    return results;
  });
}

function _parseChapters(html) {
  var out = [];
  var seen = {};
  // <a href="/chapters/<id>"><div>Chapter N - title</div></a>
  var re = /<a[^>]+href="(\/chapters\/[^"]+)"[^>]*>([\s\S]*?)<\/a>/g;
  var matches = _allMatches(html, re);
  for (var i = 0; i < matches.length; i++) {
    var link = matches[i][1];
    if (seen[link]) continue;
    seen[link] = true;
    var title = _clean(matches[i][2]);
    if (!/chapter|vol/i.test(title)) continue;
    var numMatch = title.match(/chapter\s*([0-9.]+)/i);
    var num = numMatch ? parseFloat(numMatch[1]) : null;
    out.push({
      id: link.replace(/\/chapters\//, ''),
      title: title,
      number: isNaN(num) ? null : num,
      url: SITE + link,
      date: ''
    });
  }
  return out;
}

function getDetail(url) {
  console.log('mangapill detail url: ' + url);
  return fetch(url).then(function(r) {
    var html = r.body || '';
    var titleM = html.match(/<h1[^>]*>([^<]+)<\/h1>/);
    var title = _clean(titleM ? titleM[1] : '');

    var coverM = html.match(/<img[^>]+src="(https?:\/\/[^"]+\.(?:jpg|jpeg|png|webp))"[^>]+(?:class="[^"]*rounded[^"]*"|alt="[^"]*' + (title ? title.substring(0, 10) : '') + '[^"]*")/i)
              || html.match(/<img[^>]+src="(https?:\/\/[^"]*cover[^"]+\.(?:jpg|jpeg|png|webp))"/i)
              || html.match(/<img[^>]+(?:data-src|src)="(https?:\/\/[^"]+\.(?:jpg|jpeg|png|webp))"/i);
    var cover = coverM ? coverM[1] : null;

    var descM = html.match(/<p[^>]*class="[^"]*text-sm[^"]*"[^>]*>([\s\S]*?)<\/p>/i);
    var description = descM ? _clean(descM[1]) : '';

    var statusM = html.match(/Status[\s\S]{0,150}?<div[^>]*>([^<]+)<\/div>/i);
    var status = _statusOf(statusM ? statusM[1] : '');

    var genres = [];
    var gRe = /href="\/search\?[^"]*genre=[^"]+"[^>]*>([^<]+)</g;
    var gm;
    while ((gm = gRe.exec(html)) !== null) {
      var g = _clean(gm[1]);
      if (g && genres.indexOf(g) === -1) genres.push(g);
    }

    var chapters = _parseChapters(html);
    var idMatch = url.match(/\/manga\/(\d+)/);
    var id = idMatch ? idMatch[1] : url;

    console.log('mangapill detail: title=' + title + ' chapters=' + chapters.length + ' status=' + status);
    return {
      id: id, title: title, cover: cover,
      coverHeaders: { 'Referer': REFERER },
      url: url,
      description: description, status: status,
      genres: genres, authors: [], chapters: chapters, type: 'manga'
    };
  });
}

function getChapters(url) {
  return fetch(url).then(function(r) { return _parseChapters(r.body || ''); });
}

function getPages(chapterUrl) {
  console.log('mangapill pages url: ' + chapterUrl);
  return fetch(chapterUrl).then(function(r) {
    var html = r.body || '';
    var out = [];
    // <img class="js-page" data-src="https://cdn.../page.jpeg">
    var re = /<img[^>]+(?:class="[^"]*js-page[^"]*"[^>]+data-src|data-src[^>]*class="[^"]*js-page[^"]*")="([^"]+)"|<img[^>]+class="[^"]*js-page[^"]*"[^>]+data-src="([^"]+)"/g;
    var matches = _allMatches(html, re);
    if (matches.length === 0) {
      // Fallback: any data-src that points to a known CDN
      re = /data-src="(https?:\/\/[^"]+\.(?:jpg|jpeg|png|webp))"/g;
      matches = _allMatches(html, re);
    }
    for (var i = 0; i < matches.length; i++) {
      var src = matches[i][1] || matches[i][2];
      if (!src) continue;
      out.push({
        url: src,
        index: out.length,
        headers: { 'Referer': REFERER }
      });
    }
    console.log('mangapill pages count: ' + out.length);
    if (out.length === 0) throw new Error('No pages found');
    return out;
  });
}

function getChapterContent(chapterUrl) {
  return { text: 'Mangapill is a manga-only source.', nextUrl: null };
}
