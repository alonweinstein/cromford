import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

// BH-3554 (BH-3562): a mounted suite that settles on a fixed wall-clock wait
// races preact's 35 ms effect timer on a loaded box. Every mounted suite
// settles through ./helpers/settle.js instead; this lint keeps it that way.

const DIR = fileURLToPath(new URL('./', import.meta.url));
const SELF = fileURLToPath(import.meta.url).slice(DIR.length);
// This file names the patterns it hunts for, so it is left out of its own scan.
const suites = readdirSync(DIR)
  .filter((f) => f.endsWith('.test.js') && f !== SELF)
  .sort()
  .map((f) => ({ name: f, src: readFileSync(DIR + f, 'utf8') }));

const WALL_CLOCK = /const[ ]flush = \([^)]*\) => new Promise\(\(r\) => setTimeout\(r, /;
const mounted = suites.filter((s) => s.src.includes('class FakeNode') && s.src.includes('await flush('));

test('no suite defines flush as a wall-clock wait', () => {
  const offenders = suites.filter((s) => WALL_CLOCK.test(s.src)).map((s) => s.name);
  assert.deepEqual(offenders, [], 'wall-clock flush in: ' + offenders.join(', '));
});

test('every FakeNode mount that awaits flush imports ./helpers/settle.js', () => {
  const offenders = mounted.filter((s) => !s.src.includes("from './helpers/settle.js'")).map((s) => s.name);
  assert.deepEqual(offenders, [], 'mounted suite not on the settle helper: ' + offenders.join(', '));
});

test('the mounted-suite predicate still finds the mounted suites', () => {
  assert.ok(mounted.length >= 23, `expected at least 23 mounted suites, found ${mounted.length}`);
});
