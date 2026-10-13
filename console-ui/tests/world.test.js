import test from 'node:test';
import assert from 'node:assert/strict';
import {
  spriteState, handRaised, spriteTone, faceSeed, jobSprites, stationSprites,
  needsByProject, projectActivity, projectHexes, placeSprites, placeStation,
  hexSpiral, axialToPixel, buildScene, sceneBounds, initialViewBox, clampZoom, HEX_SIZE, LABEL_STEP
} from '../src/lib/world.js';
import { nextDelay, MAX_BACKOFF_MS } from '../src/lib/backoff.js';
import { ORPHAN_AFTER_S } from '../src/lib/jobs.js';

// The scene makes one promise a table does not: a raised hand means SOMEONE HAS
// TO DO SOMETHING. These tests are that promise — if a state that the system
// handles by itself ever starts raising a hand, the whole map stops being worth
// glancing at.

const running = (over = {}) => ({
  id: 'build-project-3-TK-1-1', project: 'project-3', kind: 'build', box: 'project-3-1',
  stage: 'execute', status: 'running', heartbeating: true, activity_age_s: 60, ...over
});

// ------------------------------------------------------------ sprite state

test('a beating, fresh claim is working and keeps its hand down', () => {
  assert.equal(spriteState(running()), 'working');
  assert.equal(handRaised('working'), false);
  assert.equal(spriteTone('working'), 'ok');
});

test('a running claim whose beats stopped is stuck, hand up', () => {
  const s = spriteState(running({ activity_age_s: ORPHAN_AFTER_S + 1 }));
  assert.equal(s, 'stuck');
  assert.equal(handRaised(s), true);
  assert.equal(spriteTone(s), 'dead');
});

test('a claim that NEVER beat and has gone silent is quiet, not stuck', () => {
  // Same distinction lib/jobs.js draws: an old bin/ is a lower bound on life,
  // not a death, and calling it dead would teach the reader to discount red.
  const s = spriteState(running({ heartbeating: false, activity_age_s: ORPHAN_AFTER_S + 1 }));
  assert.equal(s, 'quiet');
  assert.equal(handRaised(s), true);
  assert.equal(spriteTone(s), 'warn');
});

test('a claim that never beat but is FRESH is still just working', () => {
  assert.equal(spriteState(running({ heartbeating: false, activity_age_s: 30 })), 'working');
});

test('parked and budget_stopped raise a hand — a person has to decide', () => {
  for (const status of ['parked', 'budget_stopped']) {
    const s = spriteState(running({ status }));
    assert.equal(s, 'blocked', status);
    assert.equal(handRaised(s), true, status);
  }
});

test('queued_for_retry does NOT raise a hand — the lane picks it up itself', () => {
  const s = spriteState(running({ status: 'queued_for_retry' }));
  assert.equal(s, 'waiting');
  assert.equal(handRaised(s), false);
});

test('orphaned raises a hand: the watchdog released the claim, nobody re-took it', () => {
  assert.equal(spriteState(running({ status: 'orphaned' })), 'stuck');
});

test('finished rows put nobody on the map — done and failed are history', () => {
  assert.equal(spriteState(running({ status: 'done' })), null);
  assert.equal(spriteState(running({ status: 'failed' })), null);
  assert.equal(spriteState(null), null);
});

// ------------------------------------------------------------ sprite rows

test('a sprite is labelled box + stage and links to that job', () => {
  const [s] = jobSprites({ jobs: [running()] });
  assert.equal(s.label, 'project-3-1 · execute');
  assert.equal(s.to, '/jobs/build-project-3-TK-1-1');
  assert.equal(s.project, 'project-3');
  assert.equal(s.raised, false);
});

test('a job id with a slash still produces a routable link', () => {
  const [s] = jobSprites({ jobs: [running({ id: 'fix/project-3#3' })] });
  assert.equal(s.to, '/jobs/fix%2Fproject-3%233');
});

test('finished rows are dropped from the scene, live ones kept', () => {
  const out = jobSprites({ jobs: [running(), running({ id: 'b', status: 'done' }), running({ id: 'c', status: 'parked' })] });
  assert.deepEqual(out.map((s) => s.job_id).sort(), ['build-project-3-TK-1-1', 'c']);
});

test('sprite order is stable so bodies do not teleport between polls', () => {
  const jobs = [running({ id: 'zz' }), running({ id: 'aa' }), running({ id: 'mm' })];
  const a = jobSprites({ jobs }).map((s) => s.id);
  const b = jobSprites({ jobs: [...jobs].reverse() }).map((s) => s.id);
  assert.deepEqual(a, b);
});

test('a missing jobs payload is an empty scene, never a throw', () => {
  assert.deepEqual(jobSprites(null), []);
  assert.deepEqual(jobSprites({}), []);
});

test('the same box always wears the same face', () => {
  assert.equal(faceSeed('project-3-1'), faceSeed('project-3-1'));
  assert.notEqual(faceSeed('project-3-1'), faceSeed('project-1-1'));
  assert.ok(faceSeed('anything') >= 0 && faceSeed('anything') < 6);
});

// ------------------------------------------------------------ the station

test('a box with nothing claimed sleeps at the station', () => {
  const live = jobSprites({ jobs: [running({ box: 'project-3-1' })] });
  const bunks = stationSprites({ boxes: { 'project-3-1': '2 minutes ago', 'project-1-1': '1 minute ago' } }, live);
  assert.deepEqual(bunks.map((b) => b.box), ['project-1-1']);
  assert.equal(bunks[0].state, 'asleep');
  assert.equal(bunks[0].raised, false);
  assert.equal(bunks[0].to, '/machines');
});

test('a box that is not answering the watchdog is a raised hand, not a nap', () => {
  const bunks = stationSprites({ boxes: { 'project-3-1': '3 hours ago' } }, []);
  assert.equal(bunks[0].state, 'offline');
  assert.equal(bunks[0].raised, true);
});

test('a silent box still shows even while it holds a claim — silence outranks work', () => {
  // The row says it is building; the watchdog says the machine stopped talking.
  // Hiding the box because a stale claim looks busy is exactly how a dead
  // builder goes unnoticed.
  const live = jobSprites({ jobs: [running({ box: 'project-3-1' })] });
  const bunks = stationSprites({ boxes: { 'project-3-1': '4 hours ago' } }, live);
  assert.equal(bunks.length, 1);
  assert.equal(bunks[0].state, 'offline');
  assert.equal(bunks[0].working_on, true);
});

test('no machines payload means no station, not a fabricated one', () => {
  assert.deepEqual(stationSprites(null, []), []);
});

// ------------------------------------------------------------ needs

test('needs are grouped by project, and project-less ones land on fleet', () => {
  const by = needsByProject({
    alerts: [{ id: 1, project: 'project-3', line: 'x' }, { id: 2, project: null, line: 'hub' }],
    builds: [{ id: 3, project: 'project-3', stage: 'plan', bkey: 'k' }],
    proposals: [{ pkey: 'p', project: 'project-4', slug: 's', title: 't' }]
  });
  assert.equal(by['project-3'].total, 2);
  assert.equal(by['project-3'].high, 2);
  assert.equal(by.fleet.total, 1);
  assert.equal(by['project-4'].high, 0);
});

// ------------------------------------------------------------ hexes

test('the spiral fills ring by ring and never repeats a cell', () => {
  const cells = hexSpiral(19);
  assert.equal(cells.length, 19);
  assert.deepEqual(cells[0], [0, 0]);
  assert.equal(new Set(cells.map((c) => c.join(','))).size, 19);
  // every cell in ring 1 is one step from the middle
  for (const [q, r] of cells.slice(1, 7)) {
    assert.equal((Math.abs(q) + Math.abs(r) + Math.abs(q + r)) / 2, 1);
  }
});

test('an empty spiral is empty rather than a phantom tile', () => {
  assert.deepEqual(hexSpiral(0), []);
});

test('axial coords convert to pixels with the centre at the origin', () => {
  assert.deepEqual(axialToPixel(0, 0, 10), { x: 0, y: 0 });
  assert.equal(Math.round(axialToPixel(0, 1, 10).y), 15);
});

test('live claims outweigh queue and PRs when deciding who sits in the middle', () => {
  assert.ok(projectActivity({ sprites: 2 }) > projectActivity({ queue: 5, prs: 5 }));
  assert.equal(projectActivity({}), 0);
});

test('the busiest project takes the centre tile and the biggest one', () => {
  const sprites = jobSprites({ jobs: [running({ id: 'a' }), running({ id: 'b' })] });
  const hexes = projectHexes({
    projects: { projects: [{ project: 'quiet-os' }, { project: 'project-3' }] },
    sprites, needs: {}
  });
  assert.equal(hexes[0].project, 'project-3');
  assert.deepEqual([hexes[0].q, hexes[0].r], [0, 0]);
  assert.ok(hexes[0].size > hexes[1].size);
  assert.equal(hexes[0].to, '/p/project-3');
});

test('a project live in the ledger but absent from the snapshot still gets a tile', () => {
  const sprites = jobSprites({ jobs: [running({ project: 'brand-new-os' })] });
  const hexes = projectHexes({ projects: { projects: [] }, sprites, needs: {} });
  assert.deepEqual(hexes.map((h) => h.project), ['brand-new-os']);
});

test('tile ordering is deterministic when two projects tie', () => {
  const hexes = projectHexes({ projects: { projects: [{ project: 'b-os' }, { project: 'a-os' }] }, sprites: [], needs: {} });
  assert.deepEqual(hexes.map((h) => h.project), ['a-os', 'b-os']);
});

test('a tile carries the raised-hand count for its own project', () => {
  const sprites = jobSprites({ jobs: [running({ id: 'p', status: 'parked' }), running({ id: 'q' })] });
  const [hex] = projectHexes({ projects: { projects: [{ project: 'project-3' }] }, sprites, needs: { 'project-3': { total: 3, high: 1 } } });
  assert.equal(hex.live, 2);
  assert.equal(hex.raised, 1);
  assert.equal(hex.needs, 3);
  assert.equal(hex.needs_high, 1);
});

// ------------------------------------------------------------ placement

test('sprites stand on their own project tile', () => {
  const sprites = jobSprites({ jobs: [running()] });
  const hexes = projectHexes({ projects: { projects: [{ project: 'project-3' }] }, sprites, needs: {} });
  const [placed] = placeSprites(sprites, hexes);
  assert.equal(placed.homeless, false);
  assert.ok(Math.hypot(placed.x - hexes[0].x, placed.y - hexes[0].y) < hexes[0].size);
});

test('a sprite with no project is marked homeless rather than dropped at 0,0', () => {
  const sprites = jobSprites({ jobs: [running({ project: null })] });
  const [placed] = placeSprites(sprites, []);
  assert.equal(placed.homeless, true);
  assert.equal(placed.x, null);
});

test('the station sits below every tile', () => {
  const hexes = projectHexes({ projects: { projects: [{ project: 'a-os' }, { project: 'b-os' }] }, sprites: [], needs: {} });
  const bunks = placeStation([{ id: 'box:x' }, { id: 'box:y' }], hexes);
  const lowest = Math.max(...hexes.map((h) => h.y + h.size));
  for (const b of bunks) assert.ok(b.y > lowest);
});

// ------------------------------------------------------------ whole scene

test('buildScene counts what the map claims in its header', () => {
  const scene = buildScene({
    jobs: { jobs: [running({ id: 'a' }), running({ id: 'b', status: 'parked' })] },
    needs: { alerts: [{ id: 1, project: 'project-3', line: 'x' }] },
    machines: { boxes: { 'project-3-1': '1 minute ago', 'idle-1': '2 minutes ago' } },
    projects: { projects: [{ project: 'project-3', open_prs: 2 }] }
  });
  assert.equal(scene.counts.working, 1);
  assert.equal(scene.counts.raised, 1);
  assert.equal(scene.counts.asleep, 1);
  assert.equal(scene.counts.needs, 1);
  assert.equal(scene.hexes.length, 1);
});

test('buildScene with nothing loaded is an empty, drawable scene', () => {
  const scene = buildScene({});
  assert.deepEqual(scene.hexes, []);
  assert.deepEqual(scene.sprites, []);
  assert.equal(scene.counts.raised, 0);
  const b = sceneBounds(scene);
  assert.ok(b.w > 0 && b.h > 0);
});

test('a narrow viewport starts zoomed in on the busiest tile, a wide one fits everything', () => {
  const scene = buildScene({
    jobs: { jobs: [running()] },
    projects: { projects: [{ project: 'project-3' }, { project: 'b-os' }, { project: 'c-os' }] }
  });
  const phone = initialViewBox(scene, { width: 375, height: 420 });
  const desk = initialViewBox(scene, { width: 1280, height: 600 });
  assert.ok(phone.w < desk.w);
  assert.ok(phone.w <= HEX_SIZE * 5.2 + 0.001);
  // the phone view is centred on the tile that sits in the middle
  assert.ok(Math.abs((phone.x + phone.w / 2) - scene.hexes[0].x) < 0.001);
  // the desktop view covers the whole scene
  const b = sceneBounds(scene);
  assert.ok(desk.w >= b.w - 0.001);
});

test('zoom is clamped so the scene can never be lost off-scale', () => {
  assert.equal(clampZoom(1, 600), 100);
  assert.equal(clampZoom(1e6, 600), 1500);
  assert.equal(clampZoom(600, 600), 600);
});

// ------------------------------------------------------------ polling

test('polling backs off on repeated failure and caps', () => {
  assert.equal(nextDelay(20000, 0), 20000);
  assert.equal(nextDelay(20000, 1), 40000);
  assert.equal(nextDelay(20000, 2), 80000);
  assert.equal(nextDelay(20000, 9), MAX_BACKOFF_MS);
});

test('sprites sharing a tile step their labels down so they do not overprint', () => {
  const jobs = [1, 2, 3, 4].map((n) => running({ id: `j${n}` }));
  const sprites = jobSprites({ jobs });
  const hexes = projectHexes({ projects: { projects: [{ project: 'project-3' }] }, sprites, needs: {} });
  const placed = placeSprites(sprites, hexes);
  assert.deepEqual(placed.map((s) => s.labelDy), [0, LABEL_STEP, LABEL_STEP * 2, 0]);
});

test('bunks are spaced by the label, not the body, and alternate lines', () => {
  const hexes = projectHexes({ projects: { projects: [{ project: 'a-os' }] }, sprites: [], needs: {} });
  const bunks = placeStation([{ id: 'x' }, { id: 'y' }, { id: 'z' }], hexes);
  assert.ok(bunks[1].x - bunks[0].x >= HEX_SIZE);
  assert.deepEqual(bunks.map((b) => b.labelDy), [0, LABEL_STEP, 0]);
});
