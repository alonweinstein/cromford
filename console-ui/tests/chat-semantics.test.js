import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  ORCHESTRATOR, ALL_THREADS, buildTargets, cursorFor, advanceCursor, replyFailure,
  isFailedReply, pendingWaitLabel, normaliseTarget
} from '../src/lib/chat.js';

// ---------------------------------------------------------------- cursors

test('each target keeps its OWN cursor', () => {
  // `last_id` from a targeted GET describes that target only. Feeding it back
  // as a shared cursor makes the next tab's poll start too high and skip
  // everything below it — messages that silently never appear.
  let c = {};
  c = advanceCursor(c, 'project-1', { last_id: 40 });
  c = advanceCursor(c, ORCHESTRATOR, { last_id: 7 });
  assert.equal(cursorFor(c, 'project-1'), 40);
  assert.equal(cursorFor(c, ORCHESTRATOR), 7);
});

test('a high cursor on one target never raises another target', () => {
  let c = advanceCursor({}, 'project-1', { last_id: 900 });
  assert.equal(cursorFor(c, 'project-4'), 0, 'an untouched target still starts from the beginning');
});

test('an unseen target starts at 0 so its history loads once', () => {
  assert.equal(cursorFor({}, 'project-3'), 0);
  assert.equal(cursorFor(null, 'project-3'), 0);
});

test('a per-target cursor never goes backwards', () => {
  let c = advanceCursor({}, 'project-4', { last_id: 12 });
  c = advanceCursor(c, 'project-4', { last_id: 5 });
  assert.equal(cursorFor(c, 'project-4'), 12);
});

test('a payload with no last_id leaves the cursor alone', () => {
  let c = advanceCursor({}, 'project-4', { last_id: 12 });
  c = advanceCursor(c, 'project-4', {});
  assert.equal(cursorFor(c, 'project-4'), 12);
});

test('advancing a cursor does not mutate the map it was given', () => {
  const before = advanceCursor({}, 'a', { last_id: 3 });
  const after = advanceCursor(before, 'a', { last_id: 9 });
  assert.equal(cursorFor(before, 'a'), 3);
  assert.equal(cursorFor(after, 'a'), 9);
});

// ---------------------------------------------------------- hub is not a target

test('hub is NOT a chat target', () => {
  // `hub` is the fetch_log-only literal. Offering it here would queue a chat
  // command nothing answers, and the tab would just sit there forever.
  const keys = buildTargets(['project-1', 'hub', 'project-4']).map((t) => t.key);
  assert.equal(keys.includes('hub'), false);
  assert.deepEqual(keys, [ORCHESTRATOR, 'project-1', 'project-4']);
});

test('a fleet list that is only hub still leaves the orchestrator', () => {
  assert.deepEqual(buildTargets(['hub']).map((t) => t.key), [ORCHESTRATOR]);
});

// ------------------------------------------------------------ failed replies

test('a routing_failed reply is a failure, not an answer', () => {
  const m = { id: 5, command_id: '5', direction: 'reply', target: 'project-3', error: 'routing_failed', text: 'could not reach box' };
  assert.equal(isFailedReply(m), true);
  assert.equal(replyFailure(m).reason, 'routing_failed');
});

test('an older row carries the failure only as self-describing text', () => {
  // Rows written before the `error` column exists say so in the body; they
  // must not render as a normal answer bubble either.
  for (const text of [
    'routing failed: no box registered for project-3',
    'ROUTING FAILED',
    'could not route to the project-3 box'
  ]) {
    assert.equal(isFailedReply({ id: 1, direction: 'reply', text }), true, text);
  }
});

test('a normal answer that merely mentions failure is NOT a failure bubble', () => {
  // Over-matching is worse than under-matching here: painting a real answer as
  // an error would hide the answer the operator asked for.
  for (const text of [
    'the TK-212 build failed at the review stage',
    'routing is fine; the tick is late because disk is at 81%',
    'two runs failed overnight, both retried green'
  ]) {
    assert.equal(isFailedReply({ id: 1, direction: 'reply', text }), false, text);
  }
});

test('your own outgoing turn is never a failed reply', () => {
  assert.equal(isFailedReply({ id: 1, direction: 'out', text: 'routing failed' }), false);
});

test('an unknown error value still renders as a failure rather than an answer', () => {
  const m = { id: 5, direction: 'reply', error: 'box_unreachable', text: '' };
  assert.equal(isFailedReply(m), true);
  assert.equal(replyFailure(m).reason, 'box_unreachable');
});

test('a routing failure does not make a cold box count as warm', () => {
  // The box never actually answered, so the NEXT turn is still a first turn.
  const messages = [
    { id: 1, command_id: '1', direction: 'out', target: 'project-3', text: 'hi' },
    { id: 2, command_id: '1', direction: 'reply', target: 'project-3', error: 'routing_failed', text: 'no route' }
  ];
  const label = pendingWaitLabel({ messages, target: 'project-3', waitingMs: 1000 });
  assert.equal(label.patient, true);
  assert.match(label.text, /waking/i);
});

// ------------------------------------------- the all-threads cursor is separate

test('the all-threads cursor cannot be inherited by a real target', () => {
  // The untargeted read returns every thread under ONE global last_id. Keeping
  // it in the same map under a reserved key is what stops a per-target read
  // from ever starting at that global high-water mark and skipping messages.
  let c = advanceCursor({}, ALL_THREADS, { last_id: 900 });
  assert.equal(cursorFor(c, ALL_THREADS), 900);
  assert.equal(cursorFor(c, 'project-1'), 0);
  assert.equal(cursorFor(c, ORCHESTRATOR), 0);
});

test('the reserved key is not a name any project could take', () => {
  assert.equal(ALL_THREADS.startsWith('__'), true);
  assert.equal(/^[a-z0-9][a-z0-9._-]*$/i.test(ALL_THREADS), false,
    'a legal project name must not be able to collide with the reserved key');
  assert.equal(buildTargets([ALL_THREADS]).some((t) => t.key === ALL_THREADS && t.label !== 'HUB ORCHESTRATOR'), true,
    'and if one somehow arrived it would still be just another target, never the cursor bucket');
  assert.equal(normaliseTarget(ALL_THREADS), ALL_THREADS);
});
