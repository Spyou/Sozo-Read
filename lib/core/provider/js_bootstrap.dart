/// Shared JS bootstrap loaded **once** into a single QuickJS runtime that
/// hosts every provider as `__providers[sourceId]`. flutter_js binds each
/// message channel to one runtime (last writer wins), so multi-runtime
/// designs deadlock — this design uses ONE runtime and routes by sourceId
/// inside the payload.
const String kJsBootstrap = r'''
var __pendingFetches = {};
var __fetchSeq = 0;
globalThis.__providers = globalThis.__providers || {};

function __nextFetchId() {
  __fetchSeq += 1;
  return 'f' + __fetchSeq;
}

globalThis.__resolveFetch = function(id, responseJson) {
  var p = __pendingFetches[id];
  if (!p) return;
  delete __pendingFetches[id];
  try {
    var parsed = JSON.parse(responseJson);
    p.resolve(parsed);
  } catch (e) {
    p.reject('Invalid fetch response JSON: ' + e);
  }
};

globalThis.__rejectFetch = function(id, reason) {
  var p = __pendingFetches[id];
  if (!p) return;
  delete __pendingFetches[id];
  p.reject(reason);
};

/// Generic fetch — providers wrap this so they can inject their own sourceId.
globalThis.__fetch = function(src, url, opts) {
  opts = opts || {};
  var id = __nextFetchId();
  var payload = {
    __src: src,
    id: id,
    url: url,
    method: (opts.method || 'GET').toUpperCase(),
    headers: opts.headers || {},
    body: opts.body == null ? null : (typeof opts.body === 'string' ? opts.body : JSON.stringify(opts.body)),
    responseType: opts.responseType || 'text'
  };
  var promise = new Promise(function(resolve, reject) {
    __pendingFetches[id] = { resolve: resolve, reject: reject };
  });
  sendMessage('fetch', JSON.stringify(payload));
  return promise.then(function(res) {
    return {
      ok: res.status >= 200 && res.status < 300,
      status: res.status,
      statusText: res.statusText || '',
      headers: res.headers || {},
      url: res.url || url,
      text: function() { return Promise.resolve(res.body || ''); },
      json: function() {
        try { return Promise.resolve(JSON.parse(res.body || 'null')); }
        catch (e) { return Promise.reject('Invalid JSON: ' + e); }
      },
      body: res.body || ''
    };
  });
};

globalThis.__console = function(src, level, args) {
  try {
    var parts = [];
    for (var i = 0; i < args.length; i++) {
      var a = args[i];
      parts.push(typeof a === 'string' ? a : JSON.stringify(a));
    }
    sendMessage('console', JSON.stringify({ __src: src, level: level, message: parts.join(' ') }));
  } catch (e) {}
};

if (typeof globalThis.btoa !== 'function') {
  globalThis.btoa = function(str) {
    var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=';
    var out = '', i = 0;
    while (i < str.length) {
      var c1 = str.charCodeAt(i++) & 0xff;
      var c2 = i < str.length ? str.charCodeAt(i++) & 0xff : NaN;
      var c3 = i < str.length ? str.charCodeAt(i++) & 0xff : NaN;
      var e1 = c1 >> 2;
      var e2 = ((c1 & 3) << 4) | (c2 >> 4);
      var e3 = isNaN(c2) ? 64 : (((c2 & 15) << 2) | (c3 >> 6));
      var e4 = isNaN(c3) ? 64 : (c3 & 63);
      out += chars.charAt(e1) + chars.charAt(e2) + chars.charAt(e3) + chars.charAt(e4);
    }
    return out;
  };
}

/// Invokes `__providers[sourceId][method](...args)` and resolves to a JSON
/// string. Always returns a Promise.
globalThis.__callProvider = function(sourceId, method, argsJson) {
  var args;
  try { args = JSON.parse(argsJson || '[]'); }
  catch (e) { return Promise.reject('Bad argsJson: ' + e); }
  var ns = globalThis.__providers[sourceId];
  if (!ns) return Promise.reject('Provider not loaded: ' + sourceId);
  var fn = ns[method];
  if (typeof fn !== 'function') {
    return Promise.reject('Provider ' + sourceId + ' missing method: ' + method);
  }
  function stringifyErr(e) {
    if (!e) return 'unknown error';
    if (typeof e === 'string') return e;
    if (e instanceof Error) return e.message || String(e);
    if (typeof e === 'object' && e.message) return String(e.message);
    try { return JSON.stringify(e); } catch (_) { return String(e); }
  }
  try {
    var r = fn.apply(null, args);
    return Promise.resolve(r)
      .then(function(v) { return JSON.stringify(v == null ? null : v); })
      .catch(function(e) { return Promise.reject(stringifyErr(e)); });
  } catch (e) {
    return Promise.reject(stringifyErr(e));
  }
};

// HTML helpers shared by all providers.
globalThis.htmlText = function(html) {
  if (!html) return '';
  return String(html).replace(/<[^>]*>/g, '').replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'").trim();
};

globalThis.absUrl = function(href, base) {
  if (!href) return '';
  if (/^https?:\/\//i.test(href)) return href;
  if (href.startsWith('//')) return 'https:' + href;
  if (!base) return href;
  if (href.startsWith('/')) {
    var m = base.match(/^(https?:\/\/[^\/]+)/i);
    return m ? m[1] + href : href;
  }
  return base.replace(/\/$/, '') + '/' + href;
};
''';

/// Wraps a provider's JS source so it lives inside its own namespace.
/// Defines local `fetch` and `console` that carry the provider's sourceId
/// into the global bridge.
String wrapProviderSource(String sourceId, String providerJs) {
  final src = sourceId.replaceAll("'", r"\'");
  return '''
(function(){
  var __SOURCE_ID = '$src';
  var fetch = function(url, opts) { return globalThis.__fetch(__SOURCE_ID, url, opts); };
  var console = {
    log:   function() { globalThis.__console(__SOURCE_ID, 'log', arguments); },
    warn:  function() { globalThis.__console(__SOURCE_ID, 'warn', arguments); },
    error: function() { globalThis.__console(__SOURCE_ID, 'error', arguments); },
    info:  function() { globalThis.__console(__SOURCE_ID, 'info', arguments); },
    debug: function() { globalThis.__console(__SOURCE_ID, 'debug', arguments); }
  };
  $providerJs
  globalThis.__providers['$src'] = {
    getInfo:           typeof getInfo === 'function' ? getInfo : null,
    search:            typeof search === 'function' ? search : null,
    getDetail:         typeof getDetail === 'function' ? getDetail : null,
    getChapters:       typeof getChapters === 'function' ? getChapters : null,
    getPages:          typeof getPages === 'function' ? getPages : null,
    getChapterContent: typeof getChapterContent === 'function' ? getChapterContent : null
  };
})();
''';
}
