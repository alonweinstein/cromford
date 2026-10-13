// Driving the world with the arrow keys — the whole rule set, with no DOM in it.
//
// Two renderers draw /world: the three.js planet and the flat hex map. They
// agree about almost nothing at the pixel level, so the thing that has to be
// shared is not the drawing but the DECISION: given where everything is on the
// screen right now, which body does "left" mean? That decision lives here, as
// pure functions over `{ id, x, y }` points, and both renderers hand it their
// own coordinates — scene units for the flat map, projected screen space for
// the planet. Neither one gets its own idea of what left means.
//
// The coordinate convention is the screen's, in BOTH callers: x grows to the
// right and y grows DOWNWARD. The flat map is already in that space; the
// planet's projection flips the y it gets back from three.js before calling in
// here (see navTargets() in world3d/planet.js).
//
// Everything below is tested in tests/worldnav.test.js, including the input
// guard — "typing in a filter box must never move the selection" is a rule you
// want a test to keep, not a browser.

import { sceneBounds, HEX_SIZE } from './world.js';

// ---------------------------------------------------------------- directions

// Unit vectors in screen space. `up` is -y because that is what up is on a
// screen, and getting this wrong is the classic way spatial navigation ends up
// upside down on one of two renderers.
export const DIRS = {
  left: [-1, 0],
  right: [1, 0],
  up: [0, -1],
  down: [0, 1]
};

// WASD are aliases, not a second scheme: they map onto exactly the same four
// directions, so there is one behaviour to test and one to document.
const KEY_DIR = {
  ArrowLeft: 'left', ArrowRight: 'right', ArrowUp: 'up', ArrowDown: 'down',
  a: 'left', d: 'right', w: 'up', s: 'down'
};

// A bare arrow or letter only. A modifier means the browser (or the OS) has a
// claim on that chord — cmd+left is "back", and stealing it would be rude.
export function keyToDirection(key, mods = {}) {
  if (mods.metaKey || mods.ctrlKey || mods.altKey) return null;
  if (typeof key !== 'string') return null;
  const k = key.length === 1 ? key.toLowerCase() : key;
  // Shift is allowed on the arrows and refused on the letters: shift+W is a
  // capital W somebody meant to type somewhere, not a movement.
  if (mods.shiftKey && k.length === 1) return null;
  return KEY_DIR[k] || null;
}

// ---------------------------------------------------------------- the move

// How much a candidate being off to the side costs, relative to how far away it
// is along the direction you actually pressed. 2 means "a body twice as far
// along beats a body half as far sideways", which is what makes a grid feel
// like a grid rather than like a spiral.
const PERP_COST = 2;

// Points closer together than this (in whatever units the caller is using) are
// treated as the same place, so a body standing on the exact centre of its own
// territory cannot become a direction of its own.
const EPS = 1e-6;

const byId = (entities, id) => entities.find((e) => e.id === id) || null;

// The next entity in a direction, or null when there is nothing that way.
//
// Two passes, deliberately. The first only looks inside a 45° cone around the
// direction pressed, which is what makes movement feel like movement: pressing
// right walks along the row you are in. The second pass opens up to the whole
// half-plane, so a lonely body way off to the top-right is still reachable with
// `right` instead of being stranded because nothing is exactly beside it.
export function nextInDirection(entities, currentId, dir) {
  const axis = DIRS[dir];
  if (!axis) return null;
  const cur = byId(entities, currentId);
  if (!cur) return null;

  let coned = null;
  let conedCost = Infinity;
  let open = null;
  let openCost = Infinity;

  for (const e of entities) {
    if (e === cur || e.id === cur.id) continue;
    const dx = e.x - cur.x;
    const dy = e.y - cur.y;
    const along = dx * axis[0] + dy * axis[1];
    if (along <= EPS) continue;
    const perp = Math.abs(dx * axis[1] - dy * axis[0]);
    const cost = along + perp * PERP_COST;
    if (perp <= along) {
      // Ties broken by id so the same press on the same scene always lands on
      // the same body — a nav that coin-flips is a nav nobody trusts.
      if (cost < conedCost - EPS || (Math.abs(cost - conedCost) <= EPS && coned && e.id < coned.id)) {
        coned = e;
        conedCost = cost;
      }
    }
    if (cost < openCost - EPS || (Math.abs(cost - openCost) <= EPS && open && e.id < open.id)) {
      open = e;
      openCost = cost;
    }
  }
  return coned || open;
}

// The entity nearest a point. This is what the FIRST arrow press lands on: the
// thing closest to the middle of the view, because that is where the eye
// already is.
export function nearestTo(entities, point = { x: 0, y: 0 }) {
  let best = null;
  let bestD = Infinity;
  for (const e of entities) {
    const d = (e.x - point.x) ** 2 + (e.y - point.y) ** 2;
    if (d < bestD - EPS || (Math.abs(d - bestD) <= EPS && best && e.id < best.id)) {
      best = e;
      bestD = d;
    }
  }
  return best;
}

// One press, resolved. Handed the entities visible right now, whatever was
// selected, and a direction, this is the whole movement rule:
//
//   nothing selected, or the selection has left the scene -> nearest to centre
//   something selected                                    -> spatially next
//   nothing that way                                      -> stay put
//
// Staying put is deliberate: wrapping around the map means a press that looks
// like it did nothing actually jumped you across the world.
export function moveSelection(entities, currentId, dir, center = { x: 0, y: 0 }) {
  if (!entities || !entities.length) return null;
  const cur = currentId ? byId(entities, currentId) : null;
  if (!cur) return nearestTo(entities, center);
  return nextInDirection(entities, currentId, dir) || cur;
}

// ---------------------------------------------------------------- the guard

const TYPING_TAGS = new Set(['INPUT', 'TEXTAREA', 'SELECT', 'OPTION']);

// Is this element somewhere a keystroke already means something? Typing "world"
// into a filter box must not walk the selection four steps west, and a key
// pressed inside an open modal belongs to the modal.
export function isTypingTarget(el) {
  if (!el) return false;
  if (TYPING_TAGS.has(String(el.tagName || '').toUpperCase())) return true;
  if (el.isContentEditable) return true;
  if (typeof el.closest === 'function') {
    if (el.closest('input, textarea, select, [contenteditable="true"], [role="textbox"], [role="dialog"], dialog')) return true;
  }
  return false;
}

// Whose keys are these? The world answers arrows when the page has not given
// focus to something else that wants them: nothing focused, the body, or
// anything inside the world's own box. Tab away to the nav or to a table and
// the arrows go back to scrolling the page, which is the behaviour every other
// screen in this console has.
export function focusAllowsWorldKeys(active, container) {
  if (!active) return true;
  if (active.tagName && String(active.tagName).toUpperCase() === 'BODY') return true;
  if (!container) return false;
  if (active === container) return true;
  return typeof container.contains === 'function' ? container.contains(active) : false;
}

// The one entry point the hook calls. Returns what to DO, never does it — which
// is what lets a test press every key in the alphabet at it without a browser.
export function worldKeyAction(event, { container = null, active = null, hasSelection = false } = {}) {
  if (!event) return null;
  if (event.isComposing) return null;
  if (isTypingTarget(event.target)) return null;
  if (!focusAllowsWorldKeys(active, container)) return null;

  const dir = keyToDirection(event.key, event);
  if (dir) return { action: 'move', dir };

  if (event.metaKey || event.ctrlKey || event.altKey) return null;
  if (event.key === 'Escape') return hasSelection ? { action: 'clear' } : null;
  // Enter and Space only fire when something IS selected. Otherwise Space is
  // still page-down, which is what a reader scrolling the lists below expects.
  if (event.key === 'Enter' || event.key === ' ' || event.key === 'Spacebar') {
    return hasSelection ? { action: 'open' } : null;
  }
  return null;
}

// ---------------------------------------------------------------- flat map

// The flat map's navigable entities, in scene units. Same three populations the
// SVG draws: project tiles, bodies standing on them, and boxes asleep at the
// station. A homeless body — one whose project has no tile — is not drawn, so
// it is not navigable either; the HANDS UP list below the scene is where it is
// still reachable.
export function hexTargets(scene) {
  const entities = [];
  if (!scene) return { entities, center: { x: 0, y: 0 } };

  for (const h of scene.hexes || []) {
    entities.push({
      id: `t:${h.project}`,
      kind: 'territory',
      x: h.x,
      y: h.y,
      label: h.project,
      to: h.to,
      title: tileTitle(h),
      live: h.live,
      needs: h.needs,
      raised: h.raised,
      paused: h.paused
    });
  }
  const body = (s) => ({
    id: s.id,
    kind: s.kind === 'box' ? 'box' : 'agent',
    x: s.x,
    y: s.y,
    label: s.label,
    to: s.to,
    state: s.state,
    tone: s.tone,
    raised: Boolean(s.raised)
  });
  for (const s of scene.sprites || []) if (!s.homeless) entities.push(body(s));
  for (const s of scene.station || []) entities.push(body(s));

  const b = sceneBounds(scene);
  return { entities, center: { x: b.x + b.w / 2, y: b.y + b.h / 2 } };
}

// The same one-line summary a tile carries in its tooltip, so the card that
// names a keyboard selection says exactly what a tap says.
export function tileTitle(h) {
  return [
    `${h.live} live claim${h.live === 1 ? '' : 's'}`,
    h.needs ? `${h.needs} waiting on a person` : null,
    h.queue ? `queue ${h.queue}` : null,
    h.paused ? 'PAUSED' : null
  ].filter(Boolean).join(' · ');
}

// Keep the selection on screen. The flat map starts zoomed IN on a phone, so
// walking three bodies to the left would otherwise walk them straight out of
// the viewBox — this nudges the camera by the smallest amount that puts the
// point back inside, and leaves it alone entirely when it already is.
export function ensureVisible(view, point, margin = HEX_SIZE * 0.6) {
  if (!view || !point) return view;
  // A margin that eats the whole viewport would make every point off-screen.
  const mx = Math.min(margin, view.w / 3);
  const my = Math.min(margin, view.h / 3);
  let x = view.x;
  let y = view.y;
  if (point.x < x + mx) x = point.x - mx;
  else if (point.x > x + view.w - mx) x = point.x - view.w + mx;
  if (point.y < y + my) y = point.y - my;
  else if (point.y > y + view.h - my) y = point.y - view.h + my;
  if (x === view.x && y === view.y) return view;
  return { ...view, x, y };
}
