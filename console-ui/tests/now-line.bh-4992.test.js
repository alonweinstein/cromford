// BH-4992 (BH-4947 wave 3): /now leads with the line.
//
// The headline states the screen's condition from the payloads NowView already
// reads (the running jobs and the cockpit's boards, needs and ticks); "01 The
// line" lists every ticket in flight with its eight stations, each key a link
// to /t/<KEY>. The facts building-now.bh-3569 pins (the BUILDING NOW and NEEDS A
// HUMAN stats, the BUILDING NOW section) stay.
// (File name: console-ui runs tests/*.test.js, so not the ticket's .line-test.js.)
import test from 'node:test';
import assert from 'node:assert/strict';
import { h } from 'preact';

globalThis.window = globalThis.window || {
  location: { pathname: '/now', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {}
};
const { render } = await import('preact-render-to-string');
const { NowView } = await import('../src/screens/Now.js');
const { nowHeadline } = await import('../src/lib/line-screens.js');

const NOW = Date.parse('2026-10-10T08:00:00Z');
const ago = (s) => new Date(NOW - s * 1000).toISOString();
const visible = (html) => html.replace(/<[^>]+>/g, ' ').replace(/&amp;/g, '&').replace(/\s+/g, ' ');
const job = (id, key, stage) => ({ id, project: 'cromford', ticket_id: key, kind: 'build', status: 'running', stage, box: 'pool-1',
  heartbeating: true, activity_age_s: 30, beat_age_s: 30, last_beat_at: ago(30), created_at: ago(1800), age_s: 1800, spent_usd: 2 });
const data = (over = {}) => ({ data: { boards: [{ project: 'a' }, { project: 'b' }, { project: 'c' }], active_builds: [],
  recent_runs: [{ started_at: ago(120), finished_at: ago(60), rc: 0 }, { started_at: ago(900), finished_at: ago(840), rc: 1 }],
  events: [], needs: { total: 4 }, ...over }, error: null, loading: false, reload() {} });
const jobs = (list) => ({ data: { jobs: list, as_of: ago(0) }, error: null, loading: false, reload() {} });

test('N1 the headline derives from the payload counts', () => {
  const h1 = nowHeadline({ inFlight: 2, needs: 4, boards: 3, ticks: 2, failing: 1 });
  assert.deepEqual(h1, { line1: '2 tickets on the line.', line2: '4 need a person. 1 of the last 2 ticks failed.', lede: 'Across 3 boards.' });
  assert.equal(nowHeadline({ inFlight: 1, needs: 0, boards: 1, ticks: 0, failing: 0 }).line1, '1 ticket on the line.');
  assert.equal(nowHeadline({ inFlight: null, needs: null, boards: null, ticks: null, failing: null }).line1, 'Reading the line.');
  const out = render(h(NowView, { data: data(), jobs: jobs([job('b-1', 'BH-101', 'execute'), job('b-2', 'BH-102', 'review')]), nowMs: NOW }));
  assert.match(out, /<h1 class="line-headline">2 tickets on the line\.<br\/><span class="line-headline__dim">4 need a person\. 1 of the last 2 ticks failed\.<\/span>/);
});

test('N2 the line leads: every ticket in flight, with stations, each key a link', () => {
  const out = render(h(NowView, { data: data(), jobs: jobs([job('b-1', 'BH-101', 'execute'), job('b-2', 'BH-102', 'review')]), nowMs: NOW }));
  const lineAt = out.indexOf('The line</h2>');
  assert.ok(lineAt > 0, 'a numbered "The line" section');
  assert.ok(lineAt < out.indexOf('section__title">BOARDS<'), 'the line comes before the other sections');
  for (const k of ['BH-101', 'BH-102']) assert.ok(out.includes(`href="/t/${k}"`), `${k} links to its ticket`);
  assert.match(out, /aria-label="BH-101 at Build \(now\)"/);
  assert.match(out, /aria-label="BH-102 at Review \(now\)"/);
  // The pinned stats stay.
  assert.match(visible(out), /BUILDING NOW/);
  assert.match(visible(out), /NEEDS A HUMAN/);
});

test('N3 nothing in flight says so; an unread jobs read draws no line', () => {
  const none = render(h(NowView, { data: data(), jobs: jobs([]), nowMs: NOW }));
  assert.match(visible(none), /Nothing is on the line right now\./);
  assert.match(none, /<h1 class="line-headline">0 tickets on the line\./);
  const unread = render(h(NowView, { data: data(), jobs: { data: null, error: new Error('down'), loading: false, reload() {} }, nowMs: NOW }));
  assert.match(unread, /<h1 class="line-headline">Reading the line\./);
  assert.doesNotMatch(unread, /0 tickets on the line/);
});
