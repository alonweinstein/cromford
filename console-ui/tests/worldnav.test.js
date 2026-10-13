// What the arrow keys mean, asserted without a browser.
//
// The two things worth a test here are the two things that are easy to get
// subtly wrong and impossible to eyeball: that "left" picks the nearest body to
// the LEFT rather than the previous item in a list, and that typing the letter
// "s" into a filter box does not walk the selection south. Everything the
// renderers do on top of this is drawing.

import test from 'node:test';
import assert from 'node:assert/strict';
import {
  DIRS, keyToDirection, nextInDirection, nearestTo, moveSelection,
  isTypingTarget, focusAllowsWorldKeys, worldKeyAction, hexTargets, ensureVisible
} from '../src/lib/worldnav.js';
import { buildScene } from '../src/lib/world.js';

// A small grid, laid out the way the screen is: y grows downward.
//
//        nw   n   ne
//        w    c    e
//        sw   s   se
const GRID = [
  { id: 'nw', x: -100, y: -100 }, { id: 'n', x: 0, y: -100 }, { id: 'ne', x: 100, y: -100 },
  { id: 'w', x: -100, y: 0 }, { id: 'c', x: 0, y: 0 }, { id: 'e', x: 100, y: 0 },
  { id: 'sw', x: -100, y: 100 }, { id: 's', x: 0, y: 100 }, { id: 'se', x: 100, y: 100 }
];

const step = (from, dir) => {
  const n = nextInDirection(GRID, from, dir);
  return n && n.id;
};

test('a direction picks the neighbour that way, not the next item in the list', () => {
  assert.equal(step('c', 'left'), 'w');
  assert.equal(step('c', 'right'), 'e');
  assert.equal(step('c', 'up'), 'n');
  assert.equal(step('c', 'down'), 's');
});

test('up is toward the top of the screen, in screen coordinates', () => {
  assert.deepEqual(DIRS.up, [0, -1]);
  assert.equal(step('s', 'up'), 'c');
  assert.equal(step('n', 'down'), 'c');
});

test('movement walks a row one step at a time rather than jumping the far side', () => {
  assert.equal(step('w', 'right'), 'c');
  assert.equal(step('c', 'right'), 'e');
  assert.equal(step('e', 'right'), null, 'nothing further right exists');
});

test('a body straight ahead beats a nearer one off to the side', () => {
  const ents = [
    { id: 'cur', x: 0, y: 0 },
    { id: 'ahead', x: 120, y: 0 },
    { id: 'aside', x: 40, y: 90 }
  ];
  assert.equal(nextInDirection(ents, 'cur', 'right').id, 'ahead');
});

test('a lonely body off the diagonal is still reachable, not stranded', () => {
  // Nothing is inside the cone to the right, but something IS to the right.
  const ents = [
    { id: 'cur', x: 0, y: 0 },
    { id: 'far-corner', x: 30, y: -400 }
  ];
  assert.equal(nextInDirection(ents, 'cur', 'right').id, 'far-corner');
  assert.equal(nextInDirection(ents, 'cur', 'left'), null);
});

test('two candidates at the same cost resolve the same way every time', () => {
  const ents = [
    { id: 'cur', x: 0, y: 0 },
    { id: 'bbb', x: 50, y: 20 },
    { id: 'aaa', x: 50, y: -20 }
  ];
  const first = nextInDirection(ents, 'cur', 'right').id;
  for (let i = 0; i < 5; i++) assert.equal(nextInDirection(ents, 'cur', 'right').id, first);
  assert.equal(first, 'aaa', 'the tie breaks on id, so the scene never coin-flips');
});

test('the first press with nothing selected lands nearest the middle', () => {
  assert.equal(nearestTo(GRID, { x: 0, y: 0 }).id, 'c');
  assert.equal(nearestTo(GRID, { x: 200, y: 200 }).id, 'se');
  assert.equal(moveSelection(GRID, null, 'left', { x: 0, y: 0 }).id, 'c');
  assert.equal(moveSelection(GRID, 'gone-from-the-scene', 'up', { x: -90, y: -90 }).id, 'nw');
});

test('a press with nothing that way holds still instead of wrapping around', () => {
  assert.equal(moveSelection(GRID, 'e', 'right').id, 'e');
  assert.equal(moveSelection([], null, 'right'), null);
});

// ---------------------------------------------------------------- keys

test('arrows and WASD are the same four directions', () => {
  assert.equal(keyToDirection('ArrowLeft'), 'left');
  assert.equal(keyToDirection('a'), 'left');
  assert.equal(keyToDirection('A'), 'left');
  assert.equal(keyToDirection('ArrowRight'), 'right');
  assert.equal(keyToDirection('d'), 'right');
  assert.equal(keyToDirection('ArrowUp'), 'up');
  assert.equal(keyToDirection('w'), 'up');
  assert.equal(keyToDirection('ArrowDown'), 'down');
  assert.equal(keyToDirection('s'), 'down');
  assert.equal(keyToDirection('q'), null);
  assert.equal(keyToDirection('Tab'), null);
});

test('a modified chord belongs to the browser, not to the world', () => {
  assert.equal(keyToDirection('ArrowLeft', { metaKey: true }), null, 'cmd+left is Back');
  assert.equal(keyToDirection('ArrowLeft', { ctrlKey: true }), null);
  assert.equal(keyToDirection('ArrowLeft', { altKey: true }), null);
  assert.equal(keyToDirection('w', { shiftKey: true }), null, 'shift+W is a capital W');
  assert.equal(keyToDirection('ArrowUp', { shiftKey: true }), 'up');
});

// ---------------------------------------------------------------- the guard

const el = (tagName, extra = {}) => ({
  tagName,
  isContentEditable: false,
  closest: () => null,
  contains: () => false,
  ...extra
});

const BODY = el('BODY');

test('typing in an input never moves the selection', () => {
  const input = el('INPUT');
  for (const key of ['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown', 'w', 'a', 's', 'd', 'Enter', ' ', 'Escape']) {
    assert.equal(
      worldKeyAction({ key, target: input }, { active: input, hasSelection: true }),
      null,
      `"${key}" typed into an input must do nothing to the world`
    );
  }
});

test('the same is true of a textarea, a select, a contenteditable and an open modal', () => {
  assert.equal(isTypingTarget(el('TEXTAREA')), true);
  assert.equal(isTypingTarget(el('SELECT')), true);
  assert.equal(isTypingTarget(el('DIV', { isContentEditable: true })), true);
  const inModal = el('BUTTON', { closest: (sel) => (sel.includes('[role="dialog"]') ? {} : null) });
  assert.equal(isTypingTarget(inModal), true);
  assert.equal(isTypingTarget(el('DIV')), false);
  assert.equal(isTypingTarget(null), false);
});

test('the world answers arrows only when nothing else has the focus', () => {
  const container = el('DIV', { contains: (n) => n && n.id === 'inside' });
  const inside = el('A', { id: 'inside' });
  const elsewhere = el('A', { id: 'outside' });
  assert.equal(focusAllowsWorldKeys(null, container), true, 'nothing focused');
  assert.equal(focusAllowsWorldKeys(BODY, container), true, 'the page itself');
  assert.equal(focusAllowsWorldKeys(container, container), true, 'the world box');
  assert.equal(focusAllowsWorldKeys(inside, container), true, 'a link inside the scene');
  assert.equal(focusAllowsWorldKeys(elsewhere, container), false, 'a link in the nav keeps its keys');
});

test('a key pressed with focus outside the world is left entirely alone', () => {
  const container = el('DIV', { contains: () => false });
  const elsewhere = el('A');
  assert.equal(worldKeyAction({ key: 'ArrowDown', target: elsewhere }, { container, active: elsewhere }), null);
});

test('the actions a press can resolve to', () => {
  const base = { container: null, active: BODY };
  assert.deepEqual(worldKeyAction({ key: 'ArrowUp', target: BODY }, base), { action: 'move', dir: 'up' });
  assert.deepEqual(worldKeyAction({ key: 'd', target: BODY }, base), { action: 'move', dir: 'right' });
  assert.deepEqual(
    worldKeyAction({ key: 'Enter', target: BODY }, { ...base, hasSelection: true }),
    { action: 'open' }
  );
  assert.deepEqual(
    worldKeyAction({ key: ' ', target: BODY }, { ...base, hasSelection: true }),
    { action: 'open' }
  );
  assert.deepEqual(
    worldKeyAction({ key: 'Escape', target: BODY }, { ...base, hasSelection: true }),
    { action: 'clear' }
  );
});

test('Enter, Space and Escape stay the page\'s own with nothing selected', () => {
  const base = { container: null, active: BODY, hasSelection: false };
  assert.equal(worldKeyAction({ key: ' ', target: BODY }, base), null, 'Space is still page-down');
  assert.equal(worldKeyAction({ key: 'Enter', target: BODY }, base), null);
  assert.equal(worldKeyAction({ key: 'Escape', target: BODY }, base), null);
});

test('a keystroke mid-IME-composition is not a command', () => {
  assert.equal(
    worldKeyAction({ key: 'ArrowDown', target: BODY, isComposing: true }, { active: BODY }),
    null
  );
});

// ---------------------------------------------------------------- flat map

const now = Math.floor(Date.now() / 1000);  // determinism: ok every started_at below is an offset from this one read
const SCENE = buildScene({
  jobs: {
    jobs: [
      { id: 'j1', project: 'project-3', box: 'project-3-2', stage: 'execute', status: 'running', heartbeating: 1, activity_age_s: 30, started_at: now - 100 },
      { id: 'j2', project: 'project-1', box: 'project-1-1', stage: 'plan', status: 'parked', heartbeating: 0, activity_age_s: 4000, started_at: now - 9000 }
    ]
  },
  machines: { boxes: { 'project-4-1': '2 min ago' } },
  projects: { projects: [{ project: 'project-3' }, { project: 'project-1' }, { project: 'project-4' }] }
});

test('every drawn thing on the flat map is navigable, and nothing else is', () => {
  const { entities } = hexTargets(SCENE);
  const ids = entities.map((e) => e.id).sort();
  assert.deepEqual(ids, ['box:project-4-1', 'job:j1', 'job:j2', 't:project-4', 't:project-1', 't:project-3'].sort());
  for (const e of entities) {
    assert.equal(typeof e.x, 'number');
    assert.equal(typeof e.y, 'number');
    assert.ok(e.to, `${e.id} carries the link a click would follow`);
    assert.ok(e.label, `${e.id} carries the label the card shows`);
  }
});

test('a homeless body is not on the map, so it is not in the keyboard walk', () => {
  const scene = { hexes: [], sprites: [{ id: 'job:x', homeless: true, x: null, y: null }], station: [] };
  assert.deepEqual(hexTargets(scene).entities, []);
});

test('the flat map hands back the middle of the scene for the first press', () => {
  const { entities, center } = hexTargets(SCENE);
  const first = moveSelection(entities, null, 'right', center);
  assert.ok(first, 'the first press selects something');
  assert.ok(entities.some((e) => e.id === first.id));
});

test('the camera only moves when the selection would be off screen', () => {
  const view = { x: 0, y: 0, w: 400, h: 300 };
  assert.equal(ensureVisible(view, { x: 200, y: 150 }, 40), view, 'dead centre: untouched');
  const panned = ensureVisible(view, { x: -50, y: 150 }, 40);
  assert.equal(panned.x, -90);
  assert.equal(panned.y, 0, 'only the axis that needed it moves');
  assert.equal(panned.w, 400);
  const down = ensureVisible(view, { x: 200, y: 500 }, 40);
  assert.equal(down.y, 500 - 300 + 40);
});

test('a margin bigger than the viewport cannot make every point off screen', () => {
  const view = { x: 0, y: 0, w: 90, h: 90 };
  assert.equal(ensureVisible(view, { x: 45, y: 45 }, 400), view);
});
