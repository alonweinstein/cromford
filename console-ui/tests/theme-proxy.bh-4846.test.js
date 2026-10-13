import test from 'node:test';
import assert from 'node:assert/strict';
import { onRequest } from '../functions/api/coord/[[path]].js';
import { docFromTheme, exportTheme } from '../src/theme/custom.js';
import { BUILTIN_THEMES } from '../src/theme/themes.js';

// BH-4846: the coord proxy's two custom-theme writes. A PUT settings to a
// ui.theme.custom.<slug> key runs the theme validator before anything is
// forwarded, and DELETE settings/<key> is admitted for that prefix only.
// Driven through the real onRequest with fetch stubbed (the config-proxy.bh-2378 harness).

const SECRET = 'test-harness-secret';

function stubFetch() {
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const target = typeof input === 'string' ? input : input.url;
    if (target.startsWith('https://harness-console.operator.workers.dev')) return new Response('', { status: 200 });
    seen.push({ url: target, method: init.method, body: init.body });
    return new Response(JSON.stringify({ ok: true }), { status: 200, headers: { 'content-type': 'application/json' } });
  };
  return { seen, restore: () => { globalThis.fetch = real; } };
}

let cookieSeq = 0;
const call = (rest, method, body) =>
  onRequest({
    request: new Request(`https://console.example.pages.dev/api/coord/${rest}`, {
      method,
      headers: { cookie: `dash=bh4846-${++cookieSeq}`, 'content-type': 'application/json' },
      body
    }),
    env: { HARNESS_SECRET: SECRET },
    params: { path: rest.split('?')[0].split('/') }
  });

const doc = () => docFromTheme(BUILTIN_THEMES.mill, 'Night Shift');

test('TP1: PUT of a custom theme with an unknown token key is a 400 naming it, and nothing is forwarded', async () => {
  const f = stubFetch();
  try {
    const bad = doc();
    bad.tokens['--nav-h'] = '#000000';
    const res = await call('settings', 'PUT', JSON.stringify({ key: 'ui.theme.custom.night-shift', value: JSON.stringify(bad) }));
    assert.equal(res.status, 400);
    const body = await res.json();
    assert.match(body.error, /not a valid theme/);
    assert.ok(body.errors.some((e) => /--nav-h/.test(e)), JSON.stringify(body.errors));
    assert.equal(f.seen.length, 0);
    // A value that is not JSON at all, and a non-string value, are refused the same way.
    for (const value of ['red', 42, { v: 1 }]) {
      const r = await call('settings', 'PUT', JSON.stringify({ key: 'ui.theme.custom.night-shift', value }));
      assert.equal(r.status, 400, JSON.stringify(value));
    }
    // A slug the worker's DELETE could never match is refused too.
    const caps = await call('settings', 'PUT', JSON.stringify({ key: 'ui.theme.custom.' + 'a'.repeat(41), value: exportTheme(doc()) }));
    assert.equal(caps.status, 400);
    assert.equal(f.seen.length, 0);
  } finally { f.restore(); }
});

test('TP2: a valid custom theme is forwarded with the stamped actor', async () => {
  const f = stubFetch();
  try {
    const value = exportTheme(doc());
    const res = await call('settings', 'PUT', JSON.stringify({ key: 'ui.theme.custom.night-shift', value, actor: 'mallory' }));
    assert.equal(res.status, 200);
    assert.equal(f.seen.length, 1);
    assert.deepEqual(JSON.parse(f.seen[0].body), { key: 'ui.theme.custom.night-shift', value, actor: 'console' });
    // An ordinary knob is untouched by the theme check.
    const knob = await call('settings', 'PUT', JSON.stringify({ key: 'ui.theme.default', value: 'custom.night-shift' }));
    assert.equal(knob.status, 200);
    assert.equal(f.seen.length, 2);
  } finally { f.restore(); }
});

test('TP3: DELETE settings/ui.theme.custom.<slug> is forwarded with the actor in the query; any other key is 405', async () => {
  const f = stubFetch();
  try {
    const res = await call('settings/ui.theme.custom.ok?reason=tidy&actor=mallory', 'DELETE');
    assert.equal(res.status, 200);
    assert.equal(f.seen.length, 1);
    const u = new URL(f.seen[0].url);
    assert.equal(u.pathname, '/api/settings/ui.theme.custom.ok');
    assert.equal(u.searchParams.get('actor'), 'console');
    assert.equal(u.searchParams.get('reason'), 'tidy');
    assert.equal(f.seen[0].method, 'DELETE');
    assert.equal(f.seen[0].body, undefined);
    for (const rest of ['settings/lane.x', 'settings/ui.theme.default', 'settings/ui.theme.custom.', 'settings/ui.theme.custom.A', 'settings', 'settings/ui.theme.custom.ok/x']) {
      const r = await call(rest, 'DELETE');
      assert.equal(r.status, 405, rest);
    }
    assert.equal(f.seen.length, 1);
  } finally { f.restore(); }
});
