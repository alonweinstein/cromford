import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { ADOPT_DEFAULTS, adoptionState, zeroHits } from '../src/lib/preplan-adoption.js';
import { PreplanAdoptionView } from '../src/screens/PreplanAdoption.js';

// BH-3437: the PREPLAN ADOPTION panel shows HIT RATE (adopted/builds, the
// route's `hit_rate`) and BUILDS, and a `0% HIT` tag when builds ran and none
// used a pre-plan. A null hit rate reads `—`, never 0%.

const P = 'project-3';
const KNOBS = { ...ADOPT_DEFAULTS, source: {}, unreadable: false };

const answer = (row) => ({
  window_days: 7,
  since: '2026-09-19T00:00:00Z',
  projects: [{ project: P, adopted: 0, stale: 0, miss: 0, off: 0, bought: 0, rate: null, ...row }],
  days: [],
  recent: [],
  recent_truncated: false,
  as_of: '2026-09-25T10:05:00Z'
});
const view = (row) =>
  render(h(PreplanAdoptionView, { state: adoptionState({ data: answer(row) }, P), knobs: KNOBS, project: P, onRetry: () => {} }));
const hitVal = (out) => ((out.match(/kv__label">HIT RATE<\/span>\s*<span class="kv__val">([^<]*)</) || [])[1] || '').trim();

test('1: 0 hits over 42 builds shows HIT RATE 0% and the 0% HIT tag', () => {
  const out = view({ adopted: 0, miss: 42, builds: 42, hit_rate: 0 });
  assert.match(out, /HIT RATE/);
  assert.equal(hitVal(out), '0%');
  assert.match(out, /kv__label">BUILDS<\/span>\s*<span class="kv__val">42</);
  assert.match(out, /class="tag tag--warn"[^>]*>0% HIT</);
  // HIT RATE sits above BOUGHT.
  assert.ok(out.indexOf('HIT RATE') < out.indexOf('BOUGHT'));
});

test('2: no builds is a dash, never 0%, and no tag', () => {
  for (const row of [{ builds: 0, hit_rate: null, off: 3 }, { off: 3 }]) {
    const out = view(row);
    assert.equal(hitVal(out), '—', JSON.stringify(row));
    assert.doesNotMatch(out, /0% HIT/);
  }
});

test('3: a 25% hit rate reads 25% with no tag', () => {
  const out = view({ adopted: 2, stale: 1, miss: 5, off: 3, bought: 3, rate: 2 / 3, builds: 8, hit_rate: 0.25 });
  assert.equal(hitVal(out), '25%');
  assert.doesNotMatch(out, /0% HIT/);
});

test('4: zeroHits is builds > 0 with nothing adopted; absent numbers never fire', () => {
  assert.equal(zeroHits({ builds: 42, adopted: 0 }), true);
  assert.equal(zeroHits({ builds: 1, adopted: 0 }), true);
  assert.equal(zeroHits({ builds: 8, adopted: 2 }), false);
  assert.equal(zeroHits({ builds: 0, adopted: 0 }), false);
  assert.equal(zeroHits({ builds: null, adopted: 0 }), false);
  assert.equal(zeroHits({ adopted: 0 }), false);
  assert.equal(zeroHits({ builds: 5 }), false);
  assert.equal(zeroHits({}), false);
  assert.equal(zeroHits(null), false);
});

test('5: the stats default for a project with no row carries hit_rate null and builds 0', () => {
  const s = adoptionState({ data: { ...answer({}), projects: [],
    recent: [{ job_id: 'j', ticket_id: 'T', project: P, verdict: 'OFF', detail: null, created_at: 'x' }] } }, P);
  assert.equal(s.kind, 'rows');
  assert.equal(s.stats.hit_rate, null);
  assert.equal(s.stats.builds, 0);
});
