import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { Modal } from '../src/ui/Modal.js';
import { PauseForm, pauseFormState } from '../src/screens/Project.js';

// BH-1685 lead fix. The jobs worker 400s a pause with a blank reason (#1874,
// PUT /api/pauses "reason required"), and the Project PAUSE form opened with
// the reason empty and PAUSE live, so a plain click sent exactly that. The
// form now holds PAUSE disabled until the command it would send is valid, and
// says why inline. preact-render-to-string runs no effects or handlers, so the
// typing half is pauseFormState — the one function the form's onInput and its
// render both call — and these cases render the real components around it.

const noop = () => {};
const confirmButton = (out) => {
  const m = out.match(/<button[^>]*>PAUSE<\/button>/);
  assert.ok(m, `no PAUSE button in ${out}`);
  return m[0];
};

test('a blank form blocks PAUSE and says a reason is required', () => {
  const s = pauseFormState('project-3', { what: 'triage', reason: '', ttlS: '' });
  assert.equal(s.blocked, true);
  assert.match(s.hint, /reason/i);
  for (const reason of ['   ', '\t']) {
    assert.equal(pauseFormState('project-3', { what: 'merges', reason, ttlS: '' }).blocked, true, `reason=${JSON.stringify(reason)}`);
  }
});

test('a typed reason unblocks PAUSE and clears the hint', () => {
  const s = pauseFormState('project-3', { what: 'triage', reason: 'deploy', ttlS: '' });
  assert.deepEqual({ blocked: s.blocked, hint: s.hint }, { blocked: false, hint: null });
});

test('a bad ttl blocks PAUSE too, with its own message', () => {
  const s = pauseFormState('project-3', { what: 'merges', reason: 'x', ttlS: '1.5' });
  assert.equal(s.blocked, true);
  assert.match(s.hint, /ttl/);
});

test('the form renders the inline hint while the reason is blank, and not once it is typed', () => {
  const blank = render(h(PauseForm, { project: 'project-3', value: { what: 'triage', reason: '', ttlS: '' }, onBlocked: noop }));
  assert.match(blank, /knob__note--bad/);
  assert.match(blank, /A reason is required/);
  const typed = render(h(PauseForm, { project: 'project-3', value: { what: 'triage', reason: 'deploy', ttlS: '' }, onBlocked: noop }));
  assert.doesNotMatch(typed, /knob__note--bad/);
});

test('a Modal whose form starts blocked renders its confirm button disabled', () => {
  const out = render(h(Modal, {
    title: 'PAUSE', confirmLabel: 'PAUSE', tone: 'warn', confirmBlocked: true,
    body: ({ setBlocked }) => h(PauseForm, { project: 'project-3', value: { what: 'triage', reason: '', ttlS: '' }, onBlocked: setBlocked }),
    onConfirm: noop, onCancel: noop
  }));
  assert.match(confirmButton(out), /disabled/);
  assert.match(out, /A reason is required/);
});

test('every other dialog is unchanged: a plain body leaves confirm enabled', () => {
  const out = render(h(Modal, { title: 'X', confirmLabel: 'PAUSE', body: 'sure?', onConfirm: noop, onCancel: noop }));
  assert.doesNotMatch(confirmButton(out), /disabled/);
});
