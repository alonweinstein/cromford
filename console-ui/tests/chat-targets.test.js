import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  ORCHESTRATOR, normaliseTarget, messageTarget, filterByTarget, buildTargets,
  unreadByTarget, markSeen, pendingWaitLabel, mergeMessages, optimisticTurn
} from '../src/lib/chat.js';

const msg = (id, target, direction = 'reply') =>
  ({ id, command_id: String(id), direction, text: `m${id}`, ...(target === undefined ? {} : { target }) });

test('a message with no target is the orchestrator', () => {
  // The deployed worker does not send `target` yet. Treating that as "unknown"
  // would empty the default thread the moment this ships.
  assert.equal(messageTarget({ id: 1, direction: 'out', text: 'hi' }), ORCHESTRATOR);
  assert.equal(messageTarget({ id: 1, target: null }), ORCHESTRATOR);
  assert.equal(messageTarget({ id: 1, target: '' }), ORCHESTRATOR);
  assert.equal(normaliseTarget(undefined), ORCHESTRATOR);
  assert.equal(normaliseTarget('project-1'), 'project-1');
});

test('a pre-target thread renders in full under HUB ORCHESTRATOR', () => {
  const legacy = [msg(1, undefined, 'out'), msg(2, undefined)];
  assert.equal(filterByTarget(legacy, ORCHESTRATOR).length, 2);
  assert.equal(filterByTarget(legacy, 'project-1').length, 0);
});

test('each target sees only its own turns', () => {
  const all = [msg(1, ORCHESTRATOR, 'out'), msg(2, 'project-1', 'out'), msg(3, 'project-1'), msg(4, ORCHESTRATOR)];
  assert.deepEqual(filterByTarget(all, 'project-1').map((m) => m.id), [2, 3]);
  assert.deepEqual(filterByTarget(all, ORCHESTRATOR).map((m) => m.id), [1, 4]);
});

test('the target list is the orchestrator first, then the fleet projects', () => {
  const t = buildTargets(['project-1', 'project-4']);
  assert.deepEqual(t.map((x) => x.key), [ORCHESTRATOR, 'project-1', 'project-4']);
  assert.equal(t[0].label, 'HUB ORCHESTRATOR');
  assert.equal(t[1].label, 'project-1');
});

test('the orchestrator is offered even before the fleet list loads', () => {
  assert.deepEqual(buildTargets([]).map((x) => x.key), [ORCHESTRATOR]);
  assert.deepEqual(buildTargets(null).map((x) => x.key), [ORCHESTRATOR]);
});

test('a target you have never opened does not shout about its whole history', () => {
  // Every box would light up on first load otherwise, which trains you to
  // ignore the dot — the one thing an unread marker must not do.
  const all = [msg(2, 'project-1'), msg(3, 'project-1')];
  const seen = markSeen({}, 'project-1', all);
  assert.equal(unreadByTarget(all, seen)['project-1'], 0);
});

test('a reply landing after you looked away is unread', () => {
  let all = [msg(2, 'project-1')];
  const seen = markSeen({}, 'project-1', all);
  all = [...all, msg(5, 'project-1')];
  assert.equal(unreadByTarget(all, seen)['project-1'], 1);
});

test('your own turns never count as unread', () => {
  const all = [msg(7, 'project-4', 'out')];
  assert.equal(unreadByTarget(all, {})['project-4'], 0);
});

test('unread is counted per target, not globally', () => {
  const all = [msg(2, 'project-1'), msg(3, 'project-4'), msg(4, 'project-4')];
  const u = unreadByTarget(all, {});
  assert.equal(u['project-1'], 1);
  assert.equal(u['project-4'], 2);
});

test('a first turn to a box says it is WAKING, not that it is late', () => {
  // A cold box session takes a while on the first turn. "no response" or a
  // timeout would read as broken when it is merely starting up.
  const label = pendingWaitLabel({ messages: [], target: 'project-1', waitingMs: 2000 });
  assert.match(label.text, /waking the project-1 box/i);
  assert.equal(label.patient, true);
});

test('a box that has already answered once is warm, so the wait reads normally', () => {
  const messages = [msg(1, 'project-1', 'out'), msg(2, 'project-1')];
  const label = pendingWaitLabel({ messages, target: 'project-1', waitingMs: 2000 });
  assert.equal(label.patient, false);
  assert.doesNotMatch(label.text, /waking/i);
});

test('the orchestrator is never described as waking — it is always up or it is not', () => {
  const label = pendingWaitLabel({ messages: [], target: ORCHESTRATOR, waitingMs: 2000 });
  assert.equal(label.patient, false);
  assert.doesNotMatch(label.text, /waking/i);
});

test('a long cold wait keeps reassuring instead of declaring failure', () => {
  const label = pendingWaitLabel({ messages: [], target: 'project-3', waitingMs: 90000 });
  assert.equal(label.patient, true);
  assert.match(label.text, /still waking|waking/i);
  assert.doesNotMatch(label.text, /failed|timed out|error/i);
});

test('an optimistic turn carries the target it was sent to', () => {
  const t = optimisticTurn('9', 'force triage', 'project-3');
  assert.equal(t.target, 'project-3');
  assert.equal(t.pending, true);
  assert.equal(filterByTarget([t], 'project-3').length, 1);
  assert.equal(filterByTarget([t], ORCHESTRATOR).length, 0);
});

test('an optimistic turn with no target given still defaults to the orchestrator', () => {
  assert.equal(optimisticTurn('9', 'hi').target, ORCHESTRATOR);
});

test('the server row replaces the optimistic turn even across the target fields', () => {
  const optimistic = optimisticTurn('7', 'status?', 'project-4');
  const server = { id: 9, command_id: '7', direction: 'out', text: 'status?', target: 'project-4' };
  const merged = mergeMessages([optimistic], [server]);
  assert.equal(merged.length, 1);
  assert.equal(merged[0].id, 9);
});

test('two targets sharing a command_id stay two turns, not one', () => {
  // If the console ever hands the same id to two targets, collapsing them
  // would make one thread's turn silently vanish from the screen.
  const a = { id: null, command_id: '99', direction: 'out', target: 'project-3', text: 'why overdue?' };
  const b = { id: null, command_id: '99', direction: 'out', target: ORCHESTRATOR, text: 'fleet status' };
  const merged = mergeMessages([a], [b]);
  assert.equal(merged.length, 2);
  assert.equal(filterByTarget(merged, 'project-3').length, 1);
  assert.equal(filterByTarget(merged, ORCHESTRATOR).length, 1);
});

test('a legacy row still replaces its optimistic orchestrator turn', () => {
  // The server may omit `target` entirely; it must still normalise onto the
  // same key as the optimistic turn or the turn would double on screen.
  const optimistic = optimisticTurn('4', 'hello');
  const server = { id: 12, command_id: '4', direction: 'out', text: 'hello' };
  const merged = mergeMessages([optimistic], [server]);
  assert.equal(merged.length, 1);
  assert.equal(merged[0].id, 12);
});
