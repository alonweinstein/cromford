import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mergeMessages, pendingCommandIds, nextSince, optimisticTurn } from '../src/lib/chat.js';

const out1 = { id: 1, command_id: '1', direction: 'out', origin: 'dash', text: 'what is the fleet doing' };
const reply1 = { id: 2, command_id: '1', direction: 'reply', origin: 'dash', text: 'triage green' };

test('an overlapping poll does not duplicate turns already on screen', () => {
  // Polls overlap by design (`since=last_id` is inclusive of nothing, but a
  // retry after a dropped response replays). Appending blind doubles the thread.
  const merged = mergeMessages([out1, reply1], [reply1]);
  assert.equal(merged.length, 2);
});

test('the optimistic turn is REPLACED by the server row for the same command_id', () => {
  // POST /chat returns a command_id; we paint the turn immediately. When the
  // poll returns the real row, keying on `id` alone would leave both on screen.
  const optimistic = optimisticTurn('7', 'force triage on project-3');
  assert.equal(optimistic.pending, true);
  const server = { id: 9, command_id: '7', direction: 'out', origin: 'dash', text: 'force triage on project-3' };
  const merged = mergeMessages([optimistic], [server]);
  assert.equal(merged.length, 1);
  assert.equal(merged[0].id, 9);
  assert.equal(merged[0].pending, undefined, 'the server row wins over the optimistic one');
});

test('an out and a reply sharing one command_id are two distinct turns', () => {
  // The dedup key is (command_id, direction) — collapsing on command_id alone
  // would eat every answer the orchestrator sends.
  const merged = mergeMessages([], [out1, reply1]);
  assert.equal(merged.length, 2);
  assert.deepEqual(merged.map((m) => m.direction), ['out', 'reply']);
});

test('command_id is compared as a string — the API sends both shapes', () => {
  const numeric = { id: 3, command_id: 1, direction: 'reply', text: 'same turn' };
  const merged = mergeMessages([out1, reply1], [numeric]);
  assert.equal(merged.length, 2, '1 and "1" are the same command');
});

test('the thread stays in id order however the polls interleave', () => {
  const merged = mergeMessages([reply1], [out1]);
  assert.deepEqual(merged.map((m) => m.id), [1, 2]);
});

test('a still-unanswered turn sorts last so the spinner sits at the bottom', () => {
  const optimistic = optimisticTurn('8', 'and project-4?');
  const merged = mergeMessages([out1, reply1], [optimistic]);
  assert.equal(merged[merged.length - 1].command_id, '8');
});

test('pending turns are the outs with no reply yet', () => {
  assert.deepEqual(pendingCommandIds([out1]), ['1']);
  assert.deepEqual(pendingCommandIds([out1, reply1]), []);
});

test('the next poll cursor never goes backwards', () => {
  // A `since` that regresses replays the whole thread on every tick.
  assert.equal(nextSince(5, { last_id: 9 }), 9);
  assert.equal(nextSince(9, { last_id: 5 }), 9);
  assert.equal(nextSince(9, {}), 9);
  assert.equal(nextSince(0, { last_id: 0 }), 0);
});

test('optimistic turns are never counted into the poll cursor', () => {
  // They have no server id; letting one set `since` would skip real rows.
  const merged = mergeMessages([], [optimisticTurn('7', 'hi')]);
  assert.equal(nextSince(0, { last_id: 0 }), 0);
  assert.equal(merged[0].id, null);
});
