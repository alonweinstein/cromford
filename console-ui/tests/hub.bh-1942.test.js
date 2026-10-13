import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { api } from '../src/api.js';
import { ROUTES, NAV } from '../src/app.js';
import { HubScreen } from '../src/screens/Hub.js';
import { RestoreLabPanel } from '../src/screens/hub/RestoreLab.js';

// BH-1942 (BH-1909.0): the console half of the hub-recovery contract. The four
// api calls the sibling screens will use, the /hub route and its nav tab, and
// the HubScreen they are wired to (built by BH-1945).

function captureFetch() {
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    calls.push({ url: String(url), method: init.method || 'GET', body: init.body });
    return { ok: true, status: 200, text: async () => JSON.stringify({ ok: true }) };
  };
  return calls;
}

test('the hub api calls hit the coord proxy paths with the right method', async () => {
  const calls = captureFetch();
  await api.hubRecovery();
  await api.promoteHub({ target: 'hub-2', expected_epoch: 4, confirm: true });
  await api.restoreLab({ box: 'hub-1', confirm: true });
  await api.restoreLabRuns();
  assert.deepEqual(calls.map((c) => [c.method, c.url]), [
    ['GET', '/api/coord/hub/recovery'],
    ['POST', '/api/coord/hub/promote'],
    ['POST', '/api/coord/hub/restore-lab'],
    ['GET', '/api/coord/hub/restore-lab'],
  ]);
  assert.deepEqual(JSON.parse(calls[1].body), { target: 'hub-2', expected_epoch: 4, confirm: true });
  assert.deepEqual(JSON.parse(calls[2].body), { box: 'hub-1', confirm: true });
});

// BH-1945 replaced the stub body: the screen now loads GET /api/hub/recovery
// in an effect (tests/hub-render.bh-1909.test.js drives its states), so this
// case keeps only what the contract promised, the HUB heading.
test('HubScreen renders the HUB heading', () => {
  const out = render(h(HubScreen));
  // TEST-CHANGE (BH-4993, wave 4 of BH-4947): the page's h1 is now the line
  // headline, a sentence about the hub's state; HUB is its chip. Still exact.
  assert.match(out, /<span class="line-chip"><span class="line-chip__dot"><\/span>HUB<\/span>/);
  assert.match(out, /<h1 class="line-headline">Reading the hub\.<br\/>/);
});

// BH-1946 filled the stub: the panel renders its RESTORE LAB section, loading
// until useApi's effect runs, and fetches nothing during render.
test('RestoreLabPanel renders its section in the loading state with no fetch during render', () => {
  const calls = captureFetch();
  const out = render(h(RestoreLabPanel, { boxes: [] }));
  assert.match(out, /RESTORE LAB/);
  assert.match(out, /class="skel"/);
  assert.equal(calls.length, 0);
});

test('/hub is routed to HubScreen and reachable from the nav', () => {
  const route = ROUTES.find(([p]) => p === '/hub');
  assert.ok(route, '/hub missing from ROUTES');
  assert.equal(route[1], HubScreen);
  const tab = NAV.find((n) => n.to === '/hub');
  assert.ok(tab, '/hub missing from NAV');
  assert.equal(typeof tab.icon, 'function', 'BottomNav renders <${icon}>, so the tab needs one');
  assert.equal(tab.match('/hub'), true);
  assert.equal(tab.match('/settings'), false);
  // SETTINGS stays last.
  assert.equal(NAV[NAV.length - 1].to, '/settings');
});
