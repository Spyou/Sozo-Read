// Node test harness for JS providers.
// Usage:
//   node providers/_test.mjs mangakakalot "one piece"
//
// Replicates the Dart bootstrap (htmlText/absUrl + console). Node 18+ has fetch.

import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';

const __dirname = path.dirname(url.fileURLToPath(import.meta.url));

const provider = process.argv[2] || 'mangakakalot';
const query = process.argv[3] || 'one piece';

// --- minimal bootstrap (mirrors js_bootstrap.dart) -------------------------
globalThis.htmlText = function (html) {
  if (!html) return '';
  return String(html).replace(/<[^>]*>/g, '').replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'").trim();
};
globalThis.absUrl = function (href, base) {
  if (!href) return '';
  if (/^https?:\/\//i.test(href)) return href;
  if (href.startsWith('//')) return 'https:' + href;
  if (!base) return href;
  if (href.startsWith('/')) {
    const m = base.match(/^(https?:\/\/[^\/]+)/i);
    return m ? m[1] + href : href;
  }
  return base.replace(/\/$/, '') + '/' + href;
};

// Wrap fetch so the Response's .body is an already-read text string,
// matching how the Dart bridge presents it to providers.
const realFetch = globalThis.fetch;
globalThis.fetch = async function (u, opts) {
  opts = opts || {};
  const headers = Object.assign({
    'User-Agent': 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36',
    'Accept': '*/*',
    'Accept-Language': 'en-US,en;q=0.9'
  }, opts.headers || {});
  const r = await realFetch(u, { method: opts.method || 'GET', headers, body: opts.body });
  const text = await r.text();
  return {
    ok: r.ok,
    status: r.status,
    statusText: r.statusText,
    url: r.url,
    headers: Object.fromEntries(r.headers.entries()),
    body: text,
    text: async () => text,
    json: async () => JSON.parse(text)
  };
};

// --- load provider ---------------------------------------------------------
const src = fs.readFileSync(path.join(__dirname, provider + '.js'), 'utf8');
const wrapper = new Function(src + `
  return { getInfo, search, getDetail, getChapters, getPages, getChapterContent };
`);
const api = wrapper();

// --- run test --------------------------------------------------------------
const trunc = (s, n = 80) => (s == null ? '' : String(s).length > n ? String(s).slice(0, n) + '…' : String(s));

async function run() {
  console.log(`\n==== ${provider} ====`);
  console.log('getInfo:', api.getInfo());

  console.log(`\n-- search("${query}") --`);
  const t0 = Date.now();
  const results = await api.search(query, 1);
  console.log(`  ${results.length} results in ${Date.now() - t0}ms`);
  results.slice(0, 5).forEach((b, i) => {
    console.log(`  [${i + 1}] ${trunc(b.title, 60)}  |  ${b.url}`);
  });
  if (results.length === 0) {
    console.log('  (no results — check selectors / URL)');
    return;
  }

  console.log('\n-- getDetail --');
  const t1 = Date.now();
  const detail = await api.getDetail(results[0].url);
  console.log(`  "${trunc(detail.title, 60)}"  status=${detail.status}  chapters=${detail.chapters.length}  in ${Date.now() - t1}ms`);
  console.log(`  desc: ${trunc(detail.description, 120)}`);
  console.log(`  genres: ${detail.genres.slice(0, 6).join(', ')}`);

  if (detail.chapters.length === 0) {
    console.log('  (no chapters — check chapter selectors)');
    return;
  }

  // Try a few chapters (latest is often external/licensed).
  const candidates = [
    detail.chapters[0],
    detail.chapters[Math.min(10, detail.chapters.length - 1)],
    detail.chapters[Math.floor(detail.chapters.length / 2)],
    detail.chapters[detail.chapters.length - 1]
  ].filter(Boolean);

  for (const ch of candidates) {
    console.log(`\n-- getPages for "${trunc(ch.title, 50)}" --`);
    const t2 = Date.now();
    try {
      const pages = await api.getPages(ch.url);
      console.log(`  ${pages.length} pages in ${Date.now() - t2}ms`);
      pages.slice(0, 3).forEach((p, i) => console.log(`  [${i + 1}] ${p.url}`));
      if (pages.length > 0) break;
    } catch (e) {
      console.log(`  failed: ${e.message}`);
    }
  }
}

run().catch(e => {
  console.error('FAILED:', e);
  process.exit(1);
});
