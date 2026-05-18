// NovelBin provider — https://novelbin.com
// Open access, no Cloudflare gate. Search results are server-side rendered,
// chapter lists come from a dedicated AJAX endpoint, and chapter content
// lives in a consistent `<div id="chr-content">` container.

var SOURCE_ID = 'novelbin';
var SITE = 'https://novelbin.com';
var REFERER = SITE + '/';

function getInfo() {
  return {
    name: 'NovelBin',
    lang: 'en',
    baseUrl: SITE,
    logo: SITE + '/img/logo.png',
    type: 'novel',
    version: '1.0.0'
  };
}

function _cleanText(s) {
  return htmlText(s || '').replace(/\s+/g, ' ').trim();
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

function _idFromUrl(url) {
  // /b/<slug>           -> "<slug>"
  // /b/<slug>/chapter-N -> "<slug>__chapter-N"
  var m = String(url).match(/\/b\/([^\/?#]+)(?:\/([^?#]+))?/);
  if (!m) return String(url);
  return m[2] ? m[1] + '__' + m[2] : m[1];
}

function _slugFromUrl(url) {
  var m = String(url).match(/\/b\/([^\/?#]+)/);
  return m ? m[1] : null;
}

function _normalizeStatus(s) {
  s = (s || '').toLowerCase();
  if (s.indexOf('ongoing') !== -1) return 'ongoing';
  if (s.indexOf('complete') !== -1 || s.indexOf('finished') !== -1) return 'completed';
  if (s.indexOf('hiatus') !== -1) return 'hiatus';
  return 'unknown';
}

function _parseListing(html) {
  var results = [];
  var seen = {};
  // Each card has:
  //   <h3 class="novel-title|title"><a href="https://novelbin.com/b/<slug>" title="Title">Title</a></h3>
  var titleRe = /<h3\s+class="(?:novel-title|title)"[^>]*>\s*<a[^>]+href="([^"]+\/b\/[^"]+)"[^>]*(?:title="([^"]*)")?[^>]*>([^<]+)<\/a>/g;
  var matches = _allMatches(html, titleRe);
  for (var i = 0; i < matches.length; i++) {
    var link = matches[i][1].replace(/&amp;/g, '&');
    if (link.indexOf('/chapter-') !== -1) continue; // skip chapter links
    if (seen[link]) continue;
    seen[link] = true;
    var title = _cleanText(matches[i][2] || matches[i][3]);

    // Walk back to find the cover img (lazy-loaded via data-src).
    var titleIdx = html.indexOf(matches[i][0]);
    var snippet = titleIdx >= 0 ? html.substring(Math.max(0, titleIdx - 800), titleIdx) : '';
    var coverM = snippet.match(/data-src="(https?:\/\/[^"]+\.(?:jpg|jpeg|png|webp))"/i);
    if (!coverM) coverM = snippet.match(/<img[^>]+src="(https?:\/\/[^"]+\.(?:jpg|jpeg|png|webp))"/i);
    var cover = coverM ? coverM[1] : null;
    // NovelBin's listing markup points at the /novel_80_113/ thumbnail
    // (80x113 px) which is way too small for the home grid and renders
    // visibly blurry. The full-res variant lives at /novel/<slug>.jpg —
    // same CDN, no resize prefix.
    if (cover) {
      cover = cover.replace(/\/novel_\d+_\d+\//, '/novel/');
    }

    results.push({
      id: _idFromUrl(link),
      title: title,
      cover: cover,
      url: link,
      type: 'novel'
    });
  }
  return results;
}

function search(query, page, category) {
  page = page || 1;
  category = category || '';
  var hasQuery = query && String(query).trim().length > 0;

  var url;
  if (hasQuery) {
    url = SITE + '/search?keyword=' + encodeURIComponent(String(query).trim());
  } else if (category === 'latest') {
    url = SITE + '/sort/latest';
  } else if (category === 'trending') {
    url = SITE + '/sort/top-hot-novel';
  } else {
    url = SITE + '/sort/top-view-novel';
  }
  console.log('novelbin search url: ' + url);

  return fetch(url, { headers: { 'Referer': REFERER } }).then(function(r) {
    var results = _parseListing(r.body || '');
    console.log('novelbin search count: ' + results.length);
    return results;
  });
}

function _parseInfoMeta(html, label) {
  // <ul class="info info-meta"><li><h3>Author:</h3> <a>X</a></li>...
  var re = new RegExp('<h3>\\s*' + label + '\\s*:?\\s*<\\/h3>([\\s\\S]*?)</li>', 'i');
  var m = html.match(re);
  return m ? m[1] : '';
}

function _parseLinks(chunk) {
  var out = [];
  var re = /<a[^>]*>([^<]+)<\/a>/g;
  var m;
  while ((m = re.exec(chunk)) !== null) {
    var v = _cleanText(m[1]);
    if (v && out.indexOf(v) === -1) out.push(v);
  }
  if (out.length === 0) {
    var plain = _cleanText(chunk);
    if (plain) out.push(plain);
  }
  return out;
}

function getDetail(url) {
  console.log('novelbin detail url: ' + url);
  return fetch(url, { headers: { 'Referer': REFERER } }).then(function(r) {
    var html = r.body || '';

    var titleM = html.match(/<h3\s+class="title"[^>]*>([\s\S]*?)<\/h3>/i);
    var title = titleM ? _cleanText(titleM[1]) : '';

    var coverM = html.match(/<div\s+class="book"[^>]*>\s*<img[^>]+src="([^"]+)"/i);
    if (!coverM) coverM = html.match(/<img[^>]+itemprop="image"[^>]+src="([^"]+)"/i);
    var cover = coverM ? coverM[1] : null;

    var descM = html.match(/<div[^>]+class="desc-text(?:\s+[^"]*)?"\s+id="novel-description-content"[^>]*>([\s\S]*?)<\/div>/i);
    if (!descM) descM = html.match(/<div[^>]+class="desc-text[^"]*"[^>]*itemprop="description"[^>]*>([\s\S]*?)<\/div>/i);
    if (!descM) descM = html.match(/<div[^>]+class="desc-text[^"]*"[^>]*>([\s\S]*?)<\/div>/i);
    var description = descM ? _cleanText(descM[1]) : '';

    var authors = _parseLinks(_parseInfoMeta(html, 'Author'));
    var genres = _parseLinks(_parseInfoMeta(html, 'Genre'));
    var statusRaw = _parseLinks(_parseInfoMeta(html, 'Status'));
    var status = _normalizeStatus(statusRaw.length ? statusRaw[0] : '');

    var slug = _slugFromUrl(url);
    return _fetchChapterArchive(slug).then(function(chapters) {
      console.log('novelbin detail: title=' + title + ' chapters=' + chapters.length + ' status=' + status);
      return {
        id: _idFromUrl(url),
        title: title,
        cover: cover,
        url: url,
        description: description,
        status: status,
        genres: genres,
        authors: authors,
        chapters: chapters,
        type: 'novel'
      };
    });
  });
}

function _fetchChapterArchive(slug) {
  if (!slug) return Promise.resolve([]);
  // The /ajax/chapter-archive endpoint returns a plain HTML fragment with
  // every chapter as an <a href="..."> — no JS-rendering required.
  var url = SITE + '/ajax/chapter-archive?novelId=' + encodeURIComponent(slug);
  return fetch(url, {
    headers: {
      'Referer': SITE + '/b/' + slug,
      'X-Requested-With': 'XMLHttpRequest',
      'Accept': 'text/html,application/xhtml+xml'
    }
  }).then(function(r) {
    var html = r.body || '';
    var out = [];
    var seen = {};
    var re = /<a[^>]+href="([^"]+\/b\/[^"]+\/chapter-[^"]+)"[^>]*(?:title="([^"]+)")?[^>]*>([\s\S]*?)<\/a>/gi;
    var matches = _allMatches(html, re);
    for (var i = 0; i < matches.length; i++) {
      var link = matches[i][1].replace(/&amp;/g, '&');
      if (seen[link]) continue;
      seen[link] = true;
      var rawTitle = _cleanText(matches[i][2] || matches[i][3] || '');
      var numMatch = rawTitle.match(/chapter\s*([0-9]+(?:\.[0-9]+)?)/i);
      if (!numMatch) numMatch = link.match(/chapter-([0-9]+(?:\.[0-9]+)?)/i);
      var num = numMatch ? parseFloat(numMatch[1]) : null;
      out.push({
        id: _idFromUrl(link),
        title: rawTitle || ('Chapter ' + (out.length + 1)),
        number: isNaN(num) ? null : num,
        url: link,
        date: ''
      });
    }
    // Sort ascending by chapter number so the reader's "next" button maps
    // to a numerically-higher chapter.
    out.sort(function(a, b) {
      if (a.number == null && b.number == null) return 0;
      if (a.number == null) return -1;
      if (b.number == null) return 1;
      return a.number - b.number;
    });
    return out;
  });
}

function getChapters(url) {
  var slug = _slugFromUrl(url);
  return _fetchChapterArchive(slug);
}

function getPages(chapterUrl) {
  return [];
}

function getChapterContent(chapterUrl) {
  console.log('novelbin chapter url: ' + chapterUrl);
  return fetch(chapterUrl, { headers: { 'Referer': REFERER } }).then(function(r) {
    var html = r.body || '';
    // The content panel <div id="chr-content"> wraps multiple nested divs
    // (ad slots, etc.), so a lazy-stop regex would clip after the first
    // </div>. Slice between the open tag and the next chr-nav marker
    // (or the fb comment block) for a reliable boundary.
    var openIdx = html.indexOf('id="chr-content"');
    var content = '';
    if (openIdx !== -1) {
      // Advance past the opening tag's closing '>'.
      var startIdx = html.indexOf('>', openIdx);
      if (startIdx !== -1) {
        startIdx += 1;
        var endIdx = html.indexOf('chr-nav-bottom', startIdx);
        if (endIdx === -1) endIdx = html.indexOf('fb-comment-chapter', startIdx);
        if (endIdx === -1) endIdx = html.indexOf('</body>', startIdx);
        if (endIdx === -1) endIdx = html.length;
        content = html.substring(startIdx, endIdx);
      }
    }

    // Strip ads and scripts.
    content = content.replace(/<script[\s\S]*?<\/script>/gi, '');
    content = content.replace(/<ins[\s\S]*?<\/ins>/gi, '');
    content = content.replace(/<div[^>]*class="(?:ads|adsense|pgad|ad-bottom|ad-top)[^"]*"[\s\S]*?<\/div>/gi, '');

    var paragraphs = [];
    var pm = /<p[^>]*>([\s\S]*?)<\/p>/gi;
    var p;
    while ((p = pm.exec(content)) !== null) {
      var t = _cleanText(p[1]);
      if (t) paragraphs.push(t);
    }
    var text;
    if (paragraphs.length > 0) {
      text = paragraphs.join('\n\n');
    } else {
      text = _cleanText(content.replace(/<br\s*\/?>/gi, '\n'));
    }

    // Next-chapter link — NovelBin uses id="next_chap" on the navigation
    // bar. Fall back to any "Next" anchor in the page if absent.
    var nextUrl = null;
    var nextM = html.match(/<a[^>]+id="next_chap"[^>]+href="([^"]+)"/i);
    if (nextM) {
      nextUrl = absUrl(nextM[1], SITE);
    }
    if (!nextUrl || /javascript:|#$/i.test(nextUrl)) {
      // Numeric bump fallback.
      var bumpM = chapterUrl.match(/(.+\/chapter-)(\d+)([^\/?#]*)$/i);
      if (bumpM) {
        nextUrl = bumpM[1] + (parseInt(bumpM[2], 10) + 1);
      } else {
        nextUrl = null;
      }
    }
    return { text: text, nextUrl: nextUrl };
  });
}
