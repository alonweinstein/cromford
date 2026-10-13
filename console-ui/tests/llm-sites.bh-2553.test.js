import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { ROUTES, NAV } from '../src/app.js';
import { matchRoute } from '../src/router.js';
import { api } from '../src/api.js';
import { LlmSitesScreen, LlmSitesView } from '../src/screens/LlmSites.js';
import { LlmSiteScreen } from '../src/screens/LlmSite.js';

// BH-2553 (BH-2540.0): the LLM sites contract slice on the console side. Two
// stub screens reachable by typed URL through the real ROUTES table, not in
// NAV yet (the list sibling owns that line), and the two api reads.

const route = (p) => ROUTES.find(([path]) => path === p);

test('U1: ROUTES maps /llm-sites and /llm-sites/:site to the stub screens', () => {
  assert.equal(route('/llm-sites')?.[1], LlmSitesScreen);
  assert.equal(route('/llm-sites/:site')?.[1], LlmSiteScreen);
  assert.deepEqual(matchRoute('/llm-sites/:site', '/llm-sites/rb-plan'), { site: 'rb-plan' });
});

// BH-2556 replaced the list stub with the real screen, so U2 now hands the
// contract's stub payload to its view and expects the real empty state.
test('U2: the list screen renders its title and the empty state for the stub payload', () => {
  const Screen = route('/llm-sites')?.[1];
  assert.ok(Screen);
  const out = render(h(LlmSitesView, { state: { data: { sites: [], windows: null, as_of: null, incomplete: ['not-implemented'] } } }));
  assert.match(out, /LLM SITES/);
  assert.match(out, /no LLM sites in the catalog/);
});

test('U3: the site screen names the site it was routed to and starts loading', () => {
  // BH-2557 replaced the stub's "No rows loaded" line with the real screen;
  // before its fetch lands (SSR runs no effects) it shows the loading cursor.
  const Screen = route('/llm-sites/:site')?.[1];
  assert.ok(Screen);
  const out = render(h(Screen, matchRoute('/llm-sites/:site', '/llm-sites/rb-plan')));
  assert.match(out, /rb-plan/);
  assert.match(out, /class="cursor/);
  assert.doesNotMatch(out, /No rows loaded/);
});

test('U4: api.llmSites / api.llmSiteRows hit the coord proxy URLs', async () => {
  const calls = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (url) => {
    calls.push(String(url));
    return { ok: true, status: 200, text: async () => '{}' };
  };
  try {
    await api.llmSites();
    await api.llmSiteRows('a b');
  } finally { globalThis.fetch = real; }
  assert.deepEqual(calls, ['/api/coord/metrics/llm-sites', '/api/coord/metrics/llm-sites/rows?site=a%20b']);
});

test('U5: no NAV entry points at /llm-sites yet', () => {
  assert.ok(NAV.length > 0);
  assert.equal(NAV.filter((n) => String(n.to).startsWith('/llm-sites')).length, 0);
});
