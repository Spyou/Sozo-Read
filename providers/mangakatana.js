// Mangakatana provider — https://mangakatana.com
// Search & detail in plain HTML; chapter image URLs embedded as a JS array
// (e.g. var thzq=['url1','url2',...]) which we extract via regex.

var SOURCE_ID = 'mangakatana';
var SITE = 'https://mangakatana.com';
var REFERER = SITE + '/';

function getInfo() {
  return {
    name: 'Mangakatana',
    lang: 'en',
    baseUrl: SITE,
    logo: SITE + '/static/img/logo.png',
    type: 'manga',
    version: '1.0.0'
  };
}

function _allMatches(html, regex) {
  var out = []; var m; regex.lastIndex = 0;
  while ((m = regex.exec(html)) !== null) {
    out.push(m);
    if (m.index === regex.lastIndex) regex.lastIndex++;
  }
  return out;
}

function _clean(s) { return htmlText(s || '').replace(/\s+/g, ' ').trim(); }

function _statusOf(s) {
  s = (s || '').toLowerCase();
  if (s.indexOf('ongoing') !== -1) return 'ongoing';
  if (s.indexOf('completed') !== -1) return 'completed';
  if (s.indexOf('hiatus') !== -1) return 'hiatus';
  if (s.indexOf('cancelled') !== -1) return 'cancelled';
  return 'unknown';
}

function search(query, page, category) {
  page = page || 1;
  category = category || '';
  var hasQuery = query && String(query).trim().length > 0;
  var url;
  if (hasQuery) {
    url = SITE + '/?search=' + encodeURIComponent(String(query).trim()) + '&search_by=book_name' + (page > 1 ? '&page=' + page : '');
  } else if (category === 'latest') {
    url = SITE + '/latest' + (page > 1 ? '/page/' + page : '');
  } else if (category === 'trending') {
    url = SITE + '/popular' + (page > 1 ? '/page/' + page : '');
  } else {
    // Default popular.
    url = SITE + '/popular' + (page > 1 ? '/page/' + page : '');
  }
  console.log('mangakatana search url: ' + url);
  return fetch(url).then(function(r) {
    console.log('mangakatana search status: ' + r.status + ' bodyLen: ' + (r.body || '').length);
    var html = r.body || '';
    var results = [];
    // Card shape: <div class="item"> ... <img src="cover" alt="[Cover]"/> ...
    //   <h3 class="title"> <a href="https://mangakatana.com/manga/<slug>" target="_blank">TITLE</a> ...
    var re = /<div class="item"[\s\S]*?<img[^>]+src="(https?:\/\/[^"]+)"[\s\S]*?<h3 class="title">\s*<a[^>]+href="(https:\/\/mangakatana\.com\/manga\/[^"]+)"[^>]*>([^<]+)<\/a>/g;
    var matches = _allMatches(html, re);
    var seen = {};
    for (var i = 0; i < matches.length; i++) {
      var cover = matches[i][1];
      var link = matches[i][2];
      if (seen[link]) continue;
      seen[link] = true;
      var title = _clean(matches[i][3]);
      var idMatch = link.match(/\/manga\/([^\/]+)/);
      results.push({
        id: idMatch ? idMatch[1] : link,
        title: title,
        cover: cover,
        url: link,
        type: 'manga'
      });
    }
    console.log('mangakatana search count: ' + results.length);
    return results;
  });
}

function _parseChapters(html, baseUrl) {
  var out = [];
  var seen = {};
  // Chapter rows: <a href=".../c<num>"> ... <span class="time">DATE</span>
  var re = /<a[^>]+href="(https:\/\/mangakatana\.com\/manga\/[^"]+\/c[0-9.]+(?:\/[^"]*)?)"[^>]*>([^<]+)<\/a>/g;
  var matches = _allMatches(html, re);
  for (var i = 0; i < matches.length; i++) {
    var link = matches[i][1];
    if (seen[link]) continue;
    seen[link] = true;
    var title = _clean(matches[i][2]);
    if (!title) continue;
    var numMatch = link.match(/\/c([0-9.]+)/);
    var num = numMatch ? parseFloat(numMatch[1]) : null;
    out.push({
      id: numMatch ? 'c' + numMatch[1] : link,
      title: title,
      number: isNaN(num) ? null : num,
      url: link,
      date: ''
    });
  }
  return out;
}

function getDetail(url) {
  console.log('mangakatana detail url: ' + url);
  return fetch(url).then(function(r) {
    var html = r.body || '';
    var titleM = html.match(/<h1[^>]*class="[^"]*heading[^"]*"[^>]*>([^<]+)<\/h1>/i)
              || html.match(/<h1[^>]*>([^<]+)<\/h1>/);
    var title = _clean(titleM ? titleM[1] : '');

    var coverM = html.match(/<img[^>]+src="(https?:\/\/mangakatana\.com\/imgs\/[^"]+\.(?:jpg|jpeg|png|webp))"/i);
    var cover = coverM ? coverM[1] : null;

    var descM = html.match(/<div[^>]+class="[^"]*summary[^"]*"[^>]*>([\s\S]*?)<\/div>/i);
    if (!descM) descM = html.match(/<meta\s+name="description"\s+content="([^"]+)"/i);
    var description = descM ? _clean(descM[1]) : '';

    var statusM = html.match(/Status[\s\S]{0,200}?<div[^>]*>([^<]+)<\/div>/i)
              || html.match(/Status\s*:?\s*<[^>]+>([^<]+)</i);
    var status = _statusOf(statusM ? statusM[1] : '');

    var genres = [];
    var gRe = /<a[^>]+href="https:\/\/mangakatana\.com\/genre\/[^"]+"[^>]*>([^<]+)<\/a>/g;
    var gm;
    while ((gm = gRe.exec(html)) !== null) {
      var g = _clean(gm[1]);
      if (g && genres.indexOf(g) === -1) genres.push(g);
    }

    var chapters = _parseChapters(html, url);
    var idMatch = url.match(/\/manga\/([^\/]+)/);
    var id = idMatch ? idMatch[1] : url;

    console.log('mangakatana detail: title=' + title + ' chapters=' + chapters.length + ' status=' + status);
    return {
      id: id, title: title, cover: cover, url: url,
      description: description, status: status,
      genres: genres, authors: [], chapters: chapters, type: 'manga'
    };
  });
}

function getChapters(url) {
  return fetch(url).then(function(r) { return _parseChapters(r.body || '', url); });
}

function getPages(chapterUrl) {
  console.log('mangakatana pages url: ' + chapterUrl);
  return fetch(chapterUrl).then(function(r) {
    var html = r.body || '';
    // Find ALL "var <name>=[ ... ]" arrays that contain mangakatana.com image URLs,
    // pick the longest one.
    var best = [];
    var re = /var\s+\w+\s*=\s*\[([^\]]+)\]/g;
    var m;
    while ((m = re.exec(html)) !== null) {
      var body = m[1];
      if (body.indexOf('mangakatana') === -1) continue;
      var urlRe = /['"](https?:\/\/[^'"]+\.(?:jpg|jpeg|png|webp))['"]/g;
      var urls = [];
      var um;
      while ((um = urlRe.exec(body)) !== null) urls.push(um[1]);
      if (urls.length > best.length) best = urls;
    }
    console.log('mangakatana pages count: ' + best.length);
    if (best.length === 0) throw new Error('No image array found in chapter');
    return best.map(function(u, i) {
      return { url: u, index: i, headers: { 'Referer': REFERER } };
    });
  });
}

function getChapterContent(chapterUrl) {
  return { text: 'Mangakatana is a manga-only source.', nextUrl: null };
}
