// Tests the SHARED-RUNTIME design: one JS context hosting BOTH providers as
// __providers[sourceId]. Mirrors what flutter_js will do at runtime.

import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';
const __dirname = path.dirname(url.fileURLToPath(import.meta.url));

// --- shared bootstrap (mirrors kJsBootstrap) -------------------------------
const bootstrap = `
var __pendingFetches = {};
var __fetchSeq = 0;
globalThis.__providers = globalThis.__providers || {};
function __nextFetchId(){ __fetchSeq+=1; return 'f'+__fetchSeq; }
globalThis.__fetch = async function(src, u, opts) {
  opts = opts || {};
  const headers = Object.assign({
    'User-Agent': 'Mozilla/5.0 Chrome/120.0',
    'Accept': '*/*'
  }, opts.headers || {});
  const r = await fetch(u, { method: opts.method||'GET', headers, body: opts.body });
  const text = await r.text();
  return {
    ok: r.ok, status: r.status, statusText: r.statusText,
    headers: Object.fromEntries(r.headers.entries()), url: r.url, body: text,
    text: async () => text,
    json: async () => JSON.parse(text)
  };
};
globalThis.__console = function(src, level, args){
  const parts = [];
  for (let i=0;i<args.length;i++){ const a=args[i]; parts.push(typeof a==='string'?a:JSON.stringify(a)); }
  console.log('['+src+'/js '+level+']', parts.join(' '));
};
globalThis.htmlText = s => String(s||'').replace(/<[^>]*>/g,'').replace(/&nbsp;/g,' ').replace(/&amp;/g,'&').replace(/&lt;/g,'<').replace(/&gt;/g,'>').replace(/&quot;/g,'"').replace(/&#39;/g,"'").trim();
globalThis.absUrl = (h,b) => /^https?:\\/\\//i.test(h) ? h : (h.startsWith('//') ? 'https:'+h : (b ? (h.startsWith('/') ? (b.match(/^(https?:\\/\\/[^\\/]+)/)[1]+h) : (b.replace(/\\/$/,'')+'/'+h)) : h));
globalThis.__callProvider = function(sourceId, method, argsJson){
  let args; try { args = JSON.parse(argsJson||'[]'); } catch(e){ return Promise.reject('bad args'); }
  const ns = globalThis.__providers[sourceId];
  if (!ns) return Promise.reject('not loaded: '+sourceId);
  const fn = ns[method];
  if (typeof fn !== 'function') return Promise.reject('missing method: '+method);
  try { return Promise.resolve(fn.apply(null, args)).then(v => JSON.stringify(v==null?null:v)); }
  catch(e){ return Promise.reject(String(e.message||e)); }
};
`;

function wrap(sourceId, src) {
  return `
(function(){
  var __SOURCE_ID = '${sourceId}';
  var fetch = function(u,o){ return globalThis.__fetch(__SOURCE_ID, u, o); };
  var console = {
    log: function(){ globalThis.__console(__SOURCE_ID, 'log', arguments); },
    warn: function(){ globalThis.__console(__SOURCE_ID, 'warn', arguments); },
    error: function(){ globalThis.__console(__SOURCE_ID, 'error', arguments); }
  };
  ${src}
  globalThis.__providers['${sourceId}'] = {
    getInfo, search, getDetail, getChapters, getPages, getChapterContent
  };
})();
`;
}

eval(bootstrap);

const mdSrc = fs.readFileSync(path.join(__dirname, 'mangadex.js'), 'utf8');
const mkSrc = fs.readFileSync(path.join(__dirname, 'mangakakalot.js'), 'utf8');
eval(wrap('mangadex', mdSrc));
eval(wrap('mangakakalot', mkSrc));

console.log('\nLoaded providers:', Object.keys(globalThis.__providers));

for (const sid of ['mangadex', 'mangakakalot']) {
  console.log(`\n=== ${sid} ===`);
  const infoJson = await globalThis.__callProvider(sid, 'getInfo', '[]');
  console.log('getInfo:', JSON.parse(infoJson).name);
  const t0 = Date.now();
  const searchJson = await globalThis.__callProvider(sid, 'search', '["", 1]');
  const results = JSON.parse(searchJson);
  console.log(`search("") -> ${results.length} results in ${Date.now()-t0}ms`);
  results.slice(0,3).forEach((b,i)=>console.log(`  [${i+1}] ${b.title}`));
}
