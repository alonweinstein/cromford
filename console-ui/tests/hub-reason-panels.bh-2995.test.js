import test from 'node:test';
import assert from 'node:assert/strict';
import { planView, submitApply, requestApply, confirmCopy } from '../src/lib/registry-seed.js';
import { saveEdit } from '../src/lib/chat-bindings.js';

// BH-2995 (BH-2992.1): the SEED REGISTRY apply and the CHAT BINDINGS move take
// a required reason from the confirm dialog. A blank reason sends nothing; a
// filled one is trimmed and sent.

const FP = 'ab'.repeat(32);
const PLAN = planView({ insert: ['a'], update: [], prune: [], operator_owned: 0, unchanged: 0, plan_fp: FP });

function seedApi() {
  const calls = [];
  return { calls, seedApply: async (...args) => { calls.push(args); return { id: 3, changed: 1, pruned: 0 }; } };
}
function topicApi() {
  const calls = [];
  return { calls, telegramTopicSet: async (...args) => { calls.push(args); return { topic: { project: 'project-3', thread_id: 12 } }; } };
}

test('H1: submitApply sends nothing without a non-blank reason, and the trimmed reason with one', async () => {
  const api = seedApi();
  for (const reason of ['', '  ', undefined, null, 5]) {
    assert.equal(await submitApply(api, PLAN, true, reason), null, String(reason));
  }
  assert.equal(api.calls.length, 0);
  assert.equal(await submitApply(api, PLAN, false, 'why'), null);
  assert.equal(api.calls.length, 0);
  const out = await submitApply(api, PLAN, true, ' why ');
  assert.equal(out.tone, 'ok');
  assert.deepEqual(api.calls, [[FP, 'why']]);
});

test('H2: requestApply asks with a blocked REASON form and sends the reason the dialog wrote', async () => {
  let reloads = 0;
  const reload = () => { reloads++; };
  const asked = [];

  let api = seedApi();
  const blank = await requestApply({ apiObj: api, plan: PLAN, reload, confirm: async (o) => { asked.push(o); return true; } });
  assert.equal(blank, null);
  assert.equal(api.calls.length, 0, 'a confirm with a blank reason sends nothing');
  assert.equal(reloads, 0);
  assert.equal(asked[0].confirmBlocked, true);
  assert.deepEqual(asked[0].form, { reason: '' });
  assert.equal(asked[0].title, 'SEED REGISTRY');
  assert.equal(asked[0].confirmLabel, 'APPLY');

  api = seedApi();
  const out = await requestApply({ apiObj: api, plan: PLAN, reload, confirm: async (o) => { o.form.reason = 'why'; return true; } });
  assert.equal(out.tone, 'ok');
  assert.deepEqual(api.calls, [[FP, 'why']]);
  assert.equal(reloads, 1);

  // With renderForm the body is a function handing the form and setBlocked on.
  const rendered = [];
  await requestApply({ apiObj: seedApi(), plan: PLAN, reload,
    renderForm: (form, setBlocked) => { rendered.push([form, setBlocked]); return 'FORM'; },
    confirm: async (o) => { assert.equal(o.body({ setBlocked: 'SB' }), 'FORM'); return false; } });
  assert.equal(rendered.length, 1);
  assert.equal(rendered[0][1], 'SB');
  assert.deepEqual(rendered[0][0], { reason: '' });
  // Without renderForm the body stays the plan copy.
  await requestApply({ apiObj: seedApi(), plan: PLAN, reload,
    confirm: async (o) => { assert.equal(o.body, confirmCopy(PLAN)); return false; } });
});

test('H3: saveEdit refuses a confirmed blank reason, sends a filled one, and a cancel sends nothing', async () => {
  let reloads = 0;
  const reload = () => { reloads++; };
  const base = { project: 'project-3', from: 7, raw: '12', reload };

  let api = topicApi();
  let seen = null;
  const refused = await saveEdit({ ...base, apiObj: api, confirm: async (o) => { seen = o; o.form.reason = '   '; return true; } });
  assert.deepEqual(refused, { refused: 'a reason is required' });
  assert.equal(api.calls.length, 0);
  assert.equal(seen.confirmBlocked, true);
  assert.equal(seen.title, 'CHAT BINDINGS');
  assert.equal(seen.body, 'Move project-3 from thread 7 to 12?');

  api = topicApi();
  assert.equal(await saveEdit({ ...base, apiObj: api, confirm: async (o) => { o.form.reason = 'why'; return false; } }), null);
  assert.equal(api.calls.length, 0);

  api = topicApi();
  const ok = await saveEdit({ ...base, apiObj: api, confirm: async (o) => { o.form.reason = ' why '; return true; } });
  assert.equal(ok.outcome.tone, 'ok');
  assert.deepEqual(api.calls, [['project-3', 12, 'why']]);
  assert.equal(reloads, 1);

  // With renderForm the dialog body is the form, handed the move's copy.
  const got = [];
  await saveEdit({ ...base, apiObj: topicApi(), renderForm: (...a) => { got.push(a); return 'FORM'; },
    confirm: async (o) => { assert.equal(o.body({ setBlocked: 'SB' }), 'FORM'); return false; } });
  assert.deepEqual(got, [[{ reason: '' }, 'SB', 'Move project-3 from thread 7 to 12?']]);
});
