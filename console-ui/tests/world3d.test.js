import test from 'node:test';
import assert from 'node:assert/strict';
import { buildScene, HEX_SIZE } from '../src/lib/world.js';
import {
  fibonacciSphere, tangentBasis, offsetOnSphere, angleBetween, norm, dot,
  capRadius, capElevation, sizeBand, territoryColor, territories, ownerAt,
  bodyPlacement, agents, station, buildWorld3D, worldKey,
  getSkin, skinNames, SKINS, DEFAULT_SKIN, MIN_CAP, MAX_CAP, STATION_RADIUS
} from '../src/lib/world3d.js';
import { detectWebGL, hasWebGL, resetWebGLCache } from '../src/lib/webgl.js';

// The planet is allowed to be pretty. It is not allowed to lie: a body stands
// on its own project's ground, a raised hand carries a light, and the same data
// polled twice puts everyone back on the same square metre.

const job = (over = {}) => ({
  id: 'build-project-3-TK-1-1', project: 'project-3', kind: 'build', box: 'project-3-1',
  stage: 'execute', status: 'running', heartbeating: true, activity_age_s: 60, ...over
});

const fixture = () => ({
  jobs: {
    jobs: [
      job(),
      job({ id: 'build-project-3-TK-2-1', stage: 'review', box: 'project-3-2' }),
      job({ id: 'build-project-1-TK-9-1', project: 'project-1', box: 'project-1-1', status: 'parked' }),
      job({ id: 'build-project-4-TK-3-1', project: 'project-4', box: 'project-4-1' })
    ]
  },
  projects: {
    projects: [
      { project: 'project-3', open_prs: 2, open_alerts: 0, fleet: { queue_depth: 3 } },
      { project: 'project-1', open_prs: 0, open_alerts: 1, fleet: { queue_depth: 0 } },
      { project: 'project-4', open_prs: 1, open_alerts: 0, fleet: { queue_depth: 0 } },
      { project: 'project-5', open_prs: 0, open_alerts: 0, paused: true, fleet: { queue_depth: 0 } }
    ]
  },
  machines: { boxes: { 'project-3-1': '2m ago', 'project-3-2': '1m ago', 'hub-1': '3m ago', 'project-9-1': '4h ago' } },
  needs: { alerts: [], commands: [], builds: [], ideas: [] }
});

const world = (over) => buildWorld3D(buildScene({ ...fixture(), ...over }));

// ------------------------------------------------------------ sphere maths

test('fibonacci points are unit vectors and none of them collide', () => {
  const pts = fibonacciSphere(12);
  assert.equal(pts.length, 12);
  for (const p of pts) assert.ok(Math.abs(Math.hypot(...p) - 1) < 1e-9);
  for (let i = 0; i < pts.length; i++) {
    for (let j = i + 1; j < pts.length; j++) {
      assert.ok(angleBetween(pts[i], pts[j]) > 0.2, `${i} and ${j} are on top of each other`);
    }
  }
});

test('the busiest project gets the most visible ground, not a pole', () => {
  // Tiles arrive sorted busiest-first, so point 0 has to be the equatorial one.
  const pts = fibonacciSphere(9);
  assert.ok(Math.abs(pts[0][1]) <= Math.abs(pts[8][1]));
  assert.ok(Math.abs(pts[0][1]) < 0.2);
});

test('one project alone sits on the equator rather than at the north pole', () => {
  assert.deepEqual(fibonacciSphere(1), [[1, 0, 0]]);
});

test('a tangent basis is perpendicular to its normal and to itself, poles included', () => {
  for (const n of [[0, 1, 0], [0, -1, 0], norm([0.3, 0.2, -0.9])]) {
    const [t, b] = tangentBasis(n);
    assert.ok(Math.abs(dot(n, t)) < 1e-9);
    assert.ok(Math.abs(dot(n, b)) < 1e-9);
    assert.ok(Math.abs(dot(t, b)) < 1e-9);
  }
});

test('walking a known angle from a centre lands exactly that far away', () => {
  const c = norm([0.2, 0.6, 0.3]);
  for (const a of [0.05, 0.4, 1.1]) {
    const p = offsetOnSphere(c, a, 2.2);
    assert.ok(Math.abs(Math.hypot(...p) - 1) < 1e-9);
    assert.ok(Math.abs(angleBetween(c, p) - a) < 1e-9);
  }
});

// ------------------------------------------------------------ territories

test('caps shrink as projects are added but never past the readable floor', () => {
  assert.ok(capRadius(2) > capRadius(20));
  assert.equal(capRadius(400), MIN_CAP);
  // Below four projects the cap stops growing: one lonely project owning a
  // whole hemisphere is a worse picture than one big island in a big sea.
  assert.equal(capRadius(1), capRadius(4));
  assert.ok(capRadius(1) <= MAX_CAP);
  // and never so big that the sea disappears: caps that tile the sphere leave
  // no coastline, and a planet with no coastline is one green ball.
  assert.ok(capRadius(9) < Math.acos(1 - 2 / 9));
});

test('a quiet project gets a smaller, lower island than a busy one', () => {
  const w = world();
  const busy = w.territories[0];
  const quiet = w.territories[w.territories.length - 1];
  assert.ok(busy.band >= quiet.band);
  assert.ok(busy.radius >= quiet.radius);
  assert.ok(capElevation(busy.band) >= capElevation(quiet.band));
  assert.equal(sizeBand({ size: HEX_SIZE }), 1);
});

test('every project on the flat map is a territory on the planet, in the same order', () => {
  const scene = buildScene(fixture());
  const w = buildWorld3D(scene);
  assert.deepEqual(w.territories.map((t) => t.project), scene.hexes.map((h) => h.project));
  assert.equal(w.counts.territories, scene.hexes.length);
});

test('a territory keeps the flat tile’s link and its own counts', () => {
  const t = world().territories.find((x) => x.project === 'project-3');
  assert.equal(t.to, '/p/project-3');
  assert.equal(t.live, 2);
  assert.ok(t.title.includes('2 live claims'));
});

test('a paused project is drained of colour, never of position', () => {
  const w = world();
  const paused = w.territories.find((t) => t.project === 'project-5');
  const live = w.territories.find((t) => t.project === 'project-3');
  assert.equal(paused.paused, true);
  assert.ok(paused.color.l < live.color.l);
  assert.ok(paused.color.s < live.color.s);
  assert.ok(Math.abs(Math.hypot(...paused.center) - 1) < 1e-9);
  assert.ok(paused.title.includes('PAUSED'));
});

test('ground belongs to the nearest cap that actually reaches it — everything else is ocean', () => {
  const w = world();
  const t = w.territories[1];
  assert.equal(ownerAt(t.center, w.territories), 1);
  assert.equal(ownerAt(offsetOnSphere(t.center, t.radius * 0.5, 1), w.territories), 1);
  // Just past the rim, walking away from every other centre, is nobody's.
  const outside = offsetOnSphere(t.center, t.radius * 1.02, 1);
  assert.notEqual(ownerAt(outside, w.territories), 1);
  // And the planet really does have sea on it: caps sized for four projects
  // cannot tile a sphere, so some of the surface must belong to no one.
  let ocean = 0;
  for (const p of fibonacciSphere(400)) if (ownerAt(p, w.territories) === -1) ocean++;
  assert.ok(ocean > 0, 'every square metre was claimed — the caps are too big');
});

test('an empty fleet makes an empty planet rather than throwing', () => {
  const w = buildWorld3D(buildScene({}));
  assert.deepEqual(w.territories, []);
  assert.deepEqual(w.agents, []);
  assert.equal(w.counts.beacons, 0);
});

// ------------------------------------------------------------ bodies

test('every live claim stands inside its OWN project’s territory', () => {
  const w = world();
  const byProject = new Map(w.territories.map((t) => [t.project, t]));
  for (const a of w.agents) {
    assert.equal(a.homeless, false, a.id);
    const t = byProject.get(a.project);
    assert.equal(a.territory, t.project);
    assert.ok(angleBetween(a.dir, t.center) < t.radius, `${a.id} is standing in the sea`);
    assert.ok(Math.hypot(...a.position) > 1, `${a.id} is inside the planet`);
  }
});

test('two bodies on one island do not stand in the same spot', () => {
  const w = world();
  const [a, b] = w.agents.filter((x) => x.project === 'project-3');
  assert.ok(angleBetween(a.dir, b.dir) > 0.02);
  assert.notEqual(a.seat, b.seat);
});

test('the same data polled twice puts everybody back where they were', () => {
  const a = world();
  const b = world();
  assert.equal(worldKey(a), worldKey(b));
  assert.deepEqual(a.agents.map((x) => x.position), b.agents.map((x) => x.position));
});

test('a hand up carries a beacon; hands down do not', () => {
  const w = world();
  const parked = w.agents.find((a) => a.id === 'job:build-project-1-TK-9-1');
  assert.equal(parked.state, 'blocked');
  assert.equal(parked.raised, true);
  assert.equal(parked.beacon, true);
  assert.equal(parked.walks, false);
  const working = w.agents.find((a) => a.id === 'job:build-project-3-TK-1-1');
  assert.equal(working.beacon, false);
  assert.equal(working.walks, true);
  assert.equal(w.counts.beacons, 2); // the parked claim + the box that stopped pinging
});

test('a body keeps the flat map’s label and link — the tap goes to the same page', () => {
  const a = world().agents.find((x) => x.id === 'job:build-project-3-TK-1-1');
  assert.equal(a.label, 'project-3-1 · execute');
  assert.equal(a.to, '/jobs/build-project-3-TK-1-1');
});

test('a claim naming a project the hub has never heard of still gets ground', () => {
  const w = world({ jobs: { jobs: [job({ id: 'x-1', project: 'brand-new' })] } });
  const t = w.territories.find((x) => x.project === 'brand-new');
  assert.ok(t, 'the union of ledger and snapshot wins, as on the flat map');
  assert.equal(w.agents[0].homeless, false);
});

test('a claim with no project at all is homeless and gets no position, not a fake one', () => {
  const w = world({ jobs: { jobs: [job({ id: 'x-1', project: null })] } });
  assert.equal(w.agents[0].homeless, true);
  assert.equal(w.agents[0].position, null);
  assert.equal(w.counts.standing, 0);
  assert.equal(w.counts.homeless, 1);
});

// ------------------------------------------------------------ station

test('idle boxes sleep on an orbital ring, evenly spaced, outside the planet', () => {
  const w = world();
  assert.ok(w.station.length >= 2);
  for (const s of w.station) {
    const r = Math.hypot(s.position[0], s.position[2]);
    assert.ok(r > 1.2, 'the station is in orbit, not underground');
    assert.ok(r <= STATION_RADIUS + 1e-9);
  }
  const angles = w.station.map((s) => s.ringAngle);
  assert.deepEqual(angles, [...angles].sort((a, b) => a - b));
});

test('a box that stopped answering sleeps with a beacon on', () => {
  const w = world();
  const dead = w.station.find((s) => s.box === 'project-9-1');
  assert.equal(dead.state, 'offline');
  assert.equal(dead.beacon, true);
  const idle = w.station.find((s) => s.box === 'hub-1');
  assert.equal(idle.state, 'asleep');
  assert.equal(idle.beacon, false);
  assert.equal(idle.to, '/machines');
});

// ------------------------------------------------------------ skins

test('a skin moves colour and nothing else', () => {
  const scene = buildScene(fixture());
  const a = buildWorld3D(scene, { skin: 'terra' });
  const b = buildWorld3D(scene, { skin: 'does-not-exist' });
  assert.equal(b.skin.name, DEFAULT_SKIN);
  assert.deepEqual(a.agents.map((x) => x.position), b.agents.map((x) => x.position));
  assert.deepEqual(a.territories.map((x) => x.center), b.territories.map((x) => x.center));
  assert.ok(skinNames().includes(DEFAULT_SKIN));
  assert.equal(getSkin(undefined).name, DEFAULT_SKIN);
});

test('every skin declares the colours the renderer reads, in range', () => {
  for (const [name, s] of Object.entries(SKINS)) {
    for (const key of ['ocean', 'atmosphere', 'star']) {
      const c = s[key];
      assert.ok(c && c.h >= 0 && c.h <= 1 && c.s >= 0 && c.s <= 1 && c.l >= 0 && c.l <= 1, `${name}.${key}`);
    }
    const c = territoryColor({ hue: 350, live: 1 }, s);
    assert.ok(c.h >= 0 && c.h <= 1 && c.l > 0 && c.l < 1);
  }
});

test('the rebuild key changes when a body changes state and not when a heartbeat ticks', () => {
  const base = fixture();
  const a = buildWorld3D(buildScene(base));
  const same = buildWorld3D(buildScene({ ...base, jobs: { jobs: base.jobs.jobs.map((j) => ({ ...j, activity_age_s: 61 })) } }));
  assert.equal(worldKey(a), worldKey(same));
  const parked = buildWorld3D(buildScene({ ...base, jobs: { jobs: base.jobs.jobs.map((j, i) => (i ? j : { ...j, status: 'parked' })) } }));
  assert.notEqual(worldKey(a), worldKey(parked));
});

// ------------------------------------------------------------ the fallback

test('no document, no canvas and a throwing canvas all mean: draw the flat map', () => {
  assert.equal(detectWebGL(null), false);
  assert.equal(detectWebGL({}), false);
  assert.equal(detectWebGL({ createElement: () => { throw new Error('nope'); } }), false);
  assert.equal(detectWebGL({ createElement: () => ({}) }), false);
  assert.equal(detectWebGL({ createElement: () => ({ getContext: () => null }) }), false);
  assert.equal(detectWebGL({ createElement: () => ({ getContext: () => { throw new Error('blocked'); } }) }), false);
});

test('a context on any of the three names is enough, and the probe hands it back', () => {
  let lost = 0;
  const ctx = { getExtension: (n) => (n === 'WEBGL_lose_context' ? { loseContext: () => { lost++; } } : null) };
  assert.equal(detectWebGL({ createElement: () => ({ getContext: (n) => (n === 'webgl2' ? ctx : null) }) }), true);
  assert.equal(detectWebGL({ createElement: () => ({ getContext: (n) => (n === 'experimental-webgl' ? ctx : null) }) }), true);
  assert.equal(lost, 2, 'the probe must not keep a context the renderer needs');
});

test('the probe is asked once per page load, not once per render', () => {
  resetWebGLCache();
  let calls = 0;
  const doc = { createElement: () => { calls++; return { getContext: () => null }; } };
  hasWebGL(doc); hasWebGL(doc); hasWebGL(doc);
  assert.equal(calls, 1);
  resetWebGLCache();
});
