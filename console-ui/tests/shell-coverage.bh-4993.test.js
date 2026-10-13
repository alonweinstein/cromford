// BH-4993 (BH-4947 wave 4): every routed screen is on the line.
//
// The ticket's acceptance: every routed screen renders a page headline, and no
// screen file contains a hex colour. Each route of the REAL ROUTES table is
// rendered to a string with sample params. A string render runs no effects, so
// every screen is caught in its first, loading state: the headline must be
// there before any read answers, saying what is being read.
// (File name: console-ui runs tests/*.test.js, so not the ticket's .line-test.js.)

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { h } from 'preact';

globalThis.window = globalThis.window || {
  location: { pathname: '/', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {},
  localStorage: { getItem() { return null; }, setItem() {}, removeItem() {} },
  matchMedia() { return { matches: false, addEventListener() {}, removeEventListener() {} }; }
};
// No read ever answers: every screen is drawn in its first state.
globalThis.fetch = () => new Promise(() => {});

const { render } = await import('preact-render-to-string');
const { ROUTES, FleetContext } = await import('../src/app.js');
// The app always wraps screens in the fleet context; the fleet read has not answered either.
const FLEET = { data: null, error: null, loading: true, reload() {} };

const SAMPLE = { project: 'cromford', number: '41', id: '7', ticket: 'BH-4993', slug: 'an-idea', role: 'build.plan',
  lane: 'merge-conductor', kind: 'projects', name: 'cromford', site: 'site-1' };
const pathOf = (pat) => pat.replace(/:([a-z]+)/g, (_, k) => SAMPLE[k] || 'x');
const paramsOf = (pat) => Object.fromEntries([...pat.matchAll(/:([a-z]+)/g)].map(([, k]) => [k, SAMPLE[k] || 'x']));

test('S1 every routed screen renders a page headline in its first state', () => {
  const missing = [];
  for (const [pat, C] of ROUTES) {
    let out = '';
    try {
      out = render(h(FleetContext.Provider, { value: FLEET }, h(C, { ...paramsOf(pat), key: pathOf(pat) })));
    } catch (e) {
      missing.push(`${pat} (${C.name}): render threw ${e && e.message}`);
      continue;
    }
    if (!/class="line-headline"/.test(out)) missing.push(`${pat} (${C.name})`);
  }
  assert.deepEqual(missing, [], `screens with no page headline:\n  ${missing.join('\n  ')}`);
});

// Every .js under src/screens, sub-folders too.
function screenFiles(dir) {
  return readdirSync(dir).flatMap((n) => {
    const p = `${dir}/${n}`;
    return statSync(p).isDirectory() ? screenFiles(p) : n.endsWith('.js') ? [p] : [];
  });
}

test('S2 no screen file contains a hex colour', () => {
  const root = new URL('../src/screens', import.meta.url).pathname;
  const hits = [];
  for (const f of screenFiles(root)) {
    readFileSync(f, 'utf8').split('\n').forEach((line, i) => {
      if (/^\s*(\/\/|\*)/.test(line)) return;
      // A colour is 6 or 8 hex digits, or 3-4 with a letter: "#1510" is an
      // issue number, "#fff" and "#2563EB" are colours.
      for (const m of line.matchAll(/(?<![\w&/])#([0-9a-fA-F]{3,8})(?![\w-])/g)) {
        const d = m[1];
        if (d.length === 6 || d.length === 8 || ((d.length === 3 || d.length === 4) && /[a-fA-F]/.test(d))) {
          hits.push(`${f.slice(root.length + 1)}:${i + 1} ${m[0]}`);
        }
      }
    });
  }
  assert.deepEqual(hits, [], `hex colours in screen files:\n  ${hits.join('\n  ')}`);
});
