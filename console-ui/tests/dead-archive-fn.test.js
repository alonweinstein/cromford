import test from 'node:test';
import assert from 'node:assert/strict';
import {
  onRequest, archiveDead, isArchived, cardAgeMin, ARCHIVE_AFTER_MIN
} from '../functions/api/dash/kanban/pipeline.js';
import { filterPipeline } from '../src/lib/kanban.js';

// The DEAD column archive. The rows are the console worker's, in a database
// this repo has no schema for, so the archive is a READ-LAYER filter in the
// Pages Function the request already passes through. What these tests pin:
//
//   - the boundary falls on ONE side out loud (7d exactly is still shown),
//   - a row we cannot date is KEPT, never hidden by a parse miss,
//   - nothing but the dead column moves,
//   - ?include=archived returns the whole column, flagged,
//   - and anything that is not a parseable 200 is passed back untouched, so a
//     refusal never renders as a tidy empty board.

const MIN = 60000;
const NOW = Date.parse('2026-08-30T12:00:00Z');
const agoMin = (m) => new Date(NOW - m * MIN).toISOString();

const deadCard = (id, ageMin) => ({
  command_id: id, ckey: `project-3:webhook_triage:${id}`, project: 'project-3',
  stage: 'dead_letter', age_min: ageMin
});

const payload = (deadRows, extra = {}) => ({
  columns: {
    queued: [{ project: 'project-3', queue_depth: 2 }],
    building: [{ id: 1, project: 'project-1', ticket: 'TK-1' }],
    merge_queue: [], review: [], merged_deployed: [],
    dead_failed: deadRows
  },
  counts: { queued: 2, building: 1, merge_queue: 0, review: 0, merged_deployed: 0, dead_failed: deadRows.length },
  building_stale: 3,
  snapshot_age_min: 4,
  ...extra
});

// --- the boundary ------------------------------------------------------------

test('the window is seven days, in minutes', () => {
  assert.equal(ARCHIVE_AFTER_MIN, 10080);
});

test('6d59m stays and 7d01m goes — the boundary, both readings of it', () => {
  // Read literally: six days and fifty-nine minutes.
  assert.equal(isArchived(deadCard(1, 6 * 1440 + 59), NOW), false);
  // Read as "just under seven days": six days, twenty-three hours, fifty-nine.
  assert.equal(isArchived(deadCard(2, 6 * 1440 + 23 * 60 + 59), NOW), false);
  // Just over.
  assert.equal(isArchived(deadCard(3, 7 * 1440 + 1), NOW), true);
});

test('exactly seven days is still shown — strictly older is what archives', () => {
  assert.equal(isArchived(deadCard(4, 10080), NOW), false);
  assert.equal(isArchived(deadCard(5, 10080.5), NOW), true);
});

test('a fresh row and a twelve-day project-3 dead-letter land on opposite sides', () => {
  assert.equal(isArchived(deadCard(6, 30), NOW), false);
  assert.equal(isArchived(deadCard(7, 12 * 1440), NOW), true);
});

// --- dating a card -----------------------------------------------------------

test('age comes from age_min, falling back to updated_at', () => {
  assert.equal(cardAgeMin({ age_min: 42 }, NOW), 42);
  assert.equal(cardAgeMin({ updated_at: agoMin(120) }, NOW), 120);
  // age_min wins when both are present — it is what the worker computed.
  assert.equal(cardAgeMin({ age_min: 5, updated_at: agoMin(9999) }, NOW), 5);
});

test('a row we cannot date is KEPT, not hidden', () => {
  // The one failure mode this must not have: a real failure disappearing
  // because its timestamp was unreadable.
  for (const c of [{}, { age_min: null }, { age_min: 'x' }, { updated_at: 'not a date' }, null]) {
    assert.equal(isArchived(c, NOW), false, `${JSON.stringify(c)} must stay visible`);
  }
  const out = archiveDead(payload([{ command_id: 9, project: 'project-3' }]), { now: NOW });
  assert.equal(out.columns.dead_failed.length, 1);
  assert.equal(out.dead_archived, 0);
});

// --- the filter over the payload ---------------------------------------------

test('the default view drops old dead rows and recounts the column', () => {
  const out = archiveDead(payload([deadCard(1, 10), deadCard(2, 12 * 1440), deadCard(3, 9 * 1440)]), { now: NOW });
  assert.deepEqual(out.columns.dead_failed.map((r) => r.command_id), [1]);
  assert.equal(out.counts.dead_failed, 1);
  assert.equal(out.dead_archived, 2);
  assert.equal(out.dead_archive_days, 7);
  assert.equal(out.dead_archive_include, false);
});

test('nothing but the dead column moves', () => {
  const src = payload([deadCard(1, 12 * 1440)]);
  const out = archiveDead(src, { now: NOW });
  assert.deepEqual(out.columns.queued, src.columns.queued);
  assert.deepEqual(out.columns.building, src.columns.building);
  assert.equal(out.counts.building, 1);
  assert.equal(out.counts.queued, 2);
  assert.equal(out.building_stale, 3);
  assert.equal(out.snapshot_age_min, 4);
  // and the input is not mutated — the rows are still all there upstream
  assert.equal(src.columns.dead_failed.length, 1);
});

test('the audit view returns every row, flagged', () => {
  const out = archiveDead(payload([deadCard(1, 10), deadCard(2, 12 * 1440)]), { now: NOW, includeArchived: true });
  assert.equal(out.columns.dead_failed.length, 2);
  assert.deepEqual(out.columns.dead_failed.map((r) => r.archived), [false, true]);
  assert.equal(out.counts.dead_failed, 2);
  // The count of what the DEFAULT view would hide is still reported, so the
  // two views agree about how much rot there is.
  assert.equal(out.dead_archived, 1);
  assert.equal(out.dead_archive_include, true);
});

test('a payload with no dead column is handed back untouched', () => {
  const odd = { columns: { queued: [] }, counts: {} };
  assert.equal(archiveDead(odd, { now: NOW }), odd);
  assert.equal(archiveDead(null, { now: NOW }), null);
  assert.equal(archiveDead({ error: 'nope' }, { now: NOW }).error, 'nope');
});

// --- what the screen then does with it ---------------------------------------

test('filterPipeline carries the archive count, fleet-wide under a filter', () => {
  const src = archiveDead(payload([deadCard(1, 10)], {}), { now: NOW });
  src.dead_archived = 100;
  const all = filterPipeline(src, null);
  assert.equal(all.dead_archived, 100);
  assert.equal(all.dead_archive_days, 7);
  assert.equal(all.dead_archive_is_fleet_wide, false);
  // Under a project filter the number cannot be attributed, exactly as
  // building_stale cannot — so it is flagged rather than passed off.
  const one = filterPipeline(src, 'project-3');
  assert.equal(one.dead_archived, 100);
  assert.equal(one.dead_archive_is_fleet_wide, true);
});

// --- the function around it --------------------------------------------------

function withFetch(answer, fn) {
  const real = globalThis.fetch;
  const calls = [];
  globalThis.fetch = async (url, init) => {
    calls.push({ url: String(url), init });
    const a = typeof answer === 'function' ? answer(String(url)) : answer;
    if (a instanceof Error) throw a;
    return a;
  };
  return Promise.resolve(fn(calls)).finally(() => { globalThis.fetch = real; });
}

const jsonRes = (body, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });

const req = (search = '') => new Request(`https://console.example/api/dash/kanban/pipeline${search}`, {
  headers: { cookie: 'dash=tok' }
});

test('the request is forwarded to the console worker with its cookie', () =>
  withFetch(jsonRes(payload([])), async (calls) => {
    await onRequest({ request: req('?project=project-3') });
    assert.equal(calls.length, 1);
    assert.match(calls[0].url, /^https:\/\/harness-console\.operator\.workers\.dev\/api\/dash\/kanban\/pipeline\?project=project-3$/);
    assert.equal(calls[0].init.headers.get('cookie'), 'dash=tok');
    // Delegated auth: this function never decides who is signed in, it just
    // carries the cookie the worker minted.
    assert.equal(calls[0].init.headers.get('host'), null);
  }));

test('include=archived is ours and never reaches the worker', () =>
  withFetch(jsonRes(payload([deadCard(1, 12 * 1440)])), async (calls) => {
    const res = await onRequest({ request: req('?project=project-3&include=archived') });
    assert.doesNotMatch(calls[0].url, /include/);
    assert.match(calls[0].url, /project=project-3/);
    const body = await res.json();
    assert.equal(body.columns.dead_failed.length, 1);
    assert.equal(body.columns.dead_failed[0].archived, true);
  }));

test('the default response has the old rows filtered out', () =>
  withFetch(jsonRes(payload([deadCard(1, 5), deadCard(2, 11 * 1440)])), async () => {
    const res = await onRequest({ request: req() });
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.deepEqual(body.columns.dead_failed.map((r) => r.command_id), [1]);
    assert.equal(body.dead_archived, 1);
  }));

test('a non-200 is passed back verbatim, never tidied into an empty board', () =>
  withFetch(new Response('forbidden', { status: 403 }), async () => {
    const res = await onRequest({ request: req() });
    assert.equal(res.status, 403);
    assert.equal(await res.text(), 'forbidden');
  }));

test('a non-JSON 200 is passed back verbatim', () =>
  withFetch(new Response('<html>nope</html>', { status: 200, headers: { 'content-type': 'text/html' } }), async () => {
    const res = await onRequest({ request: req() });
    assert.equal(res.status, 200);
    assert.equal(await res.text(), '<html>nope</html>');
  }));

test('an unreachable worker is a 502 that says so', () =>
  withFetch(new Error('boom'), async () => {
    const res = await onRequest({ request: req() });
    assert.equal(res.status, 502);
    assert.match((await res.json()).error, /unreachable/);
  }));

test('the archive is read-only — no method but the browser\'s own is invented', () =>
  withFetch(jsonRes(payload([])), async (calls) => {
    await onRequest({ request: req() });
    assert.equal(calls[0].init.method, 'GET');
  }));
