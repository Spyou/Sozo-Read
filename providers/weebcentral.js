// WeebCentral provider — scrapes https://weebcentral.com
// Why this site: full chapter pages are served in the htmx fragment endpoint,
// no Cloudflare gate, no licensed-chapter gaps like MangaDex.

var SOURCE_ID = 'weebcentral';
var SITE = 'https://weebcentral.com';
var REFERER = SITE + '/';

function getInfo() {
  return {
    name: 'WeebCentral',
    lang: 'en',
    baseUrl: SITE,
    logo: SITE + '/static/images/brand.png',
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
  return htmlText(s || '').replace(/\s+/g, ' ').trim();
}

function _normalizeStatus(s) {
  s = (s || '').toLowerCase();
  if (s.indexOf('ongoing') !== -1) return 'ongoing';
  if (s.indexOf('complete') !== -1) return 'completed';
  if (s.indexOf('hiatus') !== -1) return 'hiatus';
  if (s.indexOf('cancel') !== -1 || s.indexOf('discontinued') !== -1) return 'cancelled';
  return 'unknown';
}

function _idFromSeriesUrl(url) {
  var m = String(url).match(/\/series\/([^\/]+)/);
  return m ? m[1] : url;
}

function _idFromChapterUrl(url) {
  var m = String(url).match(/\/chapters\/([^\/?#]+)/);
  return m ? m[1] : url;
}

function search(query, page) {
  page = page || 1;
  var hasQuery = query && String(query).trim().length > 0;
  // The search endpoint returns the same HTML format whether or not text is set.
  var qs = [
    'text=' + encodeURIComponent(hasQuery ? String(query).trim() : ''),
    'sort=' + (hasQuery ? 'Best+Match' : 'Popularity'),
    'order=Descending',
    'official=Any',
    'anime=Any',
    'adult=Any',
    'display_mode=Full+Display',
    'limit=32',
    'offset=' + (page - 1) * 32
  ].join('&');
  var url = SITE + '/search/data?' + qs;
  console.log('weebcentral search url: ' + url);
  return fetch(url).then(function(r) {
    console.log('weebcentral search status: ' + r.status + ' bodyLen: ' + (r.body || '').length);
    var html = r.body || '';
    var results = [];
    // Each <article> contains: 1) a cover <img alt="X cover"> and 2) a clean title anchor
    //   <a href="/series/<id>/<slug>" class="line-clamp-1 link link-hover">Title</a>
    // We iterate articles and pull cover + title together.
    var articles = html.split('<article class="bg-base-300');
    var seen = {};
    for (var i = 1; i < articles.length; i++) {
      var blk = articles[i];
      var coverM = blk.match(/<img[^>]+src="(https?:\/\/[^"]+\.(?:jpg|jpeg|png|webp))"/i);
      // Prefer larger webp from srcset normal/<id>.webp
      var bigM = blk.match(/srcset="(https?:\/\/[^"]+\/cover\/normal\/[^"]+\.webp)"/i);
      var cover = bigM ? bigM[1] : (coverM ? coverM[1] : null);
      var titleM = blk.match(/<a[^>]+href="(https:\/\/weebcentral\.com\/series\/[^"]+)"[^>]*class="[^"]*line-clamp-1[^"]*"[^>]*>([^<]+)<\/a>/);
      if (!titleM) {
        // Fallback: derive title from slug + img alt
        var anyLink = blk.match(/href="(https:\/\/weebcentral\.com\/series\/[^"]+)"/);
        if (!anyLink) continue;
        var altM = blk.match(/<img[^>]+alt="([^"]*?)\s*cover"/i);
        titleM = [null, anyLink[1], altM ? altM[1] : anyLink[1].split('/').pop().replace(/-/g, ' ')];
      }
      var link = titleM[1];
      if (seen[link]) continue;
      seen[link] = true;
      var title = _cleanText(titleM[2]).replace(/\s+cover$/i, '');
      results.push({
        id: _idFromSeriesUrl(link),
        title: title,
        cover: cover,
        url: link,
        type: 'manga'
      });
    }
    console.log('weebcentral search result count: ' + results.length);
    return results;
  });
}

function _parseSidebarField(html, label) {
  // Markup pattern: <li> <strong>Label: </strong> <a ...>Value</a> </li>
  // or with <span>. We capture the inside of the li.
  var re = new RegExp('<strong>\\s*' + label + '\\s*:?\\s*<\\/strong>([\\s\\S]*?)</li>', 'i');
  var m = html.match(re);
  return m ? m[1] : '';
}

function _parseLinkValues(chunk) {
  var out = [];
  var re = /<a[^>]*>([^<]+)<\/a>/g;
  var m;
  while ((m = re.exec(chunk)) !== null) {
    var v = _cleanText(m[1]);
    if (v && out.indexOf(v) === -1) out.push(v);
  }
  return out;
}

function getDetail(url) {
  console.log('weebcentral detail url: ' + url);
  return fetch(url).then(function(r) {
    var html = r.body || '';
    var titleM = html.match(/<h1[^>]*>([^<]+)<\/h1>/);
    var title = titleM ? _cleanText(titleM[1]) : '';

    var coverM = html.match(/<img[^>]+src="(https?:\/\/[^"]+\/cover\/[^"]+\.(?:jpg|jpeg|png|webp))"/i);
    var cover = coverM ? coverM[1] : null;

    var descM = html.match(/<p[^>]*class="[^"]*whitespace-pre[^"]*"[^>]*>([\s\S]*?)<\/p>/i);
    if (!descM) descM = html.match(/<p[^>]*class="[^"]*description[^"]*"[^>]*>([\s\S]*?)<\/p>/i);
    var description = descM ? _cleanText(descM[1]) : '';

    var status = _normalizeStatus(_cleanText(_parseSidebarField(html, 'Status')));
    var authors = _parseLinkValues(_parseSidebarField(html, 'Author\\(s\\)'));
    if (authors.length === 0) authors = _parseLinkValues(_parseSidebarField(html, 'Author'));
    // Tags label on the site is literally "Tags(s):" — match that form.
    var genres = _parseLinkValues(_parseSidebarField(html, 'Tags?\\(s\\)'));
    if (genres.length === 0) genres = _parseLinkValues(_parseSidebarField(html, 'Tags?'));
    if (genres.length === 0) genres = _parseLinkValues(_parseSidebarField(html, 'Genres?'));

    var id = _idFromSeriesUrl(url);
    var chaptersUrl = SITE + '/series/' + id + '/full-chapter-list';
    return _fetchChapters(chaptersUrl).then(function(chapters) {
      console.log('weebcentral detail: title=' + title + ' chapters=' + chapters.length + ' status=' + status);
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
  });
}

function _fetchChapters(url) {
  return fetch(url).then(function(r) {
    var html = r.body || '';
    var out = [];
    // Pull every chapter link + its <time datetime="..."> (if present).
    var re = /<a[^>]+href="(https:\/\/weebcentral\.com\/chapters\/[^"]+)"[\s\S]*?<span[^>]*>([^<]+Chapter[^<]*|[^<]+)<\/span>[\s\S]*?(?:<time[^>]+datetime="([^"]+)")?/g;
    var matches = _allMatches(html, re);
    var seen = {};
    for (var i = 0; i < matches.length; i++) {
      var link = matches[i][1];
      if (seen[link]) continue;
      seen[link] = true;
      var rawTitle = _cleanText(matches[i][2]);
      // The first span we hit might be "Last Read" or a label — skip if not a chapter-ish string.
      if (!/chapter|vol/i.test(rawTitle) && !/^\d/.test(rawTitle)) continue;
      var date = matches[i][3] ? matches[i][3].substring(0, 10) : '';
      var numMatch = rawTitle.match(/([0-9]+(?:\.[0-9]+)?)/);
      var num = numMatch ? parseFloat(numMatch[1]) : null;
      out.push({
        id: _idFromChapterUrl(link),
        title: rawTitle,
        number: isNaN(num) ? null : num,
        url: link,
        date: date
      });
    }
    return out;
  });
}

function getChapters(url) {
  var id = _idFromSeriesUrl(url);
  return _fetchChapters(SITE + '/series/' + id + '/full-chapter-list');
}

function getPages(chapterUrl) {
  var id = _idFromChapterUrl(chapterUrl);
  var url = SITE + '/chapters/' + id + '/images?is_prev=False&reading_style=long_strip&current_page=1';
  console.log('weebcentral pages url: ' + url);
  return fetch(url, {
    headers: {
      // The /images endpoint returns the page-image fragment only when this header is set;
      // otherwise it returns the full shell page and we get zero images.
      'HX-Request': 'true',
      'HX-Target': 'chapter-images-display',
      'Referer': chapterUrl
    }
  }).then(function(r) {
    console.log('weebcentral pages status: ' + r.status + ' bodyLen: ' + (r.body || '').length);
    var html = r.body || '';
    var out = [];
    var re = /<img[^>]+src="(https?:\/\/[^"]+\.(?:jpg|jpeg|png|webp))"/gi;
    var matches = _allMatches(html, re);
    for (var i = 0; i < matches.length; i++) {
      var src = matches[i][1];
      // Filter out site assets (logos, icons hosted on weebcentral.com).
      if (/weebcentral\.com\/static/i.test(src)) continue;
      out.push({
        url: src,
        index: out.length,
        headers: { 'Referer': REFERER }
      });
    }
    console.log('weebcentral pages count: ' + out.length);
    if (out.length === 0) throw new Error('Chapter has no images');
    return out;
  });
}

function getChapterContent(chapterUrl) {
  return { text: 'WeebCentral is a manga-only source.', nextUrl: null };
}
