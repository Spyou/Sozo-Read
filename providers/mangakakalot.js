// Mangakakalot provider — targets mangakakalot.fun (the live mirror).
// mangakakalot.com is dead (domain hijacked); .gg is Cloudflare-gated; .fun works.

var SOURCE_ID = 'mangakakalot';
var SITE = 'https://mangakakalot.fun';
var REFERER = SITE + '/';

function getInfo() {
  return {
    name: 'Mangakakalot',
    lang: 'en',
    baseUrl: SITE,
    logo: SITE + '/logo.png',
    type: 'manga',
    version: '1.0.0'
  };
}

function _allMatches(html, regex) {
  var out = [];
  var m;
  regex.lastIndex = 0;
  while ((m = regex.exec(html)) !== null) {
    out.push(m);
    if (m.index === regex.lastIndex) regex.lastIndex++;
  }
  return out;
}

function _cleanText(s) {
  return htmlText(s || '')
    .replace(/<!--[\s\S]*?-->/g, '')
    .replace(/\s+/g, ' ')
    .trim();
}

function _normalizeStatus(s) {
  s = (s || '').toLowerCase();
  if (s.indexOf('ongoing') !== -1) return 'ongoing';
  if (s.indexOf('completed') !== -1) return 'completed';
  if (s.indexOf('hiatus') !== -1) return 'hiatus';
  if (s.indexOf('cancelled') !== -1 || s.indexOf('discontinued') !== -1) return 'cancelled';
  return 'unknown';
}

function _slugify(q) {
  return String(q || '').trim().toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_|_$/g, '');
}

function search(query, page) {
  page = page || 1;
  var hasQuery = query && String(query).trim().length > 0;
  var url;
  if (hasQuery) {
    url = SITE + '/search/story/' + encodeURIComponent(_slugify(query)) + (page > 1 ? '?page=' + page : '');
  } else {
    // No query => browse popular.
    url = SITE + '/popular' + (page > 1 ? '?page=' + page : '');
  }
  console.log('mangakakalot search url: ' + url);
  return fetch(url).then(function(r) {
    console.log('mangakakalot search status: ' + r.status + ' bodyLen: ' + (r.body || '').length);
    var html = r.body || '';
    var results = [];
    // Each result: <div class="media-manga media"><div class="media-left"><a href="..."><img ... alt="Title" src="cover"></a></div>
    var re = /<div class="media-manga media">[\s\S]*?<div class="media-left">\s*<a href="([^"]+)"[^>]*>\s*<img[^>]*?src="([^"]+)"[^>]*?alt="([^"]*)"[\s\S]*?<\/div>\s*<\/div>/g;
    var matches = _allMatches(html, re);
    for (var i = 0; i < matches.length; i++) {
      var link = matches[i][1];
      var cover = matches[i][2];
      var title = _cleanText(matches[i][3]);
      if (!/\/manga\//.test(link)) continue;
      var id = link.replace(/.*\/manga\//, '').replace(/[\/?#].*$/, '');
      results.push({ id: id, title: title, cover: cover, url: link, type: 'manga' });
    }
    console.log('mangakakalot search result count: ' + results.length);
    return results;
  });
}

function _extractChapters(html) {
  // Stable: every chapter link is of shape /chapter/<manga-slug>/chapter-N
  // Use the <a href="...chapter/<slug>/chapter-..."> tag and capture inner text.
  var out = [];
  var re = /<a\s+href="(https?:\/\/[^"]+\/chapter\/[^"\/]+\/chapter-[^"]+)"[^>]*>([\s\S]*?)<\/a>/g;
  var seen = {};
  var matches = _allMatches(html, re);
  for (var i = 0; i < matches.length; i++) {
    var link = matches[i][1];
    if (seen[link]) continue;
    seen[link] = true;
    var inner = matches[i][2];
    // Pull date if present inside the anchor
    var dateMatch = inner.match(/<small[^>]*>([\s\S]*?)<\/small>/);
    var date = dateMatch ? _cleanText(dateMatch[1]) : '';
    // Strip the date span before computing title
    var titleSrc = dateMatch ? inner.replace(dateMatch[0], '') : inner;
    var title = _cleanText(titleSrc);
    if (!title || title.toLowerCase().indexOf('start reading') !== -1) continue;
    var idMatch = link.match(/chapter-([^\/?#]+)$/);
    var id = idMatch ? idMatch[1] : link;
    var numMatch = title.match(/(?:chapter|#)\s*([0-9.]+)/i) || (idMatch ? idMatch[1].match(/^([0-9.]+)/) : null);
    var num = numMatch ? parseFloat(numMatch[1]) : null;
    out.push({
      id: id,
      title: title,
      number: isNaN(num) ? null : num,
      url: link,
      date: date
    });
  }
  return out;
}

function getDetail(url) {
  console.log('mangakakalot detail url: ' + url);
  return fetch(url).then(function(r) {
    var html = r.body || '';

    // Title — first <h1>...</h1>, drop any nested anchors/labels
    var titleM = html.match(/<h1[^>]*>([\s\S]*?)<\/h1>/);
    var rawTitle = titleM ? titleM[1] : '';
    var title = _cleanText(rawTitle.replace(/<a[^>]*>[\s\S]*?<\/a>/g, '').replace(/<small[\s\S]*?<\/small>/g, ''));

    // Cover image
    var coverM = html.match(/<img[^>]+src="(https?:\/\/[^"]+\.(?:jpg|jpeg|png|webp))"[^>]+(?:alt="[^"]*manga[^"]*"|class="[^"]*thumb[^"]*")/i)
              || html.match(/<img[^>]+(?:alt="[^"]*"|class="[^"]*manga[^"]*")[^>]+src="([^"]+)"/i);
    var cover = coverM ? coverM[1] : null;

    // Status
    var statusM = html.match(/Status\s*<\/span>\s*<span>([^<]+)<\/span>/i)
              || html.match(/Status[^<]*<[^>]*>([^<]+)</i);
    var status = _normalizeStatus(statusM ? statusM[1] : '');

    // Authors
    var authors = [];
    var authM = html.match(/Author[^<]*<\/span>\s*<span>([^<]+)<\/span>/i);
    if (authM) {
      authors = authM[1].split(/[,;]/).map(function(s) { return _cleanText(s); }).filter(Boolean);
    }

    // Genres — labelled anchors
    var genres = [];
    var gRe = /<a[^>]+href="[^"]+\/genre\/[^"]+"[^>]*>([^<]+)<\/a>/g;
    var gm;
    while ((gm = gRe.exec(html)) !== null) {
      var g = _cleanText(gm[1]);
      if (g && genres.indexOf(g) === -1) genres.push(g);
    }

    // Description — usually inside a paragraph; look for known anchors
    var descM = html.match(/<div[^>]*class="[^"]*summary[^"]*"[^>]*>([\s\S]*?)<\/div>/i)
             || html.match(/<p[^>]*class="[^"]*description[^"]*"[^>]*>([\s\S]*?)<\/p>/i)
             || html.match(/<meta\s+name="description"\s+content="([^"]+)"/i);
    var description = descM ? _cleanText(descM[1]) : '';

    var chapters = _extractChapters(html);
    var id = url.replace(/.*\/manga\//, '').replace(/[\/?#].*$/, '');

    console.log('mangakakalot detail: title=' + title + ' chapters=' + chapters.length + ' status=' + status);

    return {
      id: id,
      title: title,
      cover: cover,
      url: url,
      description: description,
      status: status,
      genres: genres,
      authors: authors,
      chapters: chapters,
      type: 'manga'
    };
  });
}

function getChapters(url) {
  return fetch(url).then(function(r) { return _extractChapters(r.body || ''); });
}

function getPages(chapterUrl) {
  console.log('mangakakalot pages url: ' + chapterUrl);
  return fetch(chapterUrl).then(function(r) {
    var html = r.body || '';
    var out = [];
    // Match CDN-hosted images (mghcdn / mgcdn / similar).
    var re = /<img[^>]+src="(https?:\/\/[^"]*(?:mghcdn|mgcdn|mangahere|mangakakalot)[^"]+\.(?:jpg|jpeg|png|webp))"/gi;
    var matches = _allMatches(html, re);
    if (matches.length === 0) {
      // Fallback: any image that lives on a different host than the page and looks like a chapter image.
      re = /<img[^>]+src="(https?:\/\/[^"]+\/[^"]*?(?:chapter|cdn|images?)[^"]*?\/[0-9]+\.(?:jpg|jpeg|png|webp))"/gi;
      matches = _allMatches(html, re);
    }
    for (var i = 0; i < matches.length; i++) {
      out.push({
        url: matches[i][1],
        index: i,
        headers: { 'Referer': REFERER }
      });
    }
    console.log('mangakakalot pages count: ' + out.length);
    return out;
  });
}

function getChapterContent(chapterUrl) {
  return { text: 'Mangakakalot is a manga-only source.', nextUrl: null };
}
