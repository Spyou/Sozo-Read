// FreeWebNovel provider — https://freewebnovel.com
// Free, no Cloudflare gate, full chapter content rendered server-side.
// Novel-type provider — getChapterContent returns paragraphs; getPages
// is a no-op.

var SOURCE_ID = 'freewebnovel';
var SITE = 'https://freewebnovel.com';
var REFERER = SITE + '/';

function getInfo() {
  return {
    name: 'FreeWebNovel',
    lang: 'en',
    baseUrl: SITE,
    logo: SITE + '/files/article/image/logo.png',
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
  // /novel/<slug>           -> "<slug>"
  // /novel/<slug>/chapter-N -> "<slug>__chapter-N"
  var m = String(url).match(/\/novel\/([^\/?#]+)(?:\/([^?#]+))?/);
  if (!m) return String(url);
  return m[2] ? m[1] + '__' + m[2] : m[1];
}

function _normalizeStatus(s) {
  s = (s || '').toLowerCase();
  if (s.indexOf('ongoing') !== -1) return 'ongoing';
  if (s.indexOf('complete') !== -1 || s.indexOf('finished') !== -1) return 'completed';
  if (s.indexOf('hiatus') !== -1) return 'hiatus';
  return 'unknown';
}

function search(query, page, category) {
  page = page || 1;
  category = category || '';
  var hasQuery = query && String(query).trim().length > 0;

  var url;
  if (hasQuery) {
    url = SITE + '/search/?searchkey=' + encodeURIComponent(String(query).trim());
  } else if (category === 'latest') {
    // /latest-release returns 404 on this site; the only working "latest"
    // surface is the homepage which mixes recent updates + popular. Fall
    // through to /most-popular so the category card stays populated.
    url = SITE + '/most-popular';
  } else {
    url = SITE + '/most-popular';
  }
  console.log('freewebnovel search url: ' + url);

  return fetch(url, {
    headers: {
      // FreeWebNovel rejects empty POSTs but accepts plain GET with
      // standard browser-ish headers.
      'Accept': 'text/html,application/xhtml+xml',
      'Referer': REFERER
    }
  }).then(function(r) {
    var html = r.body || '';
    var results = [];
    var seen = {};

    // Every result card has:
    //   <h3 class="tit"><a href="/novel/<slug>" title="Title">Title</a></h3>
    var titleRe = /<h3\s+class="tit">\s*<a[^>]+href="(\/novel\/[^"]+)"[^>]*(?:title="([^"]*)")?[^>]*>([^<]+)<\/a>/g;
    var titleMatches = _allMatches(html, titleRe);

    for (var i = 0; i < titleMatches.length; i++) {
      var href = titleMatches[i][1];
      var link = absUrl(href, SITE);
      if (seen[link]) continue;
      seen[link] = true;
      var title = _cleanText(titleMatches[i][2] || titleMatches[i][3]);

      // The cover image lives in the same <li> wrapper, typically before
      // the title h3. Walk back from the title position to find it.
      var titleIdx = html.indexOf(titleMatches[i][0]);
      var snippet = titleIdx >= 0 ? html.substring(Math.max(0, titleIdx - 800), titleIdx) : '';
      var coverM = snippet.match(/<img[^>]+src="([^"]+\.(?:jpg|jpeg|png|webp))"/i);
      var cover = coverM ? absUrl(coverM[1], SITE) : null;

      results.push({
        id: _idFromUrl(link),
        title: title,
        cover: cover,
        url: link,
        type: 'novel'
      });
    }
    console.log('freewebnovel search count: ' + results.length);
    return results;
  });
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

function _parseMetaField(html, label) {
  // FreeWebNovel meta rows look like:
  //   <span class="s1">Status<em>:</em></span><span class="s2"><a>...</a></span>
  // or  <span>Status</span><span><a>Ongoing</a></span>
  var re = new RegExp(
    '<span[^>]*>\\s*' + label + '\\s*(?:<em>:</em>)?\\s*</span>\\s*<span[^>]*>([\\s\\S]*?)</span>',
    'i'
  );
  var m = html.match(re);
  return m ? m[1] : '';
}

function getDetail(url) {
  console.log('freewebnovel detail url: ' + url);
  return fetch(url, { headers: { 'Referer': REFERER } }).then(function(r) {
    var html = r.body || '';

    var titleM = html.match(/<h1[^>]*>([\s\S]*?)<\/h1>/);
    var title = titleM ? _cleanText(titleM[1]) : '';

    // Cover lives under /files/article/image/... or /files/article/...
    var coverM = html.match(/<img[^>]+src="(\/files\/article\/[^"]+\.(?:jpg|jpeg|png|webp))"/i);
    var cover = coverM ? absUrl(coverM[1], SITE) : null;

    // Description is inside the m-desc panel — pluck paragraphs.
    var descM = html.match(/<div[^>]+class="m-desc"[^>]*>([\s\S]*?)<\/div>\s*<\/div>/i);
    if (!descM) descM = html.match(/<div[^>]+class="inner"[^>]*>([\s\S]*?)<\/div>/i);
    var description = descM ? _cleanText(descM[1]) : '';

    // Strip leading "Description" label if the cleaner left it in.
    description = description.replace(/^Description\s+/i, '');

    var statusRaw = _parseLinks(_parseMetaField(html, 'Status'));
    var status = _normalizeStatus(statusRaw.length ? statusRaw[0] : '');
    var authors = _parseLinks(_parseMetaField(html, 'Author'));
    var genres = _parseLinks(_parseMetaField(html, 'Genre'));
    if (genres.length === 0) genres = _parseLinks(_parseMetaField(html, 'Genres'));
    if (genres.length === 0) genres = _parseLinks(_parseMetaField(html, 'Tags'));

    var chapters = _parseChapters(html);
    console.log('freewebnovel detail: title=' + title + ' chapters=' + chapters.length + ' status=' + status);
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
}

function _parseChapters(html) {
  var out = [];
  var seen = {};
  // FreeWebNovel renders the full chapter list inline; URLs look like
  //   /novel/<slug>/chapter-<n>
  var re = /<a[^>]+href="(\/novel\/[^"]+\/chapter-[0-9]+(?:-[a-z0-9]+)?)"[^>]*(?:title="([^"]+)")?[^>]*>([\s\S]*?)<\/a>/gi;
  var matches = _allMatches(html, re);
  for (var i = 0; i < matches.length; i++) {
    var link = absUrl(matches[i][1], SITE);
    if (seen[link]) continue;
    seen[link] = true;
    var rawTitle = _cleanText(matches[i][2] || matches[i][3] || '');
    if (!rawTitle) {
      var fromUrl = matches[i][1].match(/chapter-([0-9]+(?:-[a-z0-9]+)?)/i);
      rawTitle = fromUrl ? 'Chapter ' + fromUrl[1].replace(/-/g, ' ') : '';
    }
    var numMatch = rawTitle.match(/chapter\s*([0-9]+(?:\.[0-9]+)?)/i);
    if (!numMatch) numMatch = (matches[i][1].match(/chapter-([0-9]+)/i) || [null, null]);
    var num = numMatch && numMatch[1] ? parseFloat(numMatch[1]) : null;
    out.push({
      id: _idFromUrl(link),
      title: rawTitle,
      number: isNaN(num) ? null : num,
      url: link,
      date: ''
    });
  }
  // Sort by chapter number ascending so the reader's "next" matches the
  // reader's expectations. Unnumbered chapters keep their relative order.
  out.sort(function(a, b) {
    if (a.number == null && b.number == null) return 0;
    if (a.number == null) return -1;
    if (b.number == null) return 1;
    return a.number - b.number;
  });
  return out;
}

function getChapters(url) {
  return fetch(url, { headers: { 'Referer': REFERER } }).then(function(r) {
    return _parseChapters(r.body || '');
  });
}

function getPages(chapterUrl) {
  return [];
}

function getChapterContent(chapterUrl) {
  console.log('freewebnovel chapter url: ' + chapterUrl);
  return fetch(chapterUrl, { headers: { 'Referer': REFERER } }).then(function(r) {
    var html = r.body || '';
    // The text sits between two marker divs.
    var bodyM = html.match(/<div\s+class="chapter-start"[^>]*><\/div>([\s\S]*?)<div\s+class="chapter-end"/i);
    var content = bodyM ? bodyM[1] : '';

    // Strip ads/scripts.
    content = content.replace(/<script[\s\S]*?<\/script>/gi, '');
    content = content.replace(/<div[^>]*class="read-ads[\s\S]*?<\/div>/gi, '');
    content = content.replace(/<div[^>]*id="bg-ssp[\s\S]*?<\/div>/gi, '');
    content = content.replace(/<ins[\s\S]*?<\/ins>/gi, '');

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

    // Next-chapter link — FreeWebNovel uses a plain anchor with text "Next"
    // inside a paging block at the end of the chapter.
    var nextUrl = null;
    var nextMatches = _allMatches(
      html,
      /<a[^>]+href="(\/novel\/[^"]+\/chapter-[^"]+)"[^>]*>[^<]*(?:Next|next)[^<]*<\/a>/g
    );
    if (nextMatches.length > 0) {
      nextUrl = absUrl(nextMatches[0][1], SITE);
    }
    if (!nextUrl) {
      // Numeric heuristic: bump the trailing chapter number by 1.
      var bumpM = chapterUrl.match(/(.+\/chapter-)(\d+)([^\/?#]*)$/i);
      if (bumpM) {
        var nxt = parseInt(bumpM[2], 10) + 1;
        // Drop the trailing slug — FreeWebNovel resolves chapter-N
        // without the suffix.
        nextUrl = bumpM[1] + nxt;
      }
    }
    return { text: text, nextUrl: nextUrl };
  });
}
