// BH-4990 (BH-4947 wave 1, "The Line"): the station track.
//
// Eight stations from triage to close. Stations before the ticket's own are
// done, its own carries the ticket's state (now, held or fail), the rest are
// idle. The fill ends at the current node. Every claim is read off the
// rendered markup of the real component.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';

import { StationTrack } from '../src/ui/line.js';
import { STATIONS, stationOf } from '../src/lib/line.js';
import { jobRows } from '../src/lib/jobs.js';

// [class list, inner markup] of each .st, in order.
function stations(markup) {
  return [...String(markup).matchAll(/<div class="(st(?: [a-z]+)?)">([\s\S]*?)<\/div>/g)]
    .map((m) => ({ cls: m[1].split(' '), inner: m[2] }));
}
const STATES = ['done', 'now', 'held', 'fail'];
const text = (s, cls) => (s.match(new RegExp(`<span class="${cls}">([^<]*)</span>`)) || [])[1];
const fillOf = (markup) => (String(markup).match(/class="track__fill" style="width:\s*([^"]*)"/) || [])[1];
const TIMES = ['20:58Z', '21:04Z', '21:12Z', '21:36Z', null, null, null, null];

test('T1 a ticket at review: stations 1-3 done, 4 now, 5-8 idle; nodes 01-08 and the eight names', () => {
  const out = render(h(StationTrack, { at: 3, state: 'now', times: TIMES, label: 'BH-1' }));
  const st = stations(out);
  assert.equal(st.length, 8);
  assert.deepEqual(STATIONS, ['Triage', 'Plan', 'Build', 'Review', 'Merge', 'Deploy', 'Prod QA', 'Close']);
  st.forEach((s, i) => {
    if (i < 3) assert.deepEqual(s.cls, ['st', 'done'], `station ${i + 1}`);
    else if (i === 3) assert.deepEqual(s.cls, ['st', 'now'], 'station 4');
    else for (const c of STATES) assert.ok(!s.cls.includes(c), `station ${i + 1} is idle, not ${c}`);
    assert.equal(text(s.inner, 'node'), String(i + 1).padStart(2, '0'));
    assert.equal(text(s.inner, 'lbl'), STATIONS[i]);
  });
  assert.match(out, /role="img"/);
  assert.match(out, /aria-label="BH-1 at Review \(now\)"/);
});

test('T2 held and failed render their class on the current station, and no now anywhere', () => {
  for (const state of ['held', 'fail']) {
    const st = stations(render(h(StationTrack, { at: 2, state, times: [] })));
    assert.deepEqual(st[2].cls, ['st', state]);
    assert.ok(st.every((s) => !s.cls.includes('now')), `${state}: no now`);
    assert.deepEqual(st.slice(0, 2).map((s) => s.cls[1]), ['done', 'done']);
  }
});

test('T3 station times print in their own .when; a null time prints none', () => {
  const st = stations(render(h(StationTrack, { at: 3, state: 'now', times: TIMES })));
  for (let i = 0; i < 8; i++) {
    if (TIMES[i]) assert.equal(text(st[i].inner, 'when'), TIMES[i], `station ${i + 1}`);
    else assert.doesNotMatch(st[i].inner, /class="when"/, `station ${i + 1} has no time`);
  }
});

test('T4 the fill ends at the current node; at 0 it is empty; an unknown station is said so', () => {
  assert.equal(fillOf(render(h(StationTrack, { at: 3, state: 'now', times: [] }))), 'calc((100% - 28px) * 0.428571)');
  assert.equal(fillOf(render(h(StationTrack, { at: 7, state: 'now', times: [] }))), 'calc((100% - 28px) * 1)');
  assert.equal(fillOf(render(h(StationTrack, { at: 0, state: 'now', times: [] }))), '0');
  const unknown = render(h(StationTrack, { at: null, state: 'now', times: [], label: 'BH-9' }));
  assert.equal(fillOf(unknown), '0');
  assert.ok(stations(unknown).every((s) => s.cls.length === 1), 'no done, now, held or fail');
  assert.match(unknown, /aria-label="BH-9: station not known"/);
});

test('T5 stationOf maps the kinds and stages the fleet reports, and refuses to guess', () => {
  const row = (j) => jobRows({ jobs: [{ id: 'j', status: 'running', ...j }] })[0];
  assert.equal(stationOf(row({ kind: 'triage' })), 0);
  assert.equal(stationOf(row({ kind: 'build', stage: 'plan' })), 1);
  assert.equal(stationOf(row({ kind: 'build', stage: 'planning' })), 1);
  assert.equal(stationOf(row({ kind: 'build', stage: 'execute' })), 2);
  assert.equal(stationOf(row({ kind: 'build', stage: 'fly_dispatched' })), 2);
  // The phase row wins over the job's own coarse stage.
  assert.equal(stationOf(row({ kind: 'build', stage: 'execute', phase: 'review', phase_status: 'running' })), 3);
  assert.equal(stationOf(row({ kind: 'lead_review' })), 3);
  assert.equal(stationOf(row({ kind: 'merge-sweep' })), 4);
  assert.equal(stationOf(row({ kind: 'migration' })), 5);
  assert.equal(stationOf(row({ kind: 'deploy' })), 5);
  assert.equal(stationOf(row({ kind: 'prod_qa' })), 6);
  assert.equal(stationOf(row({ kind: 'close' })), 7);
  assert.equal(stationOf(row({ kind: 'mystery' })), null);
  assert.equal(stationOf(row({ kind: 'build', stage: 'weird' })), null);
  assert.equal(stationOf(null), null);
});

test('T6 the current station follows `at` (the class is not hard-coded)', () => {
  const st = stations(render(h(StationTrack, { at: 4, state: 'now', times: [] })));
  assert.deepEqual(st.map((s) => s.cls[1] || ''), ['done', 'done', 'done', 'done', 'now', '', '', '']);
  assert.equal(fillOf(render(h(StationTrack, { at: 4, state: 'now', times: [] }))), 'calc((100% - 28px) * 0.571429)');
});
