import { test } from 'node:test';
import assert from 'node:assert/strict';
import { logOutcome, truncationNote } from '../src/lib/logstate.js';

test('no answer yet is pending, not empty', () => {
  assert.equal(logOutcome({ status: 'pending', command: { status: 'pending' } }).state, 'pending');
});

test('a file that was never written is NOT the same as an empty file', () => {
  // "this build produced no qa.md" and "qa.md exists and is empty" mean
  // completely different things to an operator; both arrive with content:"".
  const never = logOutcome({ status: 'ready', log: { content: '', missing: true, bytes: 0 } });
  const blank = logOutcome({ status: 'ready', log: { content: '', missing: false, bytes: 0 } });
  assert.equal(never.state, 'missing');
  assert.equal(blank.state, 'empty');
  assert.notEqual(never.title, blank.title);
});

test('a refused request is an operator error, not a retry', () => {
  // Retrying an unregistered project just queues another doomed command.
  const out = logOutcome({ status: 'ready', log: { error: 'refused', content: '' } });
  assert.equal(out.state, 'refused');
  assert.equal(out.retryable, false);
});

test('an unreachable box IS retryable', () => {
  const out = logOutcome({ status: 'ready', log: { error: 'fetch_failed', content: '' } });
  assert.equal(out.state, 'fetch_failed');
  assert.equal(out.retryable, true);
});

test('the error is read wherever the beat carried it', () => {
  assert.equal(logOutcome({ status: 'ready', error: 'refused' }).state, 'refused');
  assert.equal(logOutcome({ status: 'ready', command: { result: 'refused' } }).state, 'refused');
});

test('a dead-letter command stops polling and offers a retry', () => {
  const out = logOutcome({ status: 'dead_letter', command: { id: 4, status: 'dead_letter' } });
  assert.equal(out.state, 'dead_letter');
  assert.equal(out.retryable, true);
  assert.equal(out.commandId, 4);
});

test('content wins: a tail that arrived is shown even if a stale error tags along', () => {
  const out = logOutcome({ status: 'ready', log: { content: 'tick start\nrc=0', missing: false, bytes: 20 } });
  assert.equal(out.state, 'ready');
  assert.equal(out.content, 'tick start\nrc=0');
});

test('truncation is reported from what we STORED, not from what the beat claimed', () => {
  // The producer's flag only means "longer than MY cap"; if the console stored
  // less than it received the text is cut regardless of the flag.
  assert.equal(truncationNote({ truncated: false, bytes: 30012, stored_bytes: 16000 }),
    'showing 15.6KB of 29.3KB — cut');
  assert.equal(truncationNote({ truncated: true, bytes: 48000, stored_bytes: 48000 }),
    'showing 46.9KB of 46.9KB — cut');
  assert.equal(truncationNote({ truncated: false, bytes: 900, stored_bytes: 900 }), null);
});
