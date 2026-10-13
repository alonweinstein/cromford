import { test } from 'node:test';
import assert from 'node:assert/strict';
import { agoFromMinutes, snapshotLabel, healthFromAge, fmtBytes, shortSha, minutesFromPingText, safeHttpsUrl } from '../src/lib/format.js';

test('minute ages render in the densest honest unit', () => {
  assert.equal(agoFromMinutes(0), 'now');
  assert.equal(agoFromMinutes(1), '1m');
  assert.equal(agoFromMinutes(59), '59m');
  assert.equal(agoFromMinutes(60), '1h');
  assert.equal(agoFromMinutes(150), '2h');
  assert.equal(agoFromMinutes(1440), '1d');
  assert.equal(agoFromMinutes(2880), '2d');
});

test('an unknown age says so rather than rendering as zero', () => {
  // "0m ago" for a snapshot we never received reads as "perfectly fresh",
  // which is the exact lie this whole staleness treatment exists to prevent.
  assert.equal(agoFromMinutes(null), 'never');
  assert.equal(agoFromMinutes(undefined), 'never');
});

test('the snapshot label always says it is a snapshot, never implies live', () => {
  assert.equal(snapshotLabel(4), 'snapshot 4m ago');
  assert.equal(snapshotLabel(0), 'snapshot now');
  assert.equal(snapshotLabel(null), 'no snapshot yet');
});

test('health tiers off snapshot age', () => {
  assert.equal(healthFromAge(2), 'ok');
  assert.equal(healthFromAge(9), 'ok');
  assert.equal(healthFromAge(10), 'warn');
  assert.equal(healthFromAge(29), 'warn');
  assert.equal(healthFromAge(30), 'dead');
  assert.equal(healthFromAge(null), 'unknown');
});

test('byte sizes render the way an operator reads a log cap', () => {
  assert.equal(fmtBytes(0), '0B');
  assert.equal(fmtBytes(900), '900B');
  assert.equal(fmtBytes(16000), '15.6KB');
  assert.equal(fmtBytes(48000), '46.9KB');
  assert.equal(fmtBytes(null), '—');
});

test('commit shas are trimmed but never invented', () => {
  assert.equal(shortSha('d3b64e8f1c2a4b5d6e7f8091a2b3c4d5e6f70819'), 'd3b64e8');
  assert.equal(shortSha(''), '—');
  assert.equal(shortSha(null), '—');
});

test('watchdog ping prose parses back into minutes for the tile colour', () => {
  assert.equal(minutesFromPingText('2m ago'), 2);
  assert.equal(minutesFromPingText('45s ago'), 0);
  assert.equal(minutesFromPingText('3h ago'), 180);
  assert.equal(minutesFromPingText('2d ago'), 2880);
});

test('a box that has NEVER pinged is unknown, not fresh', () => {
  // "never" parsed as 0 would paint a box that has never checked in bright
  // green — the single most misleading pixel on the fleet screen.
  assert.equal(minutesFromPingText('never'), null);
  assert.equal(minutesFromPingText(''), null);
  assert.equal(minutesFromPingText(null), null);
  assert.equal(minutesFromPingText('who knows'), null);
  assert.equal(healthFromAge(minutesFromPingText('never')), 'unknown');
});

test('only https URLs reach an href', () => {
  // pr_url and check-run URLs are echoed through D1 rows written by a beat, so
  // they are untrusted: a javascript: or data: URL must never become a link.
  assert.equal(safeHttpsUrl('https://github.com/o/r/pull/1'), 'https://github.com/o/r/pull/1');
  assert.equal(safeHttpsUrl('javascript:alert(1)'), null);
  assert.equal(safeHttpsUrl('JaVaScRiPt:alert(1)'), null);
  assert.equal(safeHttpsUrl('data:text/html,<script>x</script>'), null);
  assert.equal(safeHttpsUrl('http://github.com/o/r'), null, 'plain http is not linked either');
  assert.equal(safeHttpsUrl(''), null);
  assert.equal(safeHttpsUrl(null), null);
});

test('a protocol-relative URL does not sneak through as https', () => {
  // Resolved against a base, "//evil.com/x" becomes https://evil.com/x and
  // would pass a naive protocol check. These are always absolute URLs.
  assert.equal(safeHttpsUrl('//evil.com/x'), null);
  assert.equal(safeHttpsUrl('/relative/path'), null);
});
