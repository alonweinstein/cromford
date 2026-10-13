import test from 'node:test';
import assert from 'node:assert/strict';
import { bindingsView, editBody, confirmOpts, editOutcome, saveEdit } from '../src/lib/chat-bindings.js';
import { panelState } from '../src/lib/restore-lab.js';

// BH-2678 (BH-2521.3): the pure half of the /hub CHAT BINDINGS panel. The
// shapes are GET/PUT /api/telegram-topics in worker/jobs/src/routes/telegram-topics.js.

const ROW = { project: 'project-3', thread_id: 7, actor: 'console:a@x', updated_at: '2026-09-26T09:00:00Z' };

test('L1: a payload without a rows array is a broken answer, never an empty table', () => {
  for (const bad of [undefined, null, {}, { rows: null }, { rows: 'x' }, { topics: {} }]) {
    assert.throws(() => bindingsView(bad), /bad response/, JSON.stringify(bad));
  }
  const empty = bindingsView({ topics: {}, rows: [] });
  assert.deepEqual(empty, { rows: [] });
  assert.equal(panelState({ view: empty, error: null }), 'empty');
  assert.equal(panelState({ view: bindingsView({ rows: [ROW] }), error: null }), 'rows');
});

test('L2: editBody trims and accepts a positive integer, and refuses everything else', () => {
  assert.deepEqual(editBody('project-3', ' 12 '), { project: 'project-3', thread_id: 12 });
  assert.deepEqual(editBody('project-3', 9), { project: 'project-3', thread_id: 9 });
  for (const raw of ['0', '-3', '6.9', '12abc', '', ' ', '   ', '1e3', '0x10', '+5', '012', null, undefined, '99999999999999999999']) {
    assert.throws(() => editBody('project-3', raw), /thread id must be a positive integer/, JSON.stringify(raw));
  }
  for (const p of ['', null, undefined, 3]) assert.throws(() => editBody(p, '12'), /project/, JSON.stringify(p));
});

test('L3: editOutcome is ok only for a matching topic with an integer thread', () => {
  assert.deepEqual(editOutcome('project-3', { result: { topic: { project: 'project-3', thread_id: 12 } } }),
    { tone: 'ok', text: 'project-3 now posts to thread 12.' });
  assert.deepEqual(editOutcome('project-3', { error: new Error('HTTP 502') }),
    { tone: 'bad', text: 'Could not move project-3: HTTP 502' });
  for (const result of [null, {}, { ok: true }, { topic: { project: 'other', thread_id: 12 } },
    { topic: { project: 'project-3', thread_id: '12' } }, { topic: { project: 'project-3' } }]) {
    const out = editOutcome('project-3', { result });
    assert.equal(out.tone, 'bad', JSON.stringify(result));
    assert.equal(out.text, 'Could not move project-3: unexpected answer.');
  }
});

function fakeApi(answer) {
  const calls = [];
  return {
    calls,
    telegramTopicSet: async (...args) => {
      calls.push(args);
      if (answer instanceof Error) throw answer;
      return answer;
    },
  };
}

test('L4: saveEdit asks, sends one PUT, and reloads only on ok', async () => {
  const asked = [];
  const yes = async (o) => { asked.push(o); o.form.reason = 'why'; return true; };
  let reloads = 0;
  const reload = () => { reloads++; };

  for (const raw of ['0', '-3', '6.9', '12abc', '', '   ']) {
    const apiObj = fakeApi({ topic: { project: 'project-3', thread_id: 12 } });
    const out = await saveEdit({ apiObj, project: 'project-3', from: 7, raw, confirm: yes, reload });
    assert.deepEqual(out, { refused: 'thread id must be a positive integer' }, JSON.stringify(raw));
    assert.equal(apiObj.calls.length, 0);
  }
  assert.equal(asked.length, 0, 'an invalid id never opens the dialog');

  let apiObj = fakeApi({ topic: { project: 'project-3', thread_id: 7 } });
  assert.deepEqual(await saveEdit({ apiObj, project: 'project-3', from: 7, raw: ' 7 ', confirm: yes, reload }),
    { refused: 'already thread 7' });
  assert.equal(apiObj.calls.length, 0);
  assert.equal(asked.length, 0);

  apiObj = fakeApi({ topic: { project: 'project-3', thread_id: 12 } });
  assert.equal(await saveEdit({ apiObj, project: 'project-3', from: 7, raw: '12', confirm: async () => false, reload }), null);
  assert.equal(apiObj.calls.length, 0);
  assert.equal(reloads, 0);

  apiObj = fakeApi({ topic: { project: 'project-3', thread_id: 12 } });
  const ok = await saveEdit({ apiObj, project: 'project-3', from: 7, raw: '12', confirm: yes, reload });
  assert.deepEqual(ok, { outcome: { tone: 'ok', text: 'project-3 now posts to thread 12.' } });
  assert.deepEqual(apiObj.calls, [['project-3', 12, 'why']]);
  assert.equal(reloads, 1);
  assert.deepEqual(asked[0], { ...confirmOpts('project-3', 7, 12), confirmBlocked: true, form: { reason: 'why' } });
  assert.equal(asked[0].body, 'Move project-3 from thread 7 to 12?');
  assert.equal(asked[0].title, 'CHAT BINDINGS');

  apiObj = fakeApi(new Error('HTTP 500'));
  const failed = await saveEdit({ apiObj, project: 'project-3', from: 7, raw: '12', confirm: yes, reload });
  assert.deepEqual(failed, { outcome: { tone: 'bad', text: 'Could not move project-3: HTTP 500' } });
  assert.equal(apiObj.calls.length, 1);
  assert.equal(reloads, 1, 'a failed PUT does not reload');

  apiObj = fakeApi({ ok: true });
  const odd = await saveEdit({ apiObj, project: 'project-3', from: 7, raw: '12', confirm: yes, reload });
  assert.equal(odd.outcome.tone, 'bad');
  assert.equal(reloads, 1, 'an unexpected answer does not reload');
});
