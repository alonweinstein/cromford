import test from 'node:test';
import assert from 'node:assert/strict';
import { LANE, call, iso } from '../lib/harness.js';

test('a catalog lane with no cap-flag row reports explicit 0', async () => {
  const r = await call('/api/catalog/execute%2Fproject-3%2Fclaude', { state: { catalog: [LANE] } });
  assert.equal(r.status, 200);
  assert.equal(r.body.explicit, 0);
  // Floored to the build fuse, with the stored number still visible.
  assert.equal(r.body.budget_usd, 50);
  assert.equal(r.body.derived_usd, 12.5);
});

test('a derived build lane is floored at the $50 max-cost fuse', async () => {
  const r = await call('/api/catalog/execute%2Fproject-3%2Fclaude', { state: { catalog: [LANE] } });
  assert.equal(r.body.source, 'catalog');
  assert.ok(r.body.budget_usd >= 50, 'an honest ~$16-25 build must sit well under the cap');
});

test('an EXPLICIT row still binds verbatim, floor and all', async () => {
  // The whole doctrine: a derivation gets floored, a human does not. An
  // operator who caps a lane at $4 on purpose gets $4.
  const r = await call('/api/catalog/execute%2Fproject-3%2Fclaude', {
    state: {
      catalog: [{ lane: 'execute/project-3/claude', budget_usd: 4, updated_at: iso(0) }],
      capFlags: [{ lane: 'execute/project-3/claude', explicit: 1, reason: 'the operator: capped on purpose' }]
    }
  });
  assert.equal(r.body.explicit, 1);
  assert.equal(r.body.budget_usd, 4);
});

test('a lane nobody sized falls to its stage FAMILY tier, not to the smallest number', async () => {
  const build = await call('/api/catalog/execute%2Fnew-proj%2Fclaude', { state: { catalog: [] } });
  assert.equal(build.body.source, 'tier');
  assert.equal(build.body.budget_usd, 50);
  const product = await call('/api/catalog/prd%2Fnew-proj%2Fclaude', { state: { catalog: [] } });
  assert.equal(product.body.budget_usd, 20);
  const misc = await call('/api/catalog/probe%2Fnew-proj%2Fclaude', { state: { catalog: [] } });
  assert.equal(misc.body.budget_usd, 10);
  // takeover adopts a branch and finishes it: build-shaped money, named so a
  // hand-launched session is not funded by an accident of the catch-all.
  const takeover = await call('/api/catalog/takeover%2Fnew-proj%2Fclaude', { state: { catalog: [] } });
  assert.equal(takeover.body.budget_usd, 50);
});

test('the catalog sync derives dollars against the stage family floor', async () => {
  const r = await call('/api/catalog', {
    method: 'PUT',
    body: { lanes: [
      // 400K ceiling -> 400000/1e6*15 + 60000/1e6*75 = $10.50, under the build
      // fuse, so it lands at $50.
      { stage: 'execute', project: 'project-3', runner: 'claude', ceiling_tokens: 400000 },
      // A genuinely big ceiling derives ABOVE the floor and keeps its number.
      { stage: 'execute', project: 'big-os', runner: 'claude', ceiling_tokens: 4000000 },
      // Product family floors at $20, misc at $10.
      { stage: 'prd', project: 'project-3', ceiling_tokens: 100000 },
      { stage: 'triage', project: 'project-3', ceiling_tokens: 100000 }
    ] }
  });
  assert.equal(r.status, 200);
  const caps = new Map(r.db._calls
    .filter((c) => /INSERT INTO budget_catalog/.test(c.sql))
    .map((c) => [c.binds[0], c.binds[1]]));
  assert.equal(caps.get('execute/project-3/claude'), 50);
  assert.equal(caps.get('execute/big-os/claude'), 105);
  assert.equal(caps.get('prd/project-3/*'), 20);
  assert.equal(caps.get('triage/project-3/*'), 10);
});

test('an explicit row rides on the lane it names, with its reason', async () => {
  const r = await call('/api/catalog/execute%2Fproject-3%2Fclaude', {
    state: { catalog: [LANE], capFlags: [{ lane: 'execute/project-3/claude', explicit: 1, reason: 'the operator: this lane is capped on purpose' }] }
  });
  assert.equal(r.body.explicit, 1);
  assert.equal(r.body.explicit_reason, 'the operator: this lane is capped on purpose');
});

test('explicit does not travel down the lane ladder', async () => {
  // "This exact number, on purpose" is a statement about ONE row. A wildcard
  // lane answering for a specific one must not also lend it its verbatim
  // standing, or an explicit cap would silently bind lanes nobody looked at.
  const r = await call('/api/catalog/execute%2Fproject-3%2Fclaude', {
    state: {
      catalog: [{ lane: 'execute/*/*', budget_usd: 9, updated_at: iso(0) }],
      capFlags: [{ lane: 'execute/project-3/claude', explicit: 1 }]
    }
  });
  assert.equal(r.body.matched, 'execute/*/*');
  assert.equal(r.body.explicit, 0);
});

test('the deploy-time catalog sync never writes the explicit flag', async () => {
  // The whole reason this is a separate table: PUT /api/catalog rewrites every
  // lane it carries, and a flag living on that row would be reset by the next
  // hot-deploy — a config change nobody made.
  const r = await call('/api/catalog', {
    method: 'PUT',
    body: { lanes: [{ stage: 'execute', project: 'project-3', runner: 'claude', ceiling_tokens: 400000 }] }
  });
  assert.equal(r.status, 200);
  assert.equal(r.db._calls.filter((c) => /budget_cap_flags/.test(c.sql)).length, 0);
  const w = await call('/api/cap-flags', {
    method: 'PUT', body: { lane: 'execute/project-3/claude', explicit: true, reason: 'on purpose' }
  });
  assert.equal(w.status, 200);
  const ins = w.db._calls.find((c) => /INSERT INTO budget_cap_flags/.test(c.sql));
  assert.equal(ins.binds[1], 1);
});
