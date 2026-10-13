// SPDX-License-Identifier: Apache-2.0
// BH-5558: decide / nextLevel.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { LEVELS, decide, nextLevel } from '../src/index.js';

const NEVER = ['a direct merge (`gh pr merge`)', 'a push to main', 'a production DB write'];

test('A1: an action on the NEVER list is refused at every level', () => {
  assert.deepEqual(LEVELS, ['automation', 'augmentation', 'autonomy']);
  for (const level of LEVELS) {
    assert.equal(decide(level, 'autonomy', { name: 'a push to main', never: NEVER }), 'refuse', level);
    assert.equal(decide(level, 'autonomy', { name: 'A Push To Main.', never: NEVER }), 'refuse', level);
    assert.equal(decide(level, 'autonomy', { name: 'a direct merge (gh pr merge)', never: NEVER }), 'refuse', level);
    assert.equal(decide(level, 'autonomy', { name: '  a   production db WRITE ', never: NEVER }), 'refuse', level);
  }
});

test('A2: a request above the class cap is refused', () => {
  assert.equal(decide('autonomy', 'augmentation', { name: 'comment on a ticket', never: NEVER }), 'refuse');
  assert.equal(decide('augmentation', 'automation', { name: 'comment on a ticket', never: NEVER }), 'refuse');
  assert.equal(decide('autonomy', 'autonomy', { name: 'comment on a ticket', never: NEVER }), 'allow');
  assert.equal(decide('augmentation', 'autonomy', { name: 'comment on a ticket', never: NEVER }), 'ask');
});

test('A3: augmentation asks, autonomy allows, automation observes only', () => {
  assert.equal(decide('augmentation', 'augmentation', { name: 'comment on a ticket', never: NEVER }), 'ask');
  assert.equal(decide('autonomy', 'autonomy', { name: 'comment on a ticket', never: NEVER }), 'allow');
  assert.equal(decide('automation', 'automation', { name: 'comment on a ticket', never: NEVER }), 'refuse');
  // only an exact (normalized) NEVER entry refuses, not a substring
  assert.equal(decide('augmentation', 'augmentation', { name: 'comment on a push to main', never: NEVER }), 'ask');
  assert.equal(decide('augmentation', 'augmentation', { name: 'merge', never: NEVER }), 'ask');
});

test('A4: bad input fails closed', () => {
  const ok = { name: 'comment on a ticket', never: NEVER };
  for (const bad of ['admin', 'Autonomy ', '', null, undefined]) {
    assert.equal(decide(bad, 'autonomy', ok), 'refuse', `level ${bad}`);
    assert.equal(decide('autonomy', bad, ok), 'refuse', `cap ${bad}`);
  }
  assert.equal(decide('autonomy', 'autonomy', { name: 'comment on a ticket' }), 'refuse');
  assert.equal(decide('autonomy', 'autonomy', { name: '', never: [] }), 'refuse');
  assert.equal(decide('autonomy', 'autonomy', { name: 7, never: [] }), 'refuse');
  assert.equal(decide('autonomy', 'autonomy', undefined), 'refuse');
  assert.equal(decide('autonomy', 'autonomy', null), 'refuse');
});

const A = { verdict: 'agree' }, O = { verdict: 'overrule' }, D = { verdict: 'delegate' };

test('A5: promotion needs N agreements in a row and then a delegate, never above the cap', () => {
  assert.equal(nextLevel('automation', [A, A, A, D], { agreementsToPromote: 3, cap: 'augmentation' }), 'augmentation');
  assert.equal(nextLevel('augmentation', [A, A, A, D], { agreementsToPromote: 3, cap: 'autonomy' }), 'autonomy');
  assert.equal(nextLevel('automation', [A, A, A, D], { agreementsToPromote: 3, cap: 'automation' }), 'automation');
  assert.equal(nextLevel('augmentation', [A, A, A, D], { agreementsToPromote: 3, cap: 'augmentation' }), 'augmentation');
  assert.equal(nextLevel('automation', [A, O, A, D], { agreementsToPromote: 3, cap: 'autonomy' }), 'automation');
  assert.equal(nextLevel('automation', [A, A, D], { agreementsToPromote: 3, cap: 'autonomy' }), 'automation');
  // agreements alone never promote: a human must say delegate
  assert.equal(nextLevel('automation', [A, A, A, A], { agreementsToPromote: 3, cap: 'autonomy' }), 'automation');
  // bad input never promotes
  assert.equal(nextLevel('automation', [A, A, A, D], { agreementsToPromote: 0, cap: 'autonomy' }), 'automation');
  assert.equal(nextLevel('automation', [A, A, A, D], { agreementsToPromote: 3, cap: 'boss' }), 'automation');
  assert.equal(nextLevel('automation', [A, A, A, D], undefined), 'automation');
  assert.equal(nextLevel('automation', 'nope', { agreementsToPromote: 3, cap: 'autonomy' }), 'automation');
  assert.equal(nextLevel('admin', [A, A, A, D], { agreementsToPromote: 3, cap: 'autonomy' }), 'admin');
});

test('A6: an overrule demotes one level, floor automation', () => {
  const rule = { agreementsToPromote: 3, cap: 'autonomy' };
  assert.equal(nextLevel('augmentation', [A, A, A, O], rule), 'automation');
  assert.equal(nextLevel('autonomy', [A, O], rule), 'augmentation');
  assert.equal(nextLevel('automation', [O], rule), 'automation');
  assert.equal(nextLevel('autonomy', [], rule), 'autonomy');
  // a bad rule blocks promotion, never demotion: an overrule always demotes
  assert.equal(nextLevel('autonomy', [A, O], undefined), 'augmentation');
  assert.equal(nextLevel('augmentation', [O], { agreementsToPromote: 0, cap: 'boss' }), 'automation');
});
