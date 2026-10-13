import { test } from 'node:test';
import assert from 'node:assert/strict';
import { compareValues, sortRows, nextDirection } from '../src/lib/sort.js';

test('numbers sort numerically, not lexically', () => {
  assert.equal(compareValues(9, 10), -1);
  assert.equal(compareValues(10, 9), 1);
  assert.equal(compareValues(3, 3), 0);
});

test('numeric strings from the API sort numerically', () => {
  // D1 hands back plenty of numbers as strings; "9" must not beat "10".
  assert.equal(compareValues('9', '10'), -1);
});

test('strings sort case-insensitively', () => {
  assert.equal(compareValues('alpha', 'Beta'), -1);
  assert.equal(compareValues('Zeta', 'alpha'), 1);
});

test('null and undefined sort last in BOTH directions', () => {
  // A row with no value is not "the smallest" — it is unknown, and flipping the
  // sort must not float unknowns to the top of the table.
  const rows = [{ v: 3 }, { v: null }, { v: 1 }, { v: undefined }];
  const asc = sortRows(rows, (r) => r.v, 'asc').map((r) => r.v);
  const desc = sortRows(rows, (r) => r.v, 'desc').map((r) => r.v);
  assert.deepEqual(asc.slice(0, 2), [1, 3]);
  assert.deepEqual(desc.slice(0, 2), [3, 1]);
  assert.equal(asc.slice(2).every((v) => v === null || v === undefined), true);
  assert.equal(desc.slice(2).every((v) => v === null || v === undefined), true);
});

test('empty string counts as missing, not as the smallest string', () => {
  const rows = [{ v: 'b' }, { v: '' }, { v: 'a' }];
  assert.deepEqual(sortRows(rows, (r) => r.v, 'asc').map((r) => r.v), ['a', 'b', '']);
});

test('sortRows does not mutate its input', () => {
  const rows = [{ v: 2 }, { v: 1 }];
  const out = sortRows(rows, (r) => r.v, 'asc');
  assert.deepEqual(rows.map((r) => r.v), [2, 1]);
  assert.deepEqual(out.map((r) => r.v), [1, 2]);
});

test('sort is stable for equal keys', () => {
  const rows = [{ v: 1, id: 'a' }, { v: 1, id: 'b' }, { v: 1, id: 'c' }];
  assert.deepEqual(sortRows(rows, (r) => r.v, 'desc').map((r) => r.id), ['a', 'b', 'c']);
});

test('descending is the exact reverse of ascending ordering', () => {
  const rows = [{ v: 2 }, { v: 3 }, { v: 1 }];
  assert.deepEqual(sortRows(rows, (r) => r.v, 'desc').map((r) => r.v), [3, 2, 1]);
});

test('clicking a header cycles asc -> desc -> asc', () => {
  assert.equal(nextDirection('project', 'project', 'asc'), 'desc');
  assert.equal(nextDirection('project', 'project', 'desc'), 'asc');
});

test('clicking a different header starts at ascending', () => {
  assert.equal(nextDirection('queue', 'project', 'desc'), 'asc');
});
