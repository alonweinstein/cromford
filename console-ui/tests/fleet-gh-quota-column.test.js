import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { BoxTile } from '../src/screens/Fleet.js';
import { ghQuotaBadge, GH_QUOTA_RESERVE } from '../src/lib/ghquota.js';

// BH-1484. The hub and the pool boxes share ONE GitHub App installation, so a
// single 6,600/h bucket carries every repo. It was burning ~5,700/h and
// emptying in the last five minutes of every window, and the only symptom
// anywhere was a burst of "UNVERIFIABLE (HTTP 000)" lines in a log. So the hub
// pushes `gh_rest_quota.<box>` and the box tile has to SAY it — the helper
// being right is not the same as the screen telling the truth, so every case
// below renders the REAL tile and reads the HTML back.
//
// No clock is read anywhere in this file: every number arrives as data, exactly
// as the snapshot delivers it.

const tile = (ghQuota, ghReserve) => render(h(BoxTile, {
  name: 'box-hub', ping: '4m ago', ghQuota, ghReserve
}));

// ───────────────────────────────────────────────────────────── the helper

test('a healthy bucket renders remaining over limit and no pill', () => {
  const b = ghQuotaBadge({ gh_quota_remaining: 4210, gh_quota_limit: 6600 });
  assert.equal(b.low, false);
  assert.equal(b.known, true);
  assert.equal(b.badge, null);
  assert.match(b.text, /4210/);
  assert.match(b.text, /6600/);
});

test('below the reserve it is low — and the default reserve is the shared 600', () => {
  assert.equal(GH_QUOTA_RESERVE, 600,
    'bin/lib/gh-rest-ledger.sh _GH_QUOTA_RESERVE_DEFAULT and the gh.quota.reserve seed are both 600');
  assert.equal(ghQuotaBadge({ gh_quota_remaining: 600, gh_quota_limit: 6600 }).low, false,
    'exactly at the reserve is not below it — the gate compares with <');
  assert.equal(ghQuotaBadge({ gh_quota_remaining: 599, gh_quota_limit: 6600 }).low, true);
  assert.equal(ghQuotaBadge({ gh_quota_remaining: 599 }).badge, 'QUOTA LOW');
});

test('the reserve follows the hub, not a constant in the bundle', () => {
  // The console cannot reach the knob store. If the number lived only here, an
  // operator who raised gh.quota.reserve to 1500 would see a green tile while
  // the library was already refusing every optional read — two surfaces
  // disagreeing about one number.
  assert.equal(ghQuotaBadge({ gh_quota_remaining: 1000 }, 1500).low, true);
  assert.equal(ghQuotaBadge({ gh_quota_remaining: 2000 }, 1500).low, false);
  assert.match(ghQuotaBadge({ gh_quota_remaining: 1000 }, 1500).title, /1500/,
    'the tooltip has to name the reserve it actually applied');
});

test('a reserve the hub did not push falls back — it never coerces to zero', () => {
  // Number(null) and Number('') are both 0, and a reserve of 0 makes EVERY box
  // look healthy at the moment the bucket empties: the healthy-looking failure
  // this field exists to prevent.
  for (const v of [null, undefined, '', 'nonsense', NaN, {}, -5]) {
    assert.equal(ghQuotaBadge({ gh_quota_remaining: 100 }, v).low, true,
      `${JSON.stringify(v)} must fall back to ${GH_QUOTA_RESERVE}, not to 0`);
  }
  // A real 0 IS a legitimate operator setting ("never refuse a read").
  assert.equal(ghQuotaBadge({ gh_quota_remaining: 100 }, 0).low, false);
});

test('no entry at all is unknown — an old hub must not render a false zero', () => {
  for (const v of [undefined, null, {}, 'nonsense', { gh_quota_remaining: null }]) {
    const b = ghQuotaBadge(v);
    assert.equal(b.known, false, `${JSON.stringify(v)} is not a reading`);
    assert.equal(b.low, false, 'silence from the hub is not an empty bucket');
    assert.equal(b.badge, null);
  }
});

test('a missing limit still renders the remaining it does have', () => {
  const b = ghQuotaBadge({ gh_quota_remaining: 4210 });
  assert.equal(b.known, true);
  assert.match(b.text, /4210/);
  assert.doesNotMatch(b.text, /\//, 'no fabricated denominator');
});

test('a reset is named only when it is a real epoch', () => {
  assert.match(ghQuotaBadge({ gh_quota_remaining: 10, gh_quota_reset: 1790000000 }).title, /resets at/);
  for (const t of [0, -1, null, undefined, 'soon']) {
    assert.doesNotMatch(ghQuotaBadge({ gh_quota_remaining: 10, gh_quota_reset: t }).title, /resets at/,
      `${JSON.stringify(t)} is not a reset time, and "resets at —" reads as never`);
  }
});

// ───────────────────────────────────────────────────────────── the tile

test('the tile renders a healthy bucket and no alarm pill', () => {
  const html = tile({ gh_quota_remaining: 4210, gh_quota_limit: 6600 });
  assert.match(html, /gh quota/i);
  assert.match(html, /4210/);
  assert.doesNotMatch(html, /QUOTA LOW/);
});

test('the tile goes red under the reserve, with the number still on it', () => {
  const html = tile({ gh_quota_remaining: 120, gh_quota_limit: 6600 });
  assert.match(html, /120/, 'the number is what makes it actionable');
  assert.match(html, /QUOTA LOW/, 'and the pill is what makes it visible at a glance');
  assert.match(html, /tile__meta--warn/, 'the reading itself is marked, not just the pill');
});

test('the tile carries the hub reserve through, not just the helper', () => {
  assert.doesNotMatch(tile({ gh_quota_remaining: 1000 }, 900), /QUOTA LOW/);
  assert.match(tile({ gh_quota_remaining: 1000 }, 1500), /QUOTA LOW/);
});

test('a box the hub pushed nothing for renders, and says nothing it cannot support', () => {
  const none = tile(undefined);
  assert.match(none, /box-hub/, 'the tile still renders');
  assert.doesNotMatch(none, /gh quota/i, 'silence from the hub is not a reading');
  assert.doesNotMatch(none, /QUOTA LOW/);
});
