import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { BoxTile } from '../src/screens/Fleet.js';
import { ghQuotaBadge } from '../src/lib/ghquota.js';

// BH-1509 S-10. BH-1484 pushed ONE App bucket called `app`, on the true-at-the-
// time reading that the whole fleet ran under one GitHub App installation. Two
// installations are two separate 6,600/h buckets, so the hub now pushes
// `app-<installation id>` and the tile has to name the installation rather than
// say "the shared GitHub App installation" about whichever one answered.
//
// Every number here arrives as data; no clock and no network is read.

const tile = (ghQuota, ghReserve) => render(h(BoxTile, {
  name: 'box-hub', ping: '4m ago', ghQuota, ghReserve
}));

test('an installation-keyed bucket names the installation', () => {
  const b = ghQuotaBadge({ gh_quota_remaining: 900, gh_quota_bucket: 'app-163842147' }, 600);
  assert.equal(b.bucket, 'app-163842147');
  assert.match(b.title, /the shared GitHub App installation 163842147/,
    'two boxes on two Apps must be distinguishable on their tooltips');
  assert.equal(b.low, false);
});

test('two installations read as two different meters, not one', () => {
  const hub = ghQuotaBadge({ gh_quota_remaining: 5000, gh_quota_bucket: 'app-161623167' });
  const board = ghQuotaBadge({ gh_quota_remaining: 40, gh_quota_bucket: 'app-163842147' });
  assert.match(hub.title, /installation 161623167/);
  assert.match(board.title, /installation 163842147/);
  assert.notEqual(hub.title, board.title);
  assert.equal(board.badge, 'QUOTA LOW', 'one empty installation is still one empty bucket');
});

test('the legacy flat `app` reads exactly as it did before', () => {
  const b = ghQuotaBadge({ gh_quota_remaining: 900, gh_quota_bucket: 'app' }, 600);
  assert.equal(b.bucket, 'app');
  assert.match(b.title, /on the shared GitHub App installation —/,
    'no trailing id, and no "undefined" where one would go');
  assert.doesNotMatch(b.title, /undefined|NaN/);
});

test('a PAT bucket is untouched — it is not an installation', () => {
  const b = ghQuotaBadge({ gh_quota_remaining: 900, gh_quota_bucket: 'pat-abc123def456' }, 600);
  assert.equal(b.bucket, 'pat-abc123def456');
  assert.match(b.title, /the pat-abc123def456 bucket/);
  assert.doesNotMatch(b.title, /installation/,
    "a PAT's 5,000/h is nobody's installation meter");
});

test('an app-ish name that is not an installation id is not dressed up as one', () => {
  for (const bucket of ['app-', 'app-abc', 'appx']) {
    const b = ghQuotaBadge({ gh_quota_remaining: 900, gh_quota_bucket: bucket });
    assert.match(b.title, new RegExp(`the ${bucket} bucket`),
      `${bucket} is not app-<digits>, so it is named literally`);
  }
});

test('the TILE carries the installation through, not just the helper', () => {
  const html = tile({ gh_quota_remaining: 900, gh_quota_limit: 6600, gh_quota_bucket: 'app-163842147' });
  assert.match(html, /gh quota/i);
  assert.match(html, /installation 163842147/, 'the tooltip on the real tile names the installation');
  assert.doesNotMatch(html, /undefined/);
});
