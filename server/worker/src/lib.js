// RAM Doctor relay - core logic (protocol v1).
//
// The relay accepts a small, already-redacted report bundle from the RAM Doctor client and commits it to a PRIVATE
// GitHub data repository, so the person helping can read it.
//
//   THERE IS NO READ ROUTE. The Worker can only append new report folders: a stranger who finds the endpoint can at
//   worst send rate-limited, sanitised junk. Nobody can read, list, modify or delete anything through it.
//
// Modes
//  * OPEN mode (default): no invite code needed. Because anybody who finds the URL can POST, it needs the KV rate
//    limiter (binding RATE); without it the relay answers 503 (fail closed) - except /v1/health.
//  * CODE mode: if the INVITE_CODES secret is set (or REQUIRE_CODE=true) every upload must carry a valid code.
//  * Kill switch: DISABLED=1 makes uploads answer 503 immediately.
//
// Design rules
//  * Fail closed, generic errors. Secrets and report contents are never echoed and never logged.
//  * One credential only: a fine-grained PAT scoped to the single data repo (secret GITHUB_TOKEN).
//  * Paths are built only from validated pieces (slug [a-z0-9-], hex userId, server timestamp + random suffix,
//    whitelisted file names) and asserted against a strict regex before every commit.
//  * Retries are safe: a client may send a requestId; the same id again returns the first result (no second commit).
//    The per-user quota is counted only after a successful commit.
//  * Uploaded files are inspected: plan.json must be a bounded JSON object, summary.md is sanitised, report.html is
//    accepted only if it looks like our generator's output AND is inert (no external loads, no active content).
//  * Pure ES modules, no npm runtime dependencies. Runs on Cloudflare Workers and on Node >= 18 (tests).

export const PROTOCOL_VERSION = 1;
export const MAX_BODY_BYTES = 2 * 1024 * 1024; // whole request body
export const MAX_FILE_BYTES = Math.floor(1.5 * 1024 * 1024); // absolute cap for any one file (UTF-8 bytes)
export const FILE_CAPS = Object.freeze({
  'summary.md': 128 * 1024,
  'report.html': 512 * 1024,
  'plan.json': 512 * 1024,
});
export const ALLOWED_FILES = Object.freeze(['summary.md', 'report.html', 'plan.json']);
export const LIMITS = Object.freeze({ perIpPerHour: 6, perIpPerDay: 20, perUserPerHour: 10, perUserPerDay: 20 });
export const REPORT_MARKER = '<!-- ram-doctor-report';
export const MAX_SCRIPT_BYTES = 3 * 1024;
export const REQUEST_TTL_SECONDS = 24 * 3600; // how long a requestId is remembered (KV)
export const PENDING_STALE_MS = 120 * 1000; // an unfinished upload older than this is checked against GitHub
export const IN_PROGRESS_RETRY_SECONDS = 10;

const MAX_PLAN_DEPTH = 10;
const MAX_PLAN_NODES = 50000;
const MAX_PLAN_SUSPECTS = 200;
const MAX_PLAN_STRING = 20000;

const HOUR_MS = 3600 * 1000;
const DAY_MS = 24 * HOUR_MS;
const BOT_NAME = 'ram-doctor-relay[bot]';
const BOT_EMAIL = 'ram-doctor-relay@users.noreply.github.com';

const RE_USER_ID = /^[0-9a-f]{8}$/;
const RE_REQUEST_ID = /^[A-Za-z0-9-]{16,64}$/; // client-generated, e.g. a GUID; the same id is sent again on retries
const RE_CODE = /^[\x21-\x7E]{1,128}$/; // printable ASCII, no spaces
const RE_CONFIGURED_CODE = /^[\x21-\x7E]{6,128}$/;
const RE_VERSION = /^\d{1,4}\.\d{1,4}\.\d{1,4}(?:[-+][0-9A-Za-z.-]{1,32})?$/;
const RE_CREATED_AT = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?Z$/;
const RE_HOST = /^[\p{L}\p{Nd}][\p{L}\p{Nd} ._-]{0,62}$/u;
const RE_GH_NAME = /^[A-Za-z0-9_.-]{1,100}$/;
const RE_BRANCH = /^[A-Za-z0-9._\/-]{1,100}$/;
const RE_LABEL = /^[\p{L}\p{Nd} _.-]{0,40}$/u;
const RE_LONE_SURROGATE = /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/;
// control chars, whitespace, zero-width / bidi marks and line separators that browsers strip inside URL schemes
const RE_URL_JUNK = new RegExp('[\\u0000-\\u0020\\u007f-\\u009f\\u200b-\\u200f\\u2028\\u2029\\ufeff]', 'g');
// Final safety net: every path we ever send to GitHub must match this. The upload folder is the server's UTC time plus
// 6 random characters, so two uploads in the same second never share (and never replace) a folder.
const RE_SAFE_FOLDER = /^reports\/[a-z0-9]+(?:-[a-z0-9]+)*-[0-9a-f]{8}\/\d{8}-\d{6}-[a-z0-9]{6}$/;
const RE_SAFE_PATH =
  /^reports\/[a-z0-9]+(?:-[a-z0-9]+)*-[0-9a-f]{8}\/\d{8}-\d{6}-[a-z0-9]{6}\/(?:summary\.md|report\.html|plan\.json|meta\.json)$/;
const SUFFIX_ALPHABET = 'abcdefghijklmnopqrstuvwxyz0123456789';

// Display name: 2-24 code points; Arabic or Latin letters, combining marks, decimal digits, space, "_" and "-";
// no leading/trailing space.
const NAME_CHAR = '(?:(?=[\\p{Script=Arabic}\\p{Script=Latin}])\\p{L}|\\p{Mn}|\\p{Nd}|[ _-])';
const RE_DISPLAY_NAME = new RegExp('^(?! )' + NAME_CHAR + '{2,24}(?<! )$', 'u');

const encoder = new TextEncoder();
const decoder = new TextDecoder('utf-8', { fatal: true });

// ---------------------------------------------------------------------------------------------- errors

export class HttpError extends Error {
  constructor(status, code, extra) {
    super(code);
    this.name = 'HttpError';
    this.status = status;
    this.code = code;
    this.extra = extra || {};
  }
}

export class GitHubError extends Error {
  constructor(status, step, detail) {
    super('github_' + status);
    this.name = 'GitHubError';
    this.status = status;
    this.step = step || '';       // which API call failed, e.g. "POST /git/trees" (never contains file contents)
    this.detail = detail || '';   // GitHub's own error message, truncated; useful to the helper when reading the logs
  }
}

// ---------------------------------------------------------------------------------------------- helpers

/** Log metadata only. Never pass tokens, invite codes or report contents here. */
export function log(event, fields) {
  try {
    console.log(JSON.stringify(Object.assign({ event: event }, fields || {})));
  } catch (_) {
    /* logging must never break a request */
  }
}

export function jsonResponse(status, obj, headers) {
  const h = new Headers({
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
  });
  if (headers) for (const k of Object.keys(headers)) h.set(k, headers[k]);
  return new Response(JSON.stringify(obj), { status: status, headers: h });
}

function errorResponse(err) {
  const body = { ok: false, error: err.code };
  if (err.extra && err.extra.field) body.field = err.extra.field;
  const headers = {};
  if (err.extra && err.extra.retryAfter) headers['Retry-After'] = String(err.extra.retryAfter);
  if (err.extra && err.extra.allow) headers['Allow'] = err.extra.allow;
  return jsonResponse(err.status, body, headers);
}

function truthy(v) {
  return ['1', 'true', 'yes', 'on'].indexOf(String(v === undefined || v === null ? '' : v).trim().toLowerCase()) !== -1;
}

/** yyyyMMdd-HHmmss in UTC. */
export function utcStamp(ms) {
  const d = new Date(ms);
  const p = (n, w) => String(n).padStart(w || 2, '0');
  return (
    p(d.getUTCFullYear(), 4) + p(d.getUTCMonth() + 1) + p(d.getUTCDate()) + '-' +
    p(d.getUTCHours()) + p(d.getUTCMinutes()) + p(d.getUTCSeconds())
  );
}

/** 6 random characters [a-z0-9]: the part of the folder name that keeps same-second uploads apart. */
export function folderSuffix() {
  const b = new Uint8Array(6);
  crypto.getRandomValues(b);
  let s = '';
  for (let i = 0; i < b.length; i++) s += SUFFIX_ALPHABET[b[i] % SUFFIX_ALPHABET.length];
  return s;
}

/** ASCII-safe slug (max 20 chars). Arabic-only (or otherwise non-Latin) names fall back to "user". */
export function slugify(name) {
  const s = String(name)
    .normalize('NFKD')
    .replace(/[\u0300-\u036F]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 20)
    .replace(/-+$/, '');
  return s || 'user';
}

function isPlainObject(o) {
  return o !== null && typeof o === 'object' && !Array.isArray(o) && Object.getPrototypeOf(o) === Object.prototype;
}

function wellFormed(str) {
  return typeof str.isWellFormed === 'function' ? str.isWellFormed() : !RE_LONE_SURROGATE.test(str);
}

function byteLength(str) {
  return encoder.encode(str).length;
}

function hasKv(kv) {
  return !!kv && typeof kv.get === 'function' && typeof kv.put === 'function';
}

// ---------------------------------------------------------------------------------------------- validation

function bad(field) {
  return { ok: false, status: 400, code: 'invalid_request', field: field };
}

/**
 * Strict schema check for protocol v1. Returns { ok:true, value } or { ok:false, status, code, field }.
 * `field` is a fixed vocabulary word (never client data). `code` (invite code) and `requestId` (idempotency key, sent
 * unchanged on every retry of one upload) are optional in the body.
 */
export function validatePayload(o) {
  if (!isPlainObject(o)) return bad('body');
  const allowed = ['v', 'displayName', 'userId', 'code', 'requestId', 'tool', 'createdAt', 'host', 'files'];
  for (const k of Object.keys(o)) if (allowed.indexOf(k) === -1) return bad('unknown_field');

  // Cheap length gates come first so no regex ever sees a huge attacker-controlled string.
  if (o.v !== PROTOCOL_VERSION) return bad('v');
  if (typeof o.displayName !== 'string' || o.displayName.length > 64 || !RE_DISPLAY_NAME.test(o.displayName)) return bad('displayName');
  if (typeof o.userId !== 'string' || o.userId.length !== 8 || !RE_USER_ID.test(o.userId)) return bad('userId');
  // optional; '' is treated like "no code" (clients that have no code configured may send an empty string)
  if (o.code !== undefined && (typeof o.code !== 'string' || o.code.length > 128 || (o.code !== '' && !RE_CODE.test(o.code)))) return bad('code');
  // optional (1.0.x clients do not send it); when present it must be well-formed
  if (o.requestId !== undefined && (typeof o.requestId !== 'string' || o.requestId.length > 64 || !RE_REQUEST_ID.test(o.requestId))) return bad('requestId');

  if (!isPlainObject(o.tool)) return bad('tool');
  for (const k of Object.keys(o.tool)) if (k !== 'name' && k !== 'version') return bad('tool');
  if (o.tool.name !== 'RAM-Doctor') return bad('tool');
  if (typeof o.tool.version !== 'string' || o.tool.version.length > 48 || !RE_VERSION.test(o.tool.version)) return bad('tool');

  if (typeof o.createdAt !== 'string' || o.createdAt.length > 40 || !RE_CREATED_AT.test(o.createdAt) || !Number.isFinite(Date.parse(o.createdAt))) {
    return bad('createdAt');
  }
  if (typeof o.host !== 'string' || o.host.length > 64 || !(o.host === '<PC>' || RE_HOST.test(o.host))) return bad('host');

  if (!Array.isArray(o.files) || o.files.length < 1 || o.files.length > ALLOWED_FILES.length) return bad('files');
  const seen = new Set();
  const files = [];
  for (const f of o.files) {
    if (!isPlainObject(f)) return bad('files');
    for (const k of Object.keys(f)) if (k !== 'name' && k !== 'content') return bad('files');
    if (typeof f.name !== 'string' || ALLOWED_FILES.indexOf(f.name) === -1 || seen.has(f.name)) return bad('files');
    if (typeof f.content !== 'string') return bad('files');
    // UTF-8 bytes >= UTF-16 code units, so oversize files are rejected without encoding or scanning them at all.
    if (f.content.length > FILE_CAPS[f.name] || f.content.length > MAX_FILE_BYTES) return { ok: false, status: 413, code: 'too_large', field: 'files' };
    if (f.content.indexOf('\u0000') !== -1 || !wellFormed(f.content)) return bad('files');
    const bytes = byteLength(f.content);
    if (bytes > MAX_FILE_BYTES) return { ok: false, status: 413, code: 'too_large', field: 'files' };
    seen.add(f.name);
    files.push({ name: f.name, content: f.content, bytes: bytes });
  }

  return {
    ok: true,
    value: {
      displayName: o.displayName,
      userId: o.userId,
      code: typeof o.code === 'string' ? o.code : '',
      requestId: typeof o.requestId === 'string' ? o.requestId : '',
      tool: { name: o.tool.name, version: o.tool.version },
      createdAt: o.createdAt,
      host: o.host,
      files: files,
    },
  };
}

// ---------------------------------------------------------------------------------------------- content inspection

const PLACEHOLDER_DIV = '\uE000';
const PLACEHOLDER_ENDDIV = '\uE001';
const PLACEHOLDER_BR = '\uE002';

/**
 * summary.md: keep plain Markdown plus exactly <div dir="rtl">, </div> and <br>; neutralise every other "<" (so no
 * HTML tag can form), dangerous link schemes and remote images. Returns the sanitised text.
 */
export function sanitizeSummary(text) {
  let s = String(text).replace(/[\uE000-\uE0FF]/g, ''); // private-use chars could spoof our placeholders
  s = s
    .replace(/<div dir="rtl">/g, PLACEHOLDER_DIV)
    .replace(/<\/div>/g, PLACEHOLDER_ENDDIV)
    .replace(/<br\s?\/?>/g, PLACEHOLDER_BR);
  s = s.replace(/</g, '&lt;');
  s = s.replace(/(\]\([ \t]{0,8}|\]:[ \t]{0,8})(?:javascript|vbscript|data|file|blob)[ \t]{0,8}:/gi, '$1blocked:'); // bounded: no backtracking blow-up
  s = s.replace(/!\[/g, '\\!\\[');
  return s
    .split(PLACEHOLDER_DIV).join('<div dir="rtl">')
    .split(PLACEHOLDER_ENDDIV).join('</div>')
    .split(PLACEHOLDER_BR).join('<br>');
}

/** plan.json: must be a bounded JSON object with the keys our generator always writes. */
export function checkPlanJson(text) {
  const no = (reason) => ({ ok: false, reason: reason });
  let root;
  try {
    root = JSON.parse(text);
  } catch (_) {
    return no('json');
  }
  if (!isPlainObject(root)) return no('root');
  if (root.tool !== 'RAM-Doctor') return no('tool');
  if (typeof root.version !== 'string' || root.version.length > 32) return no('version');
  if (!Array.isArray(root.suspects) || root.suspects.length > MAX_PLAN_SUSPECTS) return no('suspects');
  if (!isPlainObject(root.verdict)) return no('verdict');
  if (root.observations !== undefined && !Array.isArray(root.observations)) return no('observations');
  if (root.memory !== undefined && !isPlainObject(root.memory)) return no('memory');

  let nodes = 0;
  const stack = [{ v: root, d: 1 }];
  while (stack.length) {
    const it = stack.pop();
    if (++nodes > MAX_PLAN_NODES) return no('nodes');
    if (it.d > MAX_PLAN_DEPTH) return no('depth');
    const v = it.v;
    if (typeof v === 'string') {
      if (v.length > MAX_PLAN_STRING) return no('string');
    } else if (Array.isArray(v)) {
      for (const x of v) stack.push({ v: x, d: it.d + 1 });
    } else if (v !== null && typeof v === 'object') {
      for (const k of Object.keys(v)) {
        if (k === '__proto__' || k === 'constructor' || k === 'prototype') return no('key');
        stack.push({ v: v[k], d: it.d + 1 });
      }
    }
  }
  return { ok: true };
}

// ---- report.html inspection ------------------------------------------------------------------------------------
// CPU budget note: a free Cloudflare Worker has ~10 ms of CPU per request. Nothing below uses a regex that can
// backtrack catastrophically on attacker-controlled text: the HTML check is ONE linear tokenizer built on indexOf and
// charCodeAt (every position is visited a bounded number of times), CSS comments are stripped with indexOf, and the
// remaining regexes are anchored, bounded ({0,n}) or literal-prefixed.

const SCRIPT_FORBIDDEN = [
  /\bfetch\b/, /XMLHttpRequest/, /WebSocket/, /sendBeacon/, /\beval\b/, /\bFunction\s{0,8}\(/, /\bimport\b/,
  /document\s{0,8}\.\s{0,8}write/, /\blocation\b/, /window\s{0,8}\.\s{0,8}open/, /innerHTML/, /outerHTML/, /insertAdjacentHTML/,
  /\.\s{0,8}src\s{0,8}=/, /\.\s{0,8}href\s{0,8}=/, /\.\s{0,8}(?:srcdoc|action|formAction)\s{0,8}=/, /document\s{0,8}\.\s{0,8}cookie/,
  /EventSource/, /importScripts/, /\bnew\s{1,8}Worker\b/, /\bpostMessage\b/, /\bcreateElement(?:NS)?\b/, /\bimportNode\b/,
  /setAttribute\s{0,8}\(\s{0,8}['"]\s{0,8}(?:src|href|srcdoc|on\w{0,30})\b/i, /\bset(?:Timeout|Interval)\s{0,8}\(\s{0,8}['"`]/,
];
const SCRIPT_URL = /(?:https?|ftp|wss?|file):\/\//i;
const DENY_TAGS = new Set([
  'iframe', 'object', 'embed', 'form', 'base', 'link', 'applet', 'frame', 'frameset', 'portal', 'audio', 'video',
  'source', 'track', 'animate', 'set', 'animatemotion', 'animatetransform', 'foreignobject', 'math', 'xmp', 'plaintext',
]);
// URL-bearing attributes are the ACTIVE contexts. URLs written as plain text (command lines, download cradles, pool
// addresses...) are legitimate content of a malware-triage report and are never inspected.
const URL_ATTRS = new Set(['href', 'src', 'srcset', 'action', 'xlink:href', 'data', 'poster', 'cite', 'manifest', 'codebase']);
const BAD_ATTRS = new Set(['srcdoc', 'formaction', 'ping', 'background', 'dynsrc', 'lowsrc']);
const URL_OK = [
  /^https:\/\/www\.virustotal\.com\/gui\/file\/[0-9a-f]{64}$/i,
  /^https:\/\/github\.com\/[A-Za-z0-9._~\/%+#:@=?&-]*$/i,
];
// <!doctype html> immediately followed by the marker, with an optional version: " v1", " v1.0", " v1.0.0"
const RE_REPORT_HEAD = /^\s*<!doctype html>\s*<!-- ram-doctor-report(?: v\d{1,3}(?:\.\d{1,3}){0,2})? -->/i;
const MAX_ATTRS_PER_TAG = 100;

function urlAllowed(u) {
  return URL_OK.some((re) => re.test(u));
}

function toLowerAscii(s) {
  return s.replace(/[A-Z]+/g, (m) => m.toLowerCase());
}

function isAlpha(c) {
  return (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
}

function isSpace(c) {
  return c === 32 || c === 9 || c === 10 || c === 13 || c === 12;
}

function safeCodePoint(n) {
  return Number.isFinite(n) && n > 0 && n <= 0x10ffff ? String.fromCodePoint(n) : '';
}

function decodeEntities(v) {
  const named = { colon: ':', tab: '\t', newline: '\n', amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", lpar: '(', rpar: ')' };
  return String(v)
    .replace(/&#x([0-9a-f]{1,8});?/gi, (m, h) => safeCodePoint(parseInt(h, 16)))
    .replace(/&#(\d{1,9});?/g, (m, d) => safeCodePoint(parseInt(d, 10)))
    .replace(/&([a-z]{1,10});/gi, (m, n) => (Object.prototype.hasOwnProperty.call(named, n.toLowerCase()) ? named[n.toLowerCase()] : m));
}

function attrUrlOk(v) {
  const s = decodeEntities(v).replace(RE_URL_JUNK, '');
  if (s === '' || s[0] === '#') return true;
  if (/^(?:javascript|vbscript|data|file|blob|about):/i.test(s)) return false;
  if (s.slice(0, 2) === '//') return false;
  return urlAllowed(s);
}

function stripCssComments(css) {
  let out = '';
  let i = 0;
  for (;;) {
    const s = css.indexOf('/*', i);
    if (s === -1) return out + css.slice(i);
    out += css.slice(i, s);
    const e = css.indexOf('*/', s + 2);
    if (e === -1) return out; // an unterminated comment swallows the rest, exactly like a browser
    i = e + 2;
  }
}

function cssOk(css) {
  const stripped = stripCssComments(String(css));
  const unescaped = stripped
    .replace(/\\([0-9a-f]{1,6})[ \t\r\n\f]?/gi, (m, h) => safeCodePoint(parseInt(h, 16)))
    .replace(/\\([\s\S])/g, '$1');
  for (const x of [stripped, unescaped]) {
    if (/@import/i.test(x) || /expression\s{0,8}\(/i.test(x) || /(?<![\w-])behavior\s{0,8}:/i.test(x) || /-moz-binding/i.test(x) || /javascript\s{0,8}:/i.test(x)) {
      return false;
    }
    const all = (x.match(/url\(/gi) || []).length;
    const local = (x.match(/url\(\s{0,8}['"]?#/gi) || []).length;
    if (all !== local) return false; // only url(#fragment) (SVG gradients etc.) is tolerated
  }
  return true;
}

function nextHit(cache, key, html, needle, from) {
  const p = cache[key];
  if (p === -1 || (p !== undefined && p >= from)) return p;
  cache[key] = html.indexOf(needle, from);
  return cache[key];
}

/** Index just after an HTML comment that starts at `from` (the text after "<!--"), or -1 if it never ends. */
function commentEnd(html, from, cache) {
  if (html.charCodeAt(from) === 62) return from + 1; // "<!-->" is a complete empty comment
  if (html.charCodeAt(from) === 45 && html.charCodeAt(from + 1) === 62) return from + 2; // "<!--->"
  // Next "-->" and next "--!>" at or after `from`. Each is searched again only after the cursor has passed the
  // previous hit (-1 is final), so all searches together scan the document at most twice: linear, never quadratic.
  const a = nextHit(cache, 'a', html, '-->', from);
  const b = nextHit(cache, 'b', html, '--!>', from);
  if (a === -1 && b === -1) return -1;
  if (a === -1) return b + 4;
  if (b === -1) return a + 3;
  return a < b ? a + 3 : b + 4;
}

/** Start of the matching "</name" (case-insensitive, followed by space, "/" or ">"), or -1. */
function findClose(html, from, name) {
  let p = html.indexOf('</', from);
  while (p !== -1) {
    const seg = html.substr(p + 2, name.length);
    if (seg.length === name.length && toLowerAscii(seg) === name) {
      const c = html.charCodeAt(p + 2 + name.length);
      if (Number.isNaN(c) || isSpace(c) || c === 47 || c === 62) return p;
    }
    p = html.indexOf('</', p + 2);
  }
  return -1;
}

/** HTML-spec style attribute scan starting right after the tag name. Returns { end, attrs } or null if malformed. */
function parseAttrs(html, start) {
  const n = html.length;
  const attrs = [];
  let j = start;
  for (;;) {
    while (j < n && (isSpace(html.charCodeAt(j)) || html.charCodeAt(j) === 47)) j++; // "/" separates attributes too
    if (j >= n) return null;
    if (html.charCodeAt(j) === 62) return { end: j + 1, attrs: attrs };
    if (attrs.length >= MAX_ATTRS_PER_TAG) return null;
    const ns = j;
    j++; // the first character always belongs to the name, even "="
    while (j < n) {
      const c = html.charCodeAt(j);
      if (isSpace(c) || c === 47 || c === 62 || c === 61) break;
      j++;
    }
    const aname = toLowerAscii(html.slice(ns, j));
    while (j < n && isSpace(html.charCodeAt(j))) j++;
    let value = '';
    if (j < n && html.charCodeAt(j) === 61) {
      j++;
      while (j < n && isSpace(html.charCodeAt(j))) j++;
      if (j >= n) return null;
      const q = html.charCodeAt(j);
      if (q === 34 || q === 39) {
        const e = html.indexOf(q === 34 ? '"' : "'", j + 1);
        if (e === -1) return null;
        value = html.slice(j + 1, e);
        j = e + 1;
      } else {
        const vs = j;
        while (j < n) {
          const c = html.charCodeAt(j);
          if (isSpace(c) || c === 62) break;
          j++;
        }
        value = html.slice(vs, j);
      }
    }
    attrs.push([aname, value]);
  }
}

/**
 * report.html: accepted only if it is recognisably OUR generator's output and inert. Returns { ok:true } or
 * { ok:false, reason } where reason is a fixed vocabulary word that is logged but not sent to the client.
 * Active contexts are checked (URL-bearing attributes, CSS url()/@import, <meta http-equiv>, event handlers, script
 * content, forbidden elements); URLs shown as plain text are fine.
 */
export function checkReportHtml(html) {
  const no = (reason) => ({ ok: false, reason: reason });
  if (!RE_REPORT_HEAD.test(html.slice(0, 600))) return no('marker');

  const n = html.length;
  const bang = {}; // search cache for comment terminators (see commentEnd)
  let i = 0;
  let scripts = 0;
  let sawHtml = false;

  while (i < n) {
    const lt = html.indexOf('<', i);
    if (lt === -1) break;
    const c1 = html.charCodeAt(lt + 1);

    if (c1 === 33) { // "<!"
      if (html.startsWith('<!--', lt)) {
        i = commentEnd(html, lt + 4, bang);
        if (i === -1) break; // unterminated: the rest of the document is an (inert) comment
        continue;
      }
      const gt = html.indexOf('>', lt + 2); // doctype / bogus comment: ends at the first ">"
      if (gt === -1) return no('malformed');
      i = gt + 1;
      continue;
    }
    if (c1 === 63) return no('malformed'); // "<?"

    if (c1 === 47) { // "</"
      if (!isAlpha(html.charCodeAt(lt + 2))) { i = lt + 2; continue; }
      let j = lt + 2;
      while (j < n) {
        const c = html.charCodeAt(j);
        if (isSpace(c) || c === 47 || c === 62) break;
        j++;
      }
      const cname = toLowerAscii(html.slice(lt + 2, j));
      if (cname === 'script') return no('script_count'); // closing tags of the one allowed script are consumed below
      if (DENY_TAGS.has(cname)) return no('forbidden_tag');
      const gt = html.indexOf('>', j);
      if (gt === -1) return no('malformed');
      i = gt + 1;
      continue;
    }

    if (!isAlpha(c1)) { i = lt + 1; continue; } // a lone "<" is text

    let j = lt + 1;
    while (j < n) {
      const c = html.charCodeAt(j);
      if (isSpace(c) || c === 47 || c === 62) break;
      j++;
    }
    const name = toLowerAscii(html.slice(lt + 1, j));
    if (DENY_TAGS.has(name)) return no('forbidden_tag');
    const parsed = parseAttrs(html, j);
    if (!parsed) return no('malformed');
    if (name === 'html') sawHtml = true;

    for (const [an, av] of parsed.attrs) {
      if (an.indexOf('on') === 0) return no('event_attr');
      if (BAD_ATTRS.has(an)) return no('bad_attr');
      if (name === 'meta' && an === 'http-equiv') return no('bad_attr');
      if (URL_ATTRS.has(an) && !attrUrlOk(av)) return no('bad_url');
      if (an === 'style' && !cssOk(decodeEntities(av))) return no('css');
    }
    i = parsed.end;

    if (name === 'script') {
      if (++scripts > 1) return no('script_count');
      if (parsed.attrs.length > 0) return no('script_form');
      const close = findClose(html, i, 'script');
      if (close === -1) return no('script_count');
      const code = html.slice(i, close);
      if (code.length > MAX_SCRIPT_BYTES || byteLength(code) > MAX_SCRIPT_BYTES) return no('script_size');
      for (const re of SCRIPT_FORBIDDEN) if (re.test(code)) return no('script_token');
      if (SCRIPT_URL.test(code)) return no('script_url');
      const gt = html.indexOf('>', close);
      if (gt === -1) return no('malformed');
      i = gt + 1;
    } else if (name === 'style') {
      const close = findClose(html, i, 'style');
      const css = close === -1 ? html.slice(i) : html.slice(i, close);
      if (!cssOk(css)) return no('css');
      if (close === -1) break;
      const gt = html.indexOf('>', close);
      if (gt === -1) return no('malformed');
      i = gt + 1;
    }
  }
  return sawHtml ? { ok: true } : no('not_html');
}

/** Runs the per-file inspection; returns { ok:true, files } (summary sanitised) or { ok:false, status, code, field, reason }. */
export function inspectFiles(files) {
  const out = [];
  for (const f of files) {
    let content = f.content;
    let bytes = f.bytes;
    const cap = FILE_CAPS[f.name];
    if (bytes > cap) return { ok: false, status: 413, code: 'too_large', field: f.name };
    if (f.name === 'summary.md') {
      content = sanitizeSummary(content);
      bytes = byteLength(content);
      if (bytes > cap) return { ok: false, status: 413, code: 'too_large', field: f.name };
    } else if (f.name === 'plan.json') {
      const r = checkPlanJson(content);
      if (!r.ok) return { ok: false, status: 400, code: 'invalid_request', field: 'plan.json', reason: r.reason };
    } else if (f.name === 'report.html') {
      const r = checkReportHtml(content);
      if (!r.ok) return { ok: false, status: 400, code: 'report_rejected', field: 'report.html', reason: r.reason };
    }
    out.push({ name: f.name, content: content, bytes: bytes });
  }
  return { ok: true, files: out };
}

// ---------------------------------------------------------------------------------------------- invite codes (optional)

/**
 * INVITE_CODES secret: JSON map {"code":"label"}, JSON array ["code", ...], or a comma/space/newline list.
 * Returns Map(code -> label).
 */
export function parseInviteCodes(raw) {
  const map = new Map();
  if (typeof raw !== 'string') return map;
  const s = raw.trim();
  if (!s) return map;
  const add = (code, label) => {
    if (typeof code === 'string' && RE_CONFIGURED_CODE.test(code) && !map.has(code)) {
      const l = typeof label === 'string' && RE_LABEL.test(label) ? label : '';
      map.set(code, l || 'invite-' + (map.size + 1));
    }
  };
  if (s[0] === '{') {
    try {
      const o = JSON.parse(s);
      if (isPlainObject(o)) for (const k of Object.keys(o)) add(k, o[k]);
    } catch (_) {
      /* ignore: results in an empty map => fail closed */
    }
    return map;
  }
  if (s[0] === '[') {
    try {
      const a = JSON.parse(s);
      if (Array.isArray(a)) for (const c of a) add(c, '');
    } catch (_) {
      /* ignore */
    }
    return map;
  }
  for (const part of s.split(/[,\s]+/)) add(part, '');
  return map;
}

async function sha256(str) {
  return new Uint8Array(await crypto.subtle.digest('SHA-256', encoder.encode(str)));
}

/** Constant-time equality of two byte arrays of the same length (no early exit). */
export function timingSafeEqualBytes(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

/**
 * Compares the presented code against every configured code in constant time (digests are compared, and the loop
 * never exits early). Returns the label of the matching code, or null.
 */
export async function checkInvite(presented, codes) {
  const want = await sha256(presented);
  let label = null;
  let matched = 0;
  for (const [code, lab] of codes) {
    const eq = timingSafeEqualBytes(want, await sha256(code));
    if (eq) label = lab;
    matched |= eq ? 1 : 0;
  }
  return matched ? label : null;
}

/** Resolves the auth mode from the environment. */
export function authMode(env) {
  const raw = typeof env.INVITE_CODES === 'string' ? env.INVITE_CODES.trim() : '';
  const configured = raw.length > 0;
  const required = truthy(env.REQUIRE_CODE);
  return { enforced: configured || required, configured: configured, required: required, codes: parseInviteCodes(raw) };
}

// ---------------------------------------------------------------------------------------------- rate limiting

/**
 * Fixed-window counters (hour + day) in ONE KV key per subject (binding RATE). Not atomic - an abuse brake, not
 * accounting. Returns:
 *   { ok:true }                       counted
 *   { ok:false, retryAfter }          limit reached (retryAfter in seconds)
 *   { ok:true, unbound:true }         no KV binding
 *   { ok:true, error:true }           KV failed (caller decides: open mode fails closed, code mode fails open)
 */
export async function rateHit(kv, key, lim, nowMs) {
  if (!hasKv(kv)) return { ok: true, unbound: true };
  try {
    const w = await readWindows(kv, key, nowMs);
    const blocked = overLimit(w, lim, nowMs);
    if (blocked) return blocked;
    await writeWindows(kv, key, w);
    return { ok: true };
  } catch (_) {
    log('rate_kv_error', {});
    return { ok: true, error: true };
  }
}

/** Like rateHit, but only looks: nothing is counted (the per-user quota is counted after a successful commit). */
export async function rateCheck(kv, key, lim, nowMs) {
  if (!hasKv(kv)) return { ok: true, unbound: true };
  try {
    return overLimit(await readWindows(kv, key, nowMs), lim, nowMs) || { ok: true };
  } catch (_) {
    log('rate_kv_error', {});
    return { ok: true, error: true };
  }
}

/** Counts one event without checking the limit (it has already happened). Same result shapes as rateHit. */
export async function rateCount(kv, key, nowMs) {
  if (!hasKv(kv)) return { ok: true, unbound: true };
  try {
    await writeWindows(kv, key, await readWindows(kv, key, nowMs));
    return { ok: true };
  } catch (_) {
    log('rate_kv_error', {});
    return { ok: true, error: true };
  }
}

async function readWindows(kv, key, nowMs) {
  const w = { hb: Math.floor(nowMs / HOUR_MS), db: Math.floor(nowMs / DAY_MS), h: 0, d: 0 };
  const raw = await kv.get(key);
  if (raw) {
    try {
      const o = JSON.parse(raw);
      if (o && Array.isArray(o.h) && o.h[0] === w.hb) w.h = o.h[1] | 0;
      if (o && Array.isArray(o.d) && o.d[0] === w.db) w.d = o.d[1] | 0;
    } catch (_) {
      /* corrupted value: start from zero */
    }
  }
  return w;
}

function overLimit(w, lim, nowMs) {
  if (w.d >= lim.day) return { ok: false, retryAfter: Math.max(1, Math.ceil(((w.db + 1) * DAY_MS - nowMs) / 1000)) };
  if (w.h >= lim.hour) return { ok: false, retryAfter: Math.max(1, Math.ceil(((w.hb + 1) * HOUR_MS - nowMs) / 1000)) };
  return null;
}

async function writeWindows(kv, key, w) {
  await kv.put(key, JSON.stringify({ h: [w.hb, w.h + 1], d: [w.db, w.d + 1] }), { expirationTtl: 90000 });
}

// ---------------------------------------------------------------------------------------------- idempotency (requestId)

// One KV key per (userId, requestId): {"s":"pending"|"done","f":"<folder>","t":<ms>}. "pending" is written just before
// the commit, "done" right after it. KV is eventually consistent between locations, so this is best effort; a retry
// normally reaches the same location within seconds and sees the first attempt's state.
function requestKey(userId, requestId) {
  return 'rq:' + userId + ':' + requestId;
}

async function readRequest(kv, key) {
  const raw = await kv.get(key);
  if (!raw) return { state: 'none' };
  let o = null;
  try {
    o = JSON.parse(raw);
  } catch (_) {
    return { state: 'none' };
  }
  if (!isPlainObject(o) || typeof o.f !== 'string' || !RE_SAFE_FOLDER.test(o.f) || !Number.isFinite(o.t)) return { state: 'none' };
  if (o.s === 'done') return { state: 'done', folder: o.f, at: o.t };
  if (o.s === 'pending') return { state: 'pending', folder: o.f, at: o.t };
  return { state: 'none' };
}

async function writeRequest(kv, key, state, folder, nowMs) {
  await kv.put(key, JSON.stringify({ s: state, f: folder, t: nowMs }), { expirationTtl: REQUEST_TTL_SECONDS });
}

/** Best-effort KV write/delete after the commit: failures are logged, never reported to the client. */
async function quietly(fn) {
  try {
    await fn();
  } catch (_) {
    log('request_kv_error', {});
  }
}

// ---------------------------------------------------------------------------------------------- request body

async function readLimited(request, max) {
  const declared = parseInt(request.headers.get('content-length') || '', 10);
  if (Number.isFinite(declared) && declared > max) throw new HttpError(413, 'too_large');
  if (!request.body) return new Uint8Array(0);
  const reader = request.body.getReader();
  const chunks = [];
  let total = 0;
  for (;;) {
    const r = await reader.read();
    if (r.done) break;
    total += r.value.length;
    if (total > max) {
      try {
        await reader.cancel();
      } catch (_) {
        /* ignore */
      }
      throw new HttpError(413, 'too_large');
    }
    chunks.push(r.value);
  }
  const out = new Uint8Array(total);
  let off = 0;
  for (const c of chunks) {
    out.set(c, off);
    off += c.length;
  }
  return out;
}

// ---------------------------------------------------------------------------------------------- GitHub

// A secret pasted into a terminal prompt can pick up a stray space, line break or invisible mark. GitHub answers a
// malformed Authorization header with a bare "400 Bad Request" (found in the first live test), so keep only printable ASCII.
function cleanToken(t) {
  return String(t === undefined || t === null ? '' : t).replace(/[^\x21-\x7e]/g, '');
}

function ghClient(env, deps) {
  const owner = env.GITHUB_OWNER;
  const repo = env.GITHUB_REPO;
  const token = cleanToken(env.GITHUB_TOKEN);
  return async function gh(method, path, body) {
    const doFetch = deps.fetch || globalThis.fetch;
    // what the log may say about the call: no hashes, no report folder (it contains the user's slug and id)
    const step = method + ' ' + path.replace(/[0-9a-f]{40}/g, '<sha>').replace(/^\/contents\/.*$/, '/contents/<folder>');
    let res;
    try {
      res = await doFetch('https://api.github.com/repos/' + owner + '/' + repo + path, {
        method: method,
        headers: {
          Authorization: 'Bearer ' + token,
          Accept: 'application/vnd.github+json',
          'X-GitHub-Api-Version': '2022-11-28',
          'User-Agent': 'ram-doctor-relay',
          'Content-Type': 'application/json',
        },
        body: body === undefined ? undefined : JSON.stringify(body),
      });
    } catch (_) {
      throw new GitHubError(0, step);
    }
    if (!res.ok) {
      let detail = '';
      try { const j = await res.json(); detail = String((j && j.message) || '').slice(0, 160); } catch (_) { /* no JSON body */ }
      throw new GitHubError(res.status, step, detail);
    }
    return res.json();
  };
}

/**
 * Was `folder` committed? Used only when an earlier attempt's outcome is unknown (its ref update got no answer, or it
 * never finished). Reads one path the relay built itself; nothing is ever returned to the client.
 */
export async function folderExists(env, deps, folder) {
  const path = folder + '/meta.json';
  if (!RE_SAFE_PATH.test(path)) throw new HttpError(500, 'server_error');
  const gh = ghClient(env, deps);
  const branch = env.GITHUB_BRANCH || 'main';
  try {
    await gh('GET', '/contents/' + path.split('/').map(encodeURIComponent).join('/') + '?ref=' + encodeURIComponent(branch));
    return true;
  } catch (err) {
    if (err instanceof GitHubError && err.status === 404) return false;
    throw err;
  }
}

/** The ref update failed without a clear "no" (network error or 5xx): it may have been applied anyway. */
function maybeApplied(err) {
  return err instanceof GitHubError && err.step.indexOf('PATCH ') === 0 && (err.status === 0 || err.status >= 500);
}

/**
 * One atomic commit through the Git Data API: ref -> commit -> blobs -> tree(base_tree) -> commit -> ref update
 * (never forced). If the ref moved under us (409/422 on the update) it retries ONCE on top of the new head,
 * re-using the blobs.
 */
export async function commitFiles(env, deps, entries, message, nowMs) {
  const gh = ghClient(env, deps);
  const branch = env.GITHUB_BRANCH || 'main';
  const refPath = branch.split('/').map(encodeURIComponent).join('/');
  const person = { name: BOT_NAME, email: BOT_EMAIL, date: new Date(nowMs).toISOString() };

  for (const e of entries) if (!RE_SAFE_PATH.test(e.path)) throw new HttpError(500, 'server_error');

  let blobs = null;
  for (let attempt = 0; attempt < 2; attempt++) {
    const ref = await gh('GET', '/git/ref/heads/' + refPath);
    const headSha = ref && ref.object && ref.object.sha;
    if (!headSha) throw new GitHubError(0);
    const head = await gh('GET', '/git/commits/' + headSha);
    const baseTree = head && head.tree && head.tree.sha;
    if (!baseTree) throw new GitHubError(0);

    if (!blobs) {
      blobs = [];
      for (const e of entries) {
        const b = await gh('POST', '/git/blobs', { content: e.content, encoding: 'utf-8' });
        blobs.push(b.sha);
      }
    }

    const tree = await gh('POST', '/git/trees', {
      base_tree: baseTree,
      tree: entries.map((e, i) => ({ path: e.path, mode: '100644', type: 'blob', sha: blobs[i] })),
    });
    const commit = await gh('POST', '/git/commits', {
      message: message,
      tree: tree.sha,
      parents: [headSha],
      author: person,
      committer: person,
    });
    try {
      await gh('PATCH', '/git/refs/heads/' + refPath, { sha: commit.sha, force: false });
      return { commitSha: commit.sha };
    } catch (err) {
      const raced = err instanceof GitHubError && (err.status === 409 || err.status === 422);
      if (raced && attempt === 0) {
        log('ref_race_retry', {});
        continue;
      }
      throw err;
    }
  }
  throw new GitHubError(0);
}

// ---------------------------------------------------------------------------------------------- routing

function checkConfig(env, mode) {
  const ok =
    typeof env.GITHUB_TOKEN === 'string' && cleanToken(env.GITHUB_TOKEN).length > 0 &&
    typeof env.GITHUB_OWNER === 'string' && RE_GH_NAME.test(env.GITHUB_OWNER) &&
    typeof env.GITHUB_REPO === 'string' && RE_GH_NAME.test(env.GITHUB_REPO) &&
    (env.GITHUB_BRANCH === undefined || (typeof env.GITHUB_BRANCH === 'string' && RE_BRANCH.test(env.GITHUB_BRANCH))) &&
    !(mode.required && mode.codes.size === 0); // REQUIRE_CODE=true but no usable code => refuse to run
  if (!ok) {
    log('misconfigured', {});
    throw new HttpError(500, 'server_error');
  }
}

async function postReport(request, env, deps, now) {
  if (truthy(env.DISABLED)) throw new HttpError(503, 'disabled'); // global kill switch

  const mode = authMode(env);
  checkConfig(env, mode);
  const openMode = !mode.enforced;
  // Open mode: anybody who finds the URL can POST, so the rate limiter is mandatory (fail closed).
  if (openMode && !hasKv(env.RATE)) {
    log('open_mode_without_kv', {});
    throw new HttpError(503, 'unavailable');
  }

  const ctype = (request.headers.get('content-type') || '').toLowerCase();
  if (ctype.indexOf('application/json') !== 0) throw new HttpError(400, 'invalid_request', { field: 'content-type' });

  const declared = parseInt(request.headers.get('content-length') || '', 10);
  if (Number.isFinite(declared) && declared > MAX_BODY_BYTES) throw new HttpError(413, 'too_large');

  // Per-IP brake first (every POST counts, even invalid ones and retries). The per-user limit is checked after the
  // payload is validated and counted only after a successful commit, so neither garbage that guesses a userId nor a
  // GitHub outage can burn somebody's quota.
  const ip = (request.headers.get('CF-Connecting-IP') || 'unknown').slice(0, 64);
  const ipRate = await rateHit(env.RATE, 'ip:' + ip, { hour: LIMITS.perIpPerHour, day: LIMITS.perIpPerDay }, now);
  if (ipRate.error && openMode) throw new HttpError(503, 'unavailable');
  if (!ipRate.ok) throw new HttpError(429, 'rate_limited', { retryAfter: ipRate.retryAfter });

  const raw = await readLimited(request, MAX_BODY_BYTES);

  let parsed;
  try {
    parsed = JSON.parse(decoder.decode(raw));
  } catch (_) {
    throw new HttpError(400, 'invalid_request', { field: 'body' });
  }
  const v = validatePayload(parsed);
  if (!v.ok) throw new HttpError(v.status, v.code, { field: v.field });
  const p = v.value;

  let label = 'open';
  if (mode.enforced) {
    const found = p.code ? await checkInvite(p.code, mode.codes) : null;
    if (found === null) throw new HttpError(401, 'unauthorized');
    label = found;
  }

  const insp = inspectFiles(p.files);
  if (!insp.ok) {
    if (insp.reason) log('content_rejected', { file: insp.field, reason: insp.reason });
    throw new HttpError(insp.status, insp.code, { field: insp.field });
  }
  const files = insp.files;

  const kv = hasKv(env.RATE) ? env.RATE : null;
  const kvFailed = () => {
    log('request_kv_error', {});
    if (openMode) throw new HttpError(503, 'unavailable'); // open mode never runs without its KV safeguards
  };

  // Idempotency: the same requestId again returns the first result and never commits a second time. Without a
  // requestId (1.0.x clients) or without KV (code mode) every request is a new upload, exactly as before.
  let rqKey = p.requestId && kv ? requestKey(p.userId, p.requestId) : '';
  if (rqKey) {
    let prev = { state: 'none' };
    try {
      prev = await readRequest(kv, rqKey);
    } catch (_) {
      kvFailed();
      rqKey = '';
    }
    if (prev.state === 'done') {
      log('report_replay', { userId: p.userId });
      return okResponse(env, prev.folder, true);
    }
    if (prev.state === 'pending') {
      if (now - prev.at < PENDING_STALE_MS) throw new HttpError(409, 'in_progress', { retryAfter: IN_PROGRESS_RETRY_SECONDS });
      // The first attempt never finished. Did its commit land?
      if (await folderExists(env, deps, prev.folder)) {
        await quietly(() => writeRequest(kv, rqKey, 'done', prev.folder, now));
        log('report_replay', { userId: p.userId, confirmed: true });
        return okResponse(env, prev.folder, true);
      }
    }
  }

  // Per-user quota: checked here, but counted only after a successful commit (a failed upload costs the user nothing).
  const userKey = 'u:' + p.userId;
  const userRate = await rateCheck(env.RATE, userKey, { hour: LIMITS.perUserPerHour, day: LIMITS.perUserPerDay }, now);
  if (userRate.error && openMode) throw new HttpError(503, 'unavailable');
  if (!userRate.ok) throw new HttpError(429, 'rate_limited', { retryAfter: userRate.retryAfter });

  // Folder name comes from the SERVER clock (plus a random suffix), never from the client.
  const leaf = utcStamp(now) + '-' + folderSuffix();
  const folder = 'reports/' + slugify(p.displayName) + '-' + p.userId + '/' + leaf;

  const meta = {
    schema: 1,
    displayName: p.displayName,
    userId: p.userId,
    host: p.host,
    tool: p.tool,
    clientCreatedAt: p.createdAt,
    receivedAt: new Date(now).toISOString(),
    inviteLabel: label,
    files: files.map((f) => f.name),
  };
  const entries = files.map((f) => ({ path: folder + '/' + f.name, content: f.content }));
  entries.push({ path: folder + '/meta.json', content: JSON.stringify(meta, null, 2) + '\n' });
  const message = 'report: ' + p.displayName + ' ' + p.userId + ' ' + leaf;

  if (rqKey) {
    try {
      await writeRequest(kv, rqKey, 'pending', folder, now);
    } catch (_) {
      kvFailed();
      rqKey = '';
    }
  }

  const work = commitAndRecord(env, deps, entries, message, now, folder, kv, rqKey, userKey);
  // keep the Worker alive until the commit and its bookkeeping are done, even if the client hangs up meanwhile
  if (typeof deps.waitUntil === 'function') deps.waitUntil(work.catch(() => {}));
  await work;

  log('report_ok', { userId: p.userId, files: files.length, bytes: files.reduce((n, f) => n + f.bytes, 0), mode: openMode ? 'open' : 'code' });
  return okResponse(env, folder, false);
}

/** Commit, then (only on success) count the per-user quota and mark the requestId done. */
async function commitAndRecord(env, deps, entries, message, now, folder, kv, rqKey, userKey) {
  try {
    await commitFiles(env, deps, entries, message, now);
  } catch (err) {
    let landed = false;
    let unknown = false;
    if (maybeApplied(err)) {
      // the ref update got no clear answer: look before calling it a failure (a retry would duplicate the report)
      try {
        landed = await folderExists(env, deps, folder);
      } catch (_) {
        unknown = true;
      }
    }
    if (!landed) {
      // Definitely not committed: forget the requestId so the client's retry can start again at once. When the
      // outcome is unknown the "pending" mark stays; a retry after PENDING_STALE_MS checks GitHub again.
      if (rqKey && !unknown) await quietly(() => kv.delete(rqKey));
      throw err;
    }
    log('commit_confirmed', {});
  }
  await rateCount(kv, userKey, now);
  if (rqKey) await quietly(() => writeRequest(kv, rqKey, 'done', folder, now));
}

function okResponse(env, folder, replayed) {
  const branch = env.GITHUB_BRANCH || 'main';
  const body = {
    ok: true,
    folder: folder,
    url: 'https://github.com/' + env.GITHUB_OWNER + '/' + env.GITHUB_REPO + '/tree/' + branch + '/' + folder,
  };
  if (replayed) body.replayed = true;
  return jsonResponse(200, body);
}

/** Entry point used by the Worker (and by the tests with injected `deps.fetch` / `deps.now`). */
export async function handle(request, env, deps) {
  deps = deps || {};
  const now = typeof deps.now === 'function' ? deps.now() : Date.now();
  try {
    const url = new URL(request.url);
    const path = url.pathname.length > 1 ? url.pathname.replace(/\/+$/, '') : url.pathname;

    if (path === '/v1/health') {
      if (request.method !== 'GET' && request.method !== 'HEAD') throw new HttpError(405, 'method_not_allowed', { allow: 'GET, HEAD' });
      return jsonResponse(200, { ok: true, v: PROTOCOL_VERSION });
    }
    if (path === '/v1/reports') {
      if (request.method !== 'POST') throw new HttpError(405, 'method_not_allowed', { allow: 'POST' });
      return await postReport(request, env || {}, deps, now);
    }
    throw new HttpError(404, 'not_found'); // no other route exists: in particular, nothing can be read back
  } catch (err) {
    if (err instanceof HttpError) return errorResponse(err);
    if (err instanceof GitHubError) {
      log('upstream_error', { status: err.status, step: err.step, detail: err.detail });
      return errorResponse(new HttpError(502, 'upstream_error'));
    }
    log('unhandled_error', { name: err && err.name });
    return errorResponse(new HttpError(500, 'server_error'));
  }
}
