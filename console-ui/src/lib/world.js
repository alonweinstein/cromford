// The WORLD scene's whole mind. Nothing in this file touches the DOM or the
// network: what a job row MEANS in the scene — working, hand-raised, asleep —
// and where every body stands are pure functions, so the rules are read in
// tests/world.test.js rather than squinted at in a browser at 375px.
//
// The rule this file keeps, inherited from lib/jobs.js: the coordination DB is
// COORDINATION truth. A sprite is what a claimant reported about ITSELF. So the
// scene never invents a state it was not told about — a job with no phase, a
// box with no ping and a project with no rows each render as the honest absence
// rather than as a cheerful default.

import { jobState } from './jobs.js';
import { healthFromAge, minutesFromPingText } from './format.js';
import { needRows } from './cockpit.js';

// ---------------------------------------------------------------- sprites

// Which ledger states put a body on the planet at all. `done` and `failed` are
// deliberately absent: they are history, and a scene that keeps every finished
// claim would fill with corpses until the live rows were the hard part to find.
// HISTORY and JOBS already own the finished ones.
const LIVE_STATES = new Set([
  'running', 'stalled', 'quiet', 'orphaned', 'parked', 'queued_for_retry', 'budget_stopped'
]);

// Ledger state -> what the little person is doing.
//   working  — beating, fresh, hands on the keyboard
//   waiting  — queued for a retry the LANE will pick up; nobody is blocked
//   quiet    — never beat and has gone silent: a lower bound, not a death
//   blocked  — parked or out of budget: a person has to decide something
//   stuck    — beats stopped, or the watchdog already released the claim
const STATE_MAP = {
  running: 'working',
  queued_for_retry: 'waiting',
  quiet: 'quiet',
  parked: 'blocked',
  budget_stopped: 'blocked',
  stalled: 'stuck',
  orphaned: 'stuck'
};

export function spriteState(job) {
  const s = jobState(job);
  if (!LIVE_STATES.has(s)) return null;
  return STATE_MAP[s] || null;
}

// The hand goes up only for states a HUMAN has to answer. `waiting` keeps its
// hand down on purpose: the watchdog judged that row retryable and the lane's
// own next tick takes it, so raising a hand for it would teach the reader to
// ignore the raised hands that mean something.
const RAISED = new Set(['blocked', 'stuck', 'quiet']);
export const handRaised = (state) => RAISED.has(state);

const TONE = { working: 'ok', waiting: 'warn', quiet: 'warn', blocked: 'warn', stuck: 'dead', asleep: 'idle', offline: 'dead' };
export const spriteTone = (state) => TONE[state] || 'idle';

export const SPRITE_LABEL = {
  working: 'WORKING', waiting: 'QUEUED', quiet: 'GONE QUIET',
  blocked: 'NEEDS A DECISION', stuck: 'BEATS STOPPED', asleep: 'IDLE', offline: 'NOT ANSWERING'
};

// A stable small integer per box, so the same machine always wears the same
// face. Sprites are only tellable apart if the face does not shuffle on poll.
export function faceSeed(name, buckets = 6) {
  const s = String(name || '');
  let h = 0;
  for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) >>> 0;
  return buckets > 0 ? h % buckets : 0;
}

export function jobSprites(payload) {
  const jobs = (payload && payload.jobs) || [];
  return jobs
    .map((j) => {
      const state = spriteState(j);
      if (!state) return null;
      const box = j.box || 'unclaimed';
      return {
        id: `job:${j.id}`,
        job_id: j.id,
        kind: 'job',
        box,
        project: j.project || null,
        stage: j.stage || '?',
        job_kind: j.kind || '?',
        ticket_id: j.ticket_id || null,
        state,
        raised: handRaised(state),
        tone: spriteTone(state),
        face: faceSeed(box),
        // box + stage, as the label on the sprite. It is the pair that answers
        // "who is this and what are they doing" without a tap.
        label: `${box} · ${j.stage || '?'}`,
        to: `/jobs/${encodeURIComponent(j.id)}`
      };
    })
    .filter(Boolean)
    // Position follows list order, so the order has to be stable across polls
    // or the whole scene shuffles every 20 seconds.
    .sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
}

// Boxes with nothing claimed are asleep at the station. A box that is not
// answering the watchdog is NOT asleep — it is a raised hand, because the
// difference between "idle" and "gone" is the whole reason MACHINES exists.
export function stationSprites(machinesPayload, jobSpriteList = []) {
  const boxes = (machinesPayload && machinesPayload.boxes) || {};
  const busy = new Set(jobSpriteList.map((s) => s.box));
  return Object.keys(boxes)
    .sort()
    .map((name) => {
      const min = minutesFromPingText(boxes[name]);
      const health = healthFromAge(min);
      const silent = health === 'dead' || health === 'unknown';
      if (!silent && busy.has(name)) return null;
      const state = silent ? 'offline' : 'asleep';
      return {
        id: `box:${name}`,
        kind: 'box',
        box: name,
        project: null,
        state,
        raised: silent,
        tone: spriteTone(state),
        face: faceSeed(name),
        working_on: busy.has(name),
        label: `${name} · ${silent ? 'no ping' : 'idle'}`,
        to: '/machines'
      };
    })
    .filter(Boolean);
}

// ---------------------------------------------------------------- hexes

// Pointy-top axial hex coordinates, walked outward ring by ring. The busiest
// project lands in the middle because the list is sorted before it is placed.
const RING_DIRS = [[1, -1], [0, -1], [-1, 0], [-1, 1], [0, 1], [1, 0]];

export function hexSpiral(n) {
  const out = [];
  if (n <= 0) return out;
  out.push([0, 0]);
  for (let ring = 1; out.length < n; ring++) {
    let q = RING_DIRS[4][0] * ring;
    let r = RING_DIRS[4][1] * ring;
    for (let d = 0; d < 6; d++) {
      for (let i = 0; i < ring; i++) {
        out.push([q, r]);
        q += RING_DIRS[d][0];
        r += RING_DIRS[d][1];
      }
    }
  }
  return out.slice(0, n);
}

export const axialToPixel = (q, r, size) => ({
  x: size * Math.sqrt(3) * (q + r / 2),
  y: size * 1.5 * r
});

// Base radius of a tile, in scene units. Sprites are sized against it, so this
// is the one number to move if the whole planet wants to be bigger.
export const HEX_SIZE = 84;

// One line of label, in scene units. Sprites that share a tile step their
// labels down by multiples of it.
export const LABEL_STEP = 9.5;

// How much of a tile a project earns. Live claims dominate because they are the
// thing that is HAPPENING; a queue and open PRs are pressure, not activity, so
// they count for less. Nothing here is a score to optimise — it only decides
// who sits in the middle and how big the tile is drawn.
export function projectActivity({ sprites = 0, queue = 0, prs = 0, needs = 0 }) {
  return sprites * 4 + needs * 2 + Math.min(Number(queue) || 0, 12) + Math.min(Number(prs) || 0, 12) * 0.5;
}

// Needs rows keyed by project. The rows and their severities come from
// lib/cockpit.js — NEEDS already owns what "waiting on a person" means, and a
// second copy of that rule here would be a second place for it to drift.
// `fleet` collects the ones with no project, which is a real category (hub
// alerts), not a bug to hide.
export function needsByProject(payload) {
  const out = {};
  for (const r of needRows(payload)) {
    const key = r.project || 'fleet';
    const e = out[key] || (out[key] = { total: 0, high: 0 });
    e.total += 1;
    if (r.severity === 'high') e.high += 1;
  }
  return out;
}

export function projectHexes({ projects, sprites = [], needs = {}, size = HEX_SIZE }) {
  const rows = (projects && projects.projects) || [];
  const byName = new Map();
  for (const r of rows) {
    if (!r || !r.project) continue;
    byName.set(r.project, r);
  }
  // A project can be live in the ledger before the hub's snapshot knows about
  // it. Dropping it would hide a running build, so the union wins.
  for (const s of sprites) if (s.project && !byName.has(s.project)) byName.set(s.project, { project: s.project });

  const counts = {};
  for (const s of sprites) if (s.project) counts[s.project] = (counts[s.project] || 0) + 1;

  const tiles = [...byName.values()].map((r) => {
    const n = needs[r.project] || { total: 0, high: 0 };
    const live = counts[r.project] || 0;
    return {
      project: r.project,
      live,
      raised: sprites.filter((s) => s.project === r.project && s.raised).length,
      queue: (r.fleet && r.fleet.queue_depth) || 0,
      prs: r.open_prs || 0,
      alerts: r.open_alerts || 0,
      paused: Boolean(r.paused),
      needs: n.total,
      needs_high: n.high,
      last_run_age_min: r.last_run_age_min === undefined ? null : r.last_run_age_min,
      activity: projectActivity({ sprites: live, queue: (r.fleet && r.fleet.queue_depth) || 0, prs: r.open_prs || 0, needs: n.total }),
      hue: faceSeed(r.project, 360),
      to: `/p/${encodeURIComponent(r.project)}`
    };
  });

  tiles.sort((a, b) => b.activity - a.activity || (a.project < b.project ? -1 : 1));

  const cells = hexSpiral(tiles.length);
  return tiles.map((t, i) => {
    const [q, r] = cells[i];
    const { x, y } = axialToPixel(q, r, size);
    // Three bands, not a continuous scale: a tile that breathes a few percent
    // every poll reads as noise, and the size is only meant to say "this one is
    // busier than that one".
    const band = t.activity >= 12 ? 1 : t.activity >= 4 ? 0.86 : 0.72;
    return { ...t, q, r, x, y, size: size * band };
  });
}

// Sprites stand ON their project's tile, on a ring inside it. Order is the
// sprite list's own (stable) order, so nobody teleports between polls.
export function placeSprites(sprites, hexes) {
  const byProject = new Map(hexes.map((h) => [h.project, h]));
  const seen = new Map();
  return sprites.map((s) => {
    const hex = s.project ? byProject.get(s.project) : null;
    const n = seen.get(s.project) || 0;
    seen.set(s.project, n + 1);
    if (!hex) return { ...s, x: null, y: null, homeless: true };
    const ring = Math.floor(n / 6);
    const idxInRing = n % 6;
    const radius = hex.size * (ring === 0 ? 0.42 : 0.72);
    const angle = -Math.PI / 2 + (idxInRing * Math.PI) / 3 + (ring % 2 ? Math.PI / 6 : 0);
    return {
      ...s,
      x: hex.x + radius * Math.cos(angle),
      // The ring sits a little above the tile's middle: the bottom of a hexagon
      // carries the project's own name, and a sprite's label must not print
      // over the label that says which project you are looking at.
      y: hex.y - hex.size * 0.16 + radius * Math.sin(angle) * 0.9,
      // Labels are the whole point of a sprite (box + stage), and three of them
      // on one tile are wider than the tile. Stepping each one down a line
      // keeps them all readable instead of overprinting into a smear.
      labelDy: LABEL_STEP * (n % 3),
      homeless: false
    };
  });
}

// The station is a row under the planet: one bunk per idle box.
export function placeStation(boxSprites, hexes, size = HEX_SIZE) {
  const maxY = hexes.reduce((m, h) => Math.max(m, h.y + h.size), 0);
  const y = maxY + size * 0.95;
  // A box name is a long label under a small body, so the bunks are spaced by
  // the LABEL's width, not the sprite's, and alternate lines on top of that.
  const gap = size * 1.3;
  const width = (boxSprites.length - 1) * gap;
  return boxSprites.map((s, i) => ({ ...s, x: i * gap - width / 2, y, labelDy: LABEL_STEP * (i % 2) }));
}

// ---------------------------------------------------------------- scene

export function buildScene({ jobs, needs, machines, projects } = {}) {
  const live = jobSprites(jobs);
  const station = stationSprites(machines, live);
  const byProject = needsByProject(needs);
  const hexes = projectHexes({ projects, sprites: live, needs: byProject });
  const placed = placeSprites(live, hexes);
  const bunks = placeStation(station, hexes);
  return {
    hexes,
    sprites: placed,
    station: bunks,
    counts: {
      working: placed.filter((s) => s.state === 'working').length,
      raised: placed.filter((s) => s.raised).length + bunks.filter((s) => s.raised).length,
      asleep: bunks.filter((s) => s.state === 'asleep').length,
      needs: Object.values(byProject).reduce((n, e) => n + e.total, 0)
    },
    needs_by_project: byProject
  };
}

// The box the scene occupies, padded. An empty scene still returns a usable box
// rather than a zero-sized one that would divide by zero on the first render.
export function sceneBounds(scene, pad = HEX_SIZE * 0.55) {
  const pts = [];
  for (const h of scene.hexes) pts.push({ x: h.x, y: h.y, r: h.size });
  for (const s of scene.station) pts.push({ x: s.x, y: s.y, r: HEX_SIZE * 0.4 });
  if (!pts.length) return { x: -200, y: -140, w: 400, h: 280 };
  const minX = Math.min(...pts.map((p) => p.x - p.r));
  const maxX = Math.max(...pts.map((p) => p.x + p.r));
  const minY = Math.min(...pts.map((p) => p.y - p.r));
  const maxY = Math.max(...pts.map((p) => p.y + p.r));
  return { x: minX - pad, y: minY - pad, w: (maxX - minX) + pad * 2, h: (maxY - minY) + pad * 2 };
}

// Where the camera starts. On a phone, fitting the whole planet into 375px
// makes every sprite a 20px target, so a narrow viewport starts zoomed IN on
// the busiest tile and pans; a wide one fits the lot.
export function initialViewBox(scene, { width = 1024, height = 560, narrowAt = 700 } = {}) {
  const bounds = sceneBounds(scene);
  const aspect = height > 0 ? width / height : 1.6;
  const fitW = Math.max(bounds.w, bounds.h * aspect);
  if (width >= narrowAt || !scene.hexes.length) {
    const h = fitW / aspect;
    return { x: bounds.x + bounds.w / 2 - fitW / 2, y: bounds.y + bounds.h / 2 - h / 2, w: fitW, h };
  }
  const focus = scene.hexes[0];
  const w = Math.min(fitW, HEX_SIZE * 5.2);
  const h = w / aspect;
  return { x: focus.x - w / 2, y: focus.y - h / 2, w, h };
}

export const clampZoom = (w, baseW) => Math.min(Math.max(w, baseW / 6), baseW * 2.5);
