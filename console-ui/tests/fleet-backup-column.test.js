import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { BoxTile } from '../src/screens/Fleet.js';
import { backupBadge, BACKUP_STALE_MIN } from '../src/lib/backups.js';

// BH-399. A backup that stopped is the quietest failure in the fleet: nothing
// errors, nothing is late, and the only symptom is the day you need it. So the
// hub pushes `backups.<box>` and the Fleet screen's box tile has to SAY it —
// the helper being right is not the same as the screen telling the truth, so
// every case below renders the REAL tile and reads the HTML back.
//
// No clock is read anywhere in this file: the age arrives as data, exactly as
// the snapshot delivers it.

const tile = (backup) => render(h(BoxTile, { name: 'box-alpha', ping: '4m ago', backup }));

// ───────────────────────────────────────────────────────────── the helper

test('a fresh backup is not stale and renders its age', () => {
  const b = backupBadge({ state: 'ok', backup_age_min: 5 });
  assert.equal(b.stale, false);
  assert.match(b.text, /5m/);
});

test('past the threshold it is stale — and the threshold is the shared constant', () => {
  assert.equal(BACKUP_STALE_MIN, 30, 'bin/state-backup.sh runs 5,20,35,50: 30m is two missed cycles');
  assert.equal(backupBadge({ state: 'ok', backup_age_min: 30 }).stale, false, 'exactly at the line is not past it');
  assert.equal(backupBadge({ state: 'ok', backup_age_min: 45 }).stale, true);
});

test('a box that never stamped reads NEVER, never "now"', () => {
  const b = backupBadge({ state: 'missing' });
  assert.match(b.text, /never/i);
  assert.equal(b.stale, true, 'no off-box copy at all is the worst case, not the quiet one');
  // "STALE" would be the wrong word for the worse problem: stale means there
  // IS a copy and it is old.
  assert.equal(b.badge, 'NO BACKUP');
  assert.equal(backupBadge({ state: 'ok', backup_age_min: 45 }).badge, 'STALE');
  assert.equal(backupBadge({ state: 'ok', backup_age_min: 5 }).badge, null);
});

test('unconfigured and off are distinct from broken, and neither is stale', () => {
  // bin/state-backup.sh ships unconfigured on purpose and already alerts once
  // per UTC day about it. Rendering that as a dead backup teaches the operator
  // to ignore the field.
  const u = backupBadge({ state: 'unconfigured' });
  assert.match(u.text, /not configured/i);
  assert.equal(u.stale, false);
  assert.equal(u.badge, null);
  const o = backupBadge({ state: 'off' });
  assert.match(o.text, /off/i);
  assert.equal(o.stale, false);
  assert.equal(o.badge, null);
  assert.equal(o.tone, 'unknown', 'a lane somebody switched off is not a warning');
});

test('no entry at all is unknown — an old hub must not render a false "never"', () => {
  for (const v of [undefined, null, {}, 'nonsense', { state: 'unknown' }]) {
    const b = backupBadge(v);
    assert.equal(b.stale, false, `${JSON.stringify(v)} is not evidence of a missing backup`);
    assert.equal(b.known, false);
    assert.equal(b.badge, null);
  }
});

test('a non-numeric age is not an age', () => {
  const b = backupBadge({ state: 'ok', backup_age_min: null });
  assert.equal(b.known, false, 'state ok with no number is not a reading');
  assert.equal(b.stale, false);
});

// ───────────────────────────────────────────────────────────── the tile

test('the tile renders a fresh backup age and no stale badge', () => {
  const html = tile({ state: 'ok', backup_age_min: 5 });
  assert.match(html, /backup/i);
  assert.match(html, /5m/);
  assert.doesNotMatch(html, /STALE/);
});

test('the tile renders the age AND a stale badge past 30 minutes', () => {
  const html = tile({ state: 'ok', backup_age_min: 45 });
  assert.match(html, /45m/, 'the number is what makes it actionable');
  assert.match(html, /STALE/, 'and the badge is what makes it visible at a glance');
});

test('the tile says never for a box that has no off-box copy at all', () => {
  const html = tile({ state: 'missing' });
  assert.match(html, /never/i);
  assert.match(html, /NO BACKUP/, 'the worse case gets its own words, not "STALE"');
});

test('the tile stays quiet for unconfigured, off, and a hub that pushed nothing', () => {
  for (const b of [{ state: 'unconfigured' }, { state: 'off' }, undefined]) {
    assert.doesNotMatch(tile(b), /pill--dead/, `${JSON.stringify(b)} must not render any alarm pill`);
  }
  assert.match(tile({ state: 'unconfigured' }), /not configured/i);
  // An old hub that pushes no backups key at all: the tile renders, and says
  // nothing it cannot support.
  const none = tile(undefined);
  assert.match(none, /box-alpha/, 'the tile still renders');
  assert.doesNotMatch(none, /never/i, 'silence from the hub is not proof of a missing backup');
});

// ──────────────────────────────────────────── the threshold is the hub's

test('the badge follows the threshold the hub pushed, not a constant in the bundle', () => {
  // The console cannot reach the knob store. If the number lived only here, an
  // operator who raised backup_stale_min to 45 would get no page at 40m and a
  // red STALE pill at 31m — two surfaces disagreeing about one number, which is
  // the reason bin/lib/backup-freshness.sh exists at all.
  assert.equal(backupBadge({ state: 'ok', backup_age_min: 40 }, 45).stale, false);
  assert.equal(backupBadge({ state: 'ok', backup_age_min: 50 }, 45).stale, true);
  assert.match(backupBadge({ state: 'ok', backup_age_min: 40 }, 45).title, /45m/,
    'the tooltip has to name the threshold it actually applied');
  const raised = render(h(BoxTile, { name: 'box-alpha', ping: '4m ago',
    backup: { state: 'ok', backup_age_min: 40 }, staleMin: 45 }));
  assert.doesNotMatch(raised, /STALE/, 'the tile has to carry it through, not just the helper');
  assert.match(tile({ state: 'ok', backup_age_min: 40 }), /STALE/,
    'and with nothing pushed the documented 30m fallback still applies');
});

test('a threshold the hub did not push falls back — it never coerces to zero', () => {
  // Number(null) and Number('') are both 0, and a limit of 0 makes EVERY box
  // stale: the healthy-looking failure this field exists to prevent, inverted.
  for (const v of [null, undefined, '', 'nonsense', NaN, {}, -5]) {
    assert.equal(backupBadge({ state: 'ok', backup_age_min: 5 }, v).stale, false,
      `${JSON.stringify(v)} must fall back to ${BACKUP_STALE_MIN}, not to 0`);
    assert.equal(backupBadge({ state: 'ok', backup_age_min: 45 }, v).stale, true,
      `${JSON.stringify(v)} must still page the genuinely stale box`);
  }
  // A real 0 IS a legitimate operator setting ("page on anything but now").
  assert.equal(backupBadge({ state: 'ok', backup_age_min: 5 }, 0).stale, true);
});
