// Where everything STANDS on the planet — the 3D scene's whole mind.
//
// Same contract lib/world.js keeps for the flat map: no DOM, no network, no
// three.js. This file turns the scene that buildScene() already decided (which
// projects exist, who is live, whose hand is up) into positions on a unit
// sphere, and nothing else. The renderer in world3d/planet.js is then a dumb
// hand: it reads these numbers and draws them.
//
// Keeping it pure is what lets tests/world3d.test.js assert the things that
// actually matter and cannot be eyeballed in a browser — that an agent stands
// INSIDE its own project's territory, that a hand-up body carries a beacon,
// that nobody teleports between two polls of the same data.

import { HEX_SIZE } from './world.js';

// ---------------------------------------------------------------- skins
//
// A skin is COSMETIC ONLY. It may move a colour, never a body: every position
// in this file is computed before a skin is consulted, so adding a skin can
// never change what the scene says. One ships today; the registry is here so
// the second one is a data literal and not a refactor.

export const SKINS = {
  terra: {
    name: 'terra',
    label: 'TERRA',
    // The phosphor palette this console is built from, as scene colours.
    ocean: { h: 0.47, s: 0.55, l: 0.045 },
    atmosphere: { h: 0.36, s: 0.70, l: 0.45 },
    star: { h: 0.33, s: 0.25, l: 0.78 },
    // Project hues are pulled toward the console's greens rather than used
    // raw: a full-spectrum planet stops looking like this product. Enough
    // spread is left that two neighbouring islands are never the same colour.
    hueSpread: 0.62,
    hueShift: 96,
    landSat: 0.46,
    landLight: 0.30,
    busyBoost: 0.10,
    pausedDrain: 0.55,
    rimLight: 0.52
  }
};

export const DEFAULT_SKIN = 'terra';
export const getSkin = (name) => SKINS[name] || SKINS[DEFAULT_SKIN];
export const skinNames = () => Object.keys(SKINS);

// ---------------------------------------------------------------- vectors

export const norm = (v) => {
  const m = Math.hypot(v[0], v[1], v[2]) || 1;
  return [v[0] / m, v[1] / m, v[2] / m];
};
export const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
export const scale = (v, k) => [v[0] * k, v[1] * k, v[2] * k];
export const add = (a, b) => [a[0] + b[0], a[1] + b[1], a[2] + b[2]];
export const angleBetween = (a, b) => Math.acos(Math.min(1, Math.max(-1, dot(norm(a), norm(b)))));

// Two unit vectors perpendicular to `n` and to each other: the local "ground
// plane" of a territory, so a body can be placed a known angle away from the
// centre in a known direction.
export function tangentBasis(n) {
  const up = Math.abs(n[1]) > 0.92 ? [1, 0, 0] : [0, 1, 0];
  const t = norm([
    up[1] * n[2] - up[2] * n[1],
    up[2] * n[0] - up[0] * n[2],
    up[0] * n[1] - up[1] * n[0]
  ]);
  const b = [
    n[1] * t[2] - n[2] * t[1],
    n[2] * t[0] - n[0] * t[2],
    n[0] * t[1] - n[1] * t[0]
  ];
  return [t, b];
}

// Walk `angle` radians away from `center` in direction `az` around it.
export function offsetOnSphere(center, angle, az) {
  const [t, b] = tangentBasis(center);
  const dir = add(scale(t, Math.cos(az)), scale(b, Math.sin(az)));
  return norm(add(scale(center, Math.cos(angle)), scale(dir, Math.sin(angle))));
}

// ---------------------------------------------------------------- territories

// Evenly spread points on a sphere. Deterministic, and re-ordered so the FIRST
// point is nearest the equator: the tile list arrives sorted busiest-first and
// the busiest project should not be the one hiding at a pole.
const GOLDEN_ANGLE = Math.PI * (3 - Math.sqrt(5));

export function fibonacciSphere(n) {
  const pts = [];
  for (let i = 0; i < n; i++) {
    const y = n === 1 ? 0 : 1 - ((2 * i + 1) / n);
    const r = Math.sqrt(Math.max(0, 1 - y * y));
    const th = i * GOLDEN_ANGLE;
    pts.push([Math.cos(th) * r, y, Math.sin(th) * r]);
  }
  return pts
    .map((p, i) => ({ p, i, k: Math.abs(p[1]) }))
    .sort((a, b) => a.k - b.k || a.i - b.i)
    .map((e) => e.p);
}

// The three size bands lib/world.js already chose, read back off the tile.
// Bands, not a continuous scale, for the same reason as there: a planet whose
// islands breathe a few percent every poll reads as noise.
export const sizeBand = (tile) => (tile && tile.size ? tile.size / HEX_SIZE : 1);

// Angular radius of a territory's cap, in radians. Equal-area spacing for the
// count, scaled by the tile's band, then clamped so one lonely project does not
// swallow the whole globe and twenty do not become invisible freckles.
export const MIN_CAP = 0.17;
export const MAX_CAP = 1.05;

// 0.82 rather than 1: caps sized to exactly tile the sphere leave no sea, and a
// planet with no sea is one green ball with faint seams. The islands are meant
// to have coastlines.
export function capRadius(count, band = 1) {
  const n = Math.max(1, count);
  const equal = Math.acos(Math.max(-1, 1 - 2 / Math.max(4, n)));
  return Math.min(MAX_CAP, Math.max(MIN_CAP, equal * 0.82 * band));
}

// How high a territory sits above the ocean. Busy places are literally raised,
// and high enough that the coast is a visible cliff rather than a seam.
export const capElevation = (band) => 0.03 + band * 0.075;

export function territoryColor(tile, skin) {
  const hue = (((Number(tile.hue) || 0) * skin.hueSpread + skin.hueShift) % 360 + 360) % 360;
  let l = skin.landLight + (tile.live > 0 ? skin.busyBoost : 0);
  let s = skin.landSat;
  if (tile.paused) { l *= skin.pausedDrain; s *= 0.5; }
  return { h: hue / 360, s, l };
}

export function territories(scene, { skin = getSkin(DEFAULT_SKIN) } = {}) {
  const tiles = (scene && scene.hexes) || [];
  const pts = fibonacciSphere(tiles.length);
  return tiles.map((t, i) => {
    const band = sizeBand(t);
    return {
      ...t,
      kind: 'territory',
      id: `t:${t.project}`,
      center: pts[i],
      radius: capRadius(tiles.length, band),
      elevation: capElevation(band),
      band,
      color: territoryColor(t, skin),
      // Everything a tap has to answer without a second read.
      title: [
        `${t.live} live claim${t.live === 1 ? '' : 's'}`,
        t.needs ? `${t.needs} waiting on a person` : null,
        t.queue ? `queue ${t.queue}` : null,
        t.paused ? 'PAUSED' : null
      ].filter(Boolean).join(' · ')
    };
  });
}

// Which territory owns a point on the surface — the nearest centre whose cap
// actually reaches it. Anything else is ocean, and ocean is honest: it means no
// project claims that ground, not "assume the closest one".
export function ownerAt(point, terrs) {
  const p = norm(point);
  let best = -1;
  let bestDot = -2;
  for (let i = 0; i < terrs.length; i++) {
    const d = dot(p, terrs[i].center);
    if (d > bestDot && d >= Math.cos(terrs[i].radius)) { bestDot = d; best = i; }
  }
  return best;
}

// ---------------------------------------------------------------- bodies

// Bodies stand on a golden-angle spiral inside their own cap, filling it from
// the middle outward. The index is the body's position in the (already stable)
// sprite list, so the same job stands on the same spot at every poll — a scene
// that reshuffles on refresh is unreadable no matter how pretty it is.
export const BODY_INSET = 0.66;

export function bodyPlacement(index, terr) {
  const frac = (index + 0.35) / 7;
  const angle = terr.radius * BODY_INSET * Math.min(1, Math.sqrt(frac));
  const az = index * GOLDEN_ANGLE * 1.7;
  return offsetOnSphere(terr.center, angle, az);
}

export function agents(scene, terrs) {
  const byProject = new Map(terrs.map((t) => [t.project, t]));
  const seen = new Map();
  return ((scene && scene.sprites) || []).map((s) => {
    const terr = s.project ? byProject.get(s.project) : null;
    if (!terr) return { ...s, homeless: true, dir: null, position: null };
    const n = seen.get(s.project) || 0;
    seen.set(s.project, n + 1);
    const dir = bodyPlacement(n, terr);
    return {
      ...s,
      homeless: false,
      seat: n,
      territory: terr.project,
      // Direction from the planet's centre, and the height to stand at. The
      // renderer multiplies one by the other; keeping them apart is what lets a
      // test say "this body is inside that territory" in one line.
      dir,
      elevation: terr.elevation,
      position: scale(dir, 1 + terr.elevation),
      // A hand up is the only thing on this planet that gets a light of its
      // own. It has to be findable from the far side of the globe.
      beacon: Boolean(s.raised),
      // Walkers drift a little around their seat; everyone else stands still.
      walks: s.state === 'working',
      phase: (n * 1.7 + (s.face || 0) * 0.9) % (Math.PI * 2)
    };
  });
}

// ---------------------------------------------------------------- station

// Idle boxes are not on the planet: they are asleep on a ring in orbit above
// it. That is the honest picture — an idle box belongs to no project — and it
// keeps the surface for work that is actually happening.
export const STATION_RADIUS = 1.42;
export const STATION_TILT = 0.42;

export function station(scene) {
  const rows = (scene && scene.station) || [];
  const n = rows.length;
  return rows.map((s, i) => {
    const a = n ? (i / n) * Math.PI * 2 : 0;
    const x = Math.cos(a) * STATION_RADIUS;
    const z = Math.sin(a) * STATION_RADIUS;
    // One tilted ring, so it reads as an orbit rather than as a flat halo.
    const y = Math.sin(a) * Math.sin(STATION_TILT) * STATION_RADIUS * 0.55;
    return {
      ...s,
      kind: 'box',
      position: [x, y + 0.06, z * Math.cos(STATION_TILT)],
      ringAngle: a,
      beacon: Boolean(s.raised),
      walks: false,
      phase: (i * 1.1) % (Math.PI * 2)
    };
  });
}

// ---------------------------------------------------------------- the world

export function buildWorld3D(scene, { skin: skinName = DEFAULT_SKIN } = {}) {
  const skin = getSkin(skinName);
  const terrs = territories(scene, { skin });
  const bodies = agents(scene, terrs);
  return {
    skin,
    territories: terrs,
    agents: bodies,
    station: station(scene),
    // What the renderer needs to know before it builds a single mesh.
    counts: {
      territories: terrs.length,
      standing: bodies.filter((b) => !b.homeless).length,
      beacons: bodies.filter((b) => b.beacon).length + (scene && scene.station || []).filter((s) => s.raised).length,
      homeless: bodies.filter((b) => b.homeless).length
    }
  };
}

// A stable fingerprint of the world's SHAPE (who exists and where they stand),
// used to decide when the meshes have to be rebuilt. A poll that only moved a
// heartbeat by 20 seconds must not rebuild the planet under a moving thumb.
export function worldKey(world) {
  const t = world.territories.map((x) => `${x.project}:${x.band.toFixed(2)}:${x.live}:${x.raised}:${x.paused ? 1 : 0}:${x.needs}`).join(',');
  const a = world.agents.map((x) => `${x.id}:${x.state}`).join(',');
  const s = world.station.map((x) => `${x.id}:${x.state}`).join(',');
  return `${world.skin.name}|${t}|${a}|${s}`;
}
