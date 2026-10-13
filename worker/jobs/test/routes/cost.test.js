import test from 'node:test';
import assert from 'node:assert/strict';
import { SECRET, call, sqlOf, worker } from '../lib/harness.js';

test('a burn day is keyed on the row, and the row must carry a real date', async () => {
  const bad = await call('/api/metrics/burn', { method: 'POST', body: { api_calls: 5 } });
  assert.equal(bad.status, 400);
  // A day is a PRIMARY KEY here. "today" or "" would become a row nobody can
  // find and nobody can overwrite — the file side's exact failure, one layer on.
  const junk = await call('/api/metrics/burn', { method: 'POST', body: { day: 'today' } });
  assert.equal(junk.status, 400);

  const r = await call('/api/metrics/burn', {
    method: 'POST',
    state: { burnDays: [{ day: '2026-08-28', usd_equiv: 134.62 }] },
    body: { day: '2026-08-28', api_calls: 429, usd_equiv: '134.62', peak_cache_read: '65858', actor: 'hub' }
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.burn_day.day, '2026-08-28');
  const [w] = sqlOf(r.db, /INSERT INTO burn_days/);
  // The upsert, and the day bound as ?1 — the row's own day decides what it
  // replaces. An hourly re-push has to be a no-op, not a duplicate.
  assert.match(w.sql, /ON CONFLICT\(day\) DO UPDATE/);
  assert.equal(w.binds[0], '2026-08-28');
});

test('numbers that arrive as CSV cells become numbers, and blanks become NULL', async () => {
  const r = await call('/api/metrics/burn', {
    method: 'POST',
    body: { day: '2026-08-28', api_calls: '429', usd_equiv: '', cache_read: 'n/a', avg_cache_read: '45264.7' }
  });
  assert.equal(r.status, 200);
  const [w] = sqlOf(r.db, /INSERT INTO burn_days/);
  assert.equal(w.binds[1], 429);            // api_calls, coerced
  assert.equal(w.binds[6], null);           // usd_equiv, empty cell -> NULL
  assert.equal(w.binds[4], null);           // cache_read, unparseable -> NULL, never NaN
  assert.equal(w.binds[8], 45264);          // avg_cache_read, an INTEGER column
});

test('a pr-cost sweep is one batch, upserted per pr_url', async () => {
  const rows = [
    { pr_url: 'https://github.com/x/y/pull/1', cost_usd: '136.80', stage_breakdown: 'execute:110.77;review:10.72' },
    { pr_url: 'https://github.com/x/y/pull/2', cost_usd: '4.10' },
    { cost_usd: '9.99' }   // no pr_url: skipped, never inserted keyless
  ];
  const r = await call('/api/metrics/pr-costs', { method: 'POST', body: { rows } });
  assert.equal(r.status, 200);
  assert.equal(r.body.upserted, 2);
  const writes = sqlOf(r.db, /INSERT INTO pr_costs/);
  assert.equal(writes.length, 2);
  assert.match(writes[0].sql, /ON CONFLICT\(pr_url\) DO UPDATE/);
  // cost-rollup rewrites the whole file every run, so the request that carries
  // it must not be able to bury the worker in round trips or in one huge body.
  const tooMany = await call('/api/metrics/pr-costs', {
    method: 'POST', body: { rows: new Array(2001).fill({ pr_url: 'x' }) }
  });
  assert.equal(tooMany.status, 400);
  const none = await call('/api/metrics/pr-costs', { method: 'POST', body: { rows: [{ cost_usd: 1 }] } });
  assert.equal(none.status, 400);
});

test('pr-costs carries auth_account + account_breakdown, and an old client cannot blank them', async () => {
  const r = await call('/api/metrics/pr-costs', {
    method: 'POST',
    state: { prCostsCols: ['pr_url', 'cost_usd', 'auth_account', 'account_breakdown'] },
    body: { rows: [
      { pr_url: 'https://github.com/x/y/pull/1', cost_usd: '10.00',
        auth_account: 'client-project-2-max', account_breakdown: 'client-project-2-max:9.00;ops-hub:1.00' },
      { pr_url: 'https://github.com/x/y/pull/2', cost_usd: '4.10' }   // pre-#173 rollup shape
    ] }
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.upserted, 2);
  const writes = sqlOf(r.db, /INSERT INTO pr_costs/);
  assert.equal(writes.length, 2);
  assert.equal(writes[0].binds[9], 'client-project-2-max');
  assert.equal(writes[0].binds[10], 'client-project-2-max:9.00;ops-hub:1.00');
  // The old-shape row binds NULL for both — and the upsert COALESCEs, so a
  // push from a rollup that predates the columns keeps what a newer one wrote.
  assert.equal(writes[1].binds[9], null);
  assert.equal(writes[1].binds[10], null);
  assert.match(writes[0].sql, /auth_account=COALESCE\(\?10, auth_account\)/);
  assert.match(writes[0].sql, /account_breakdown=COALESCE\(\?11, account_breakdown\)/);
  // Columns already present: no ALTER.
  assert.equal(sqlOf(r.db, /ALTER TABLE pr_costs/).length, 0);
});

test('the pr_costs column add is self-applied: ALTER exactly what PRAGMA says is missing', async () => {
  // An existing DB from before 2026-09-02: neither column.
  let r = await call('/api/metrics/pr-costs', {
    method: 'POST', state: { prCostsCols: ['pr_url', 'cost_usd'] },
    body: { rows: [{ pr_url: 'https://github.com/x/y/pull/1', cost_usd: '1' }] }
  });
  assert.equal(r.status, 200);
  let alters = sqlOf(r.db, /ALTER TABLE pr_costs ADD COLUMN/);
  assert.deepEqual(alters.map((a) => a.sql), [
    'ALTER TABLE pr_costs ADD COLUMN auth_account TEXT',
    'ALTER TABLE pr_costs ADD COLUMN account_breakdown TEXT'
  ]);
  // The probe runs BEFORE the write, so a write never lands on a table that
  // cannot take it.
  const order = r.db._calls.map((c) => c.sql);
  assert.ok(order.findIndex((q) => /PRAGMA table_info/.test(q)) < order.findIndex((q) => /INSERT INTO pr_costs/.test(q)));
  // Half-migrated (one of the two present): only the gap is added.
  r = await call('/api/metrics/pr-costs', {
    method: 'POST', state: { prCostsCols: ['pr_url', 'auth_account'] },
    body: { rows: [{ pr_url: 'https://github.com/x/y/pull/1', cost_usd: '1' }] }
  });
  alters = sqlOf(r.db, /ALTER TABLE pr_costs ADD COLUMN/);
  assert.deepEqual(alters.map((a) => a.sql), ['ALTER TABLE pr_costs ADD COLUMN account_breakdown TEXT']);
  // Once per DB handle: a second write on the same handle does not re-probe.
  const db2 = r.db;
  const secret = SECRET;
  const req = new Request('https://jobs.test/api/metrics/pr-costs', {
    method: 'POST', headers: { authorization: `Bearer ${secret}`, 'content-type': 'application/json' },
    body: JSON.stringify({ rows: [{ pr_url: 'https://github.com/x/y/pull/3' }] })
  });
  const res = await worker.fetch(req, { HARNESS_SECRET: secret, DB: db2 });
  assert.equal(res.status, 200);
  assert.equal(sqlOf(db2, /PRAGMA table_info/).length, 1);
});

test('a cost-rows push is one batch of inserts keyed (box, row_hash) that on conflict only fill a NULL lane_id / guard_fp', async () => {
  const noBox = await call('/api/metrics/cost-rows', { method: 'POST', body: { rows: [{ row_hash: 'a', line_no: 2 }] } });
  assert.equal(noBox.status, 400);
  const noRows = await call('/api/metrics/cost-rows', { method: 'POST', body: { box: 'project-2', rows: [] } });
  assert.equal(noRows.status, 400);
  const tooMany = await call('/api/metrics/cost-rows', {
    method: 'POST', body: { box: 'project-2', rows: new Array(2001).fill({ row_hash: 'a', line_no: 2 }) }
  });
  assert.equal(tooMany.status, 400);

  const full = { line_no: 2, row_hash: 'h1', ts: '2026-09-02T10:00:00Z', host: 'orgo-desktop',
    project: 'project-2', stage: 'execute', runner: 'claude', model: 'claude-opus-5',
    rc: '0', duration_s: '93', input_toks: '650892', output_toks: '82', cache_read: '10', cache_write: '0',
    cost_usd: '1.25', billing_mode: 'subscription', auth_fp: 'abc123def456', auth_account: 'client-project-2-max',
    session_id: 'sess-abc', row_source: 'transcript', result_usd: '0.40',
    ticket: 'TK-109', job_id: 'job-7', pr: 'https://github.com/x/y/pull/9', run_id: 'build-3',
    note: 'cliff-routed:grok:210000>200000', raw: '2026-09-02T10:00:00Z,orgo-desktop,project-2',
    lane_id: 'review-prs', guard_fp: 'fp-1' };
  // A 13-column row (pre-billing_mode): the client sends the trailing three as
  // null, and a client that predates 2026-09-14 omits the seven after them
  // entirely — undefined, not null, which is the case str()/numOrNull() have to
  // turn into NULL rather than the string "undefined".
  const short13 = { ...full, line_no: 3, row_hash: 'h2', billing_mode: null, auth_fp: null, auth_account: null };
  for (const k of ['session_id', 'row_source', 'result_usd', 'ticket', 'job_id', 'pr', 'run_id',
                   'note', 'raw', 'lane_id', 'guard_fp']) delete short13[k];
  const keyless = { ...full, row_hash: '' };   // no hash: skipped, never inserted keyless
  const r = await call('/api/metrics/cost-rows', {
    method: 'POST', body: { box: 'project-2', rows: [full, short13, keyless] }
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.accepted, 2);
  const writes = sqlOf(r.db, /INSERT INTO cost_rows/);
  assert.equal(writes.length, 2);
  // BH-3220: was DO NOTHING, which discarded the mirror's full row after the
  // emitter's truncated one. The behaviour is pinned end to end in
  // test/cost-rows-conflict-repair.bh-3220.test.js; this pins the clause.
  // TEST-CHANGE (BH-5352): the upsert also fills a NULL participant, so the
  // clause gains its COALESCE and its WHERE term. Still pinned whole and strict.
  assert.match(writes[0].sql.replace(/\s+/g, ' '),
    /ON CONFLICT\(box, row_hash\) DO UPDATE SET lane_id = COALESCE\(cost_rows\.lane_id, excluded\.lane_id\), guard_fp = COALESCE\(cost_rows\.guard_fp, excluded\.guard_fp\), participant = COALESCE\(cost_rows\.participant, excluded\.participant\) WHERE \(cost_rows\.lane_id IS NULL AND excluded\.lane_id IS NOT NULL\) OR \(cost_rows\.guard_fp IS NULL AND excluded\.guard_fp IS NOT NULL\) OR \(cost_rows\.participant IS NULL AND excluded\.participant IS NOT NULL\)$/);
  // The conflict path still never rewrites a stored row: the only columns it
  // may assign are the three it fills from NULL.
  const setCols = [...writes[0].sql.split(/DO UPDATE SET/)[1].split(/\bWHERE\b/)[0]
    .matchAll(/(\w+)\s*=/g)].map((m) => m[1]);
  assert.deepEqual(setCols, ['lane_id', 'guard_fp', 'participant']);
  assert.equal(writes[0].binds[0], 'project-2');
  assert.equal(writes[0].binds[1], 'h1');
  assert.equal(writes[0].binds[2], 2);            // line_no, an INTEGER
  assert.equal(writes[0].binds[11], 650892);      // input_toks coerced
  assert.equal(writes[0].binds[15], 1.25);        // cost_usd coerced
  assert.equal(writes[0].binds[18], 'client-project-2-max');
  // Row provenance + the attribution tags (2026-09-14), appended AFTER
  // auth_account so every earlier bind position is unchanged.
  assert.equal(writes[0].binds[19], 'sess-abc');      // session_id
  assert.equal(writes[0].binds[20], 'transcript');    // row_source
  assert.equal(writes[0].binds[21], 0.40);            // result_usd coerced
  assert.equal(writes[0].binds[22], 'TK-109');        // ticket
  assert.equal(writes[0].binds[23], 'job-7');         // job_id
  assert.equal(writes[0].binds[24], 'https://github.com/x/y/pull/9');
  assert.equal(writes[0].binds[25], 'build-3');       // run_id
  // `note` (the 24th CSV column, dropped by the client's own COLS list until
  // BH-1032) and `raw` (the verbatim line, so a reader can re-emit rather than
  // reconstruct), appended after run_id so every earlier position is unchanged.
  assert.equal(writes[0].binds[26], 'cliff-routed:grok:210000>200000');
  assert.equal(writes[0].binds[27], '2026-09-02T10:00:00Z,orgo-desktop,project-2');
  // BH-2303: lane_id, bound LAST (after inserted_at), so every earlier position is unchanged.
  assert.equal(writes[0].binds[29], 'review-prs');
  assert.equal(writes[1].binds[29], null);
  // BH-2537: guard_fp, bound after lane_id; absent -> NULL.
  assert.equal(writes[0].binds[30], 'fp-1');
  assert.equal(writes[1].binds[30], null);
  // The short row: NULL, not "" and not "null", in the trailing three...
  assert.equal(writes[1].binds[16], null);
  assert.equal(writes[1].binds[17], null);
  assert.equal(writes[1].binds[18], null);
  // ...and in the nine an older client does not send at all.
  for (let i = 19; i <= 27; i++) assert.equal(writes[1].binds[i], null);
  // Columns already present: no ALTER.
  assert.equal(sqlOf(r.db, /ALTER TABLE/).length, 0);
});

test('the cost_rows column add is self-applied: ALTER exactly what PRAGMA says is missing', async () => {
  // A database from before 2026-09-14 has the original nineteen data columns
  // and none of the seven. The ALTERs are what makes "deploy = migration" stay
  // true for a table that already exists — D1 has no ADD COLUMN IF NOT EXISTS,
  // so the CREATE in schema.sql covers a fresh DB and this covers every other.
  let r = await call('/api/metrics/cost-rows', {
    method: 'POST',
    state: { costRowsCols: ['box', 'row_hash', 'line_no', 'ts', 'cost_usd', 'auth_account', 'inserted_at'] },
    body: { box: 'project-2', rows: [{ row_hash: 'h1', line_no: 2, cost_usd: '1' }] }
  });
  assert.equal(r.status, 200);
  assert.deepEqual(sqlOf(r.db, /ALTER TABLE cost_rows ADD COLUMN/).map((a) => a.sql), [
    'ALTER TABLE cost_rows ADD COLUMN session_id TEXT',
    'ALTER TABLE cost_rows ADD COLUMN row_source TEXT',
    'ALTER TABLE cost_rows ADD COLUMN result_usd REAL',
    'ALTER TABLE cost_rows ADD COLUMN ticket TEXT',
    'ALTER TABLE cost_rows ADD COLUMN job_id TEXT',
    'ALTER TABLE cost_rows ADD COLUMN pr TEXT',
    'ALTER TABLE cost_rows ADD COLUMN run_id TEXT',
    'ALTER TABLE cost_rows ADD COLUMN note TEXT',
    'ALTER TABLE cost_rows ADD COLUMN raw TEXT',
    'ALTER TABLE cost_rows ADD COLUMN lane_id TEXT',   // BH-2303
    'ALTER TABLE cost_rows ADD COLUMN guard_fp TEXT',  // TEST-CHANGE BH-2537: 25 -> 26
    'ALTER TABLE cost_rows ADD COLUMN participant TEXT' // TEST-CHANGE BH-5349: ADDED_COLUMNS.cost_rows gains participant
  ]);
  // The probe runs BEFORE the write, so a push never lands on a table that
  // cannot take it — 2000 rows rejected mid-batch is 2000 rows lost until the
  // cursor re-offers them.
  const order = r.db._calls.map((c) => c.sql);
  assert.ok(order.findIndex((q) => /PRAGMA table_info\(cost_rows\)/.test(q))
            < order.findIndex((q) => /INSERT INTO cost_rows/.test(q)));
  // Half-migrated: only the gap is added.
  r = await call('/api/metrics/cost-rows', {
    method: 'POST',
    state: { costRowsCols: ['box', 'row_hash', 'line_no', 'session_id', 'row_source', 'result_usd', 'ticket', 'job_id', 'pr'] },
    body: { box: 'project-2', rows: [{ row_hash: 'h1', line_no: 2 }] }
  });
  assert.deepEqual(sqlOf(r.db, /ALTER TABLE cost_rows ADD COLUMN/).map((a) => a.sql),
                   ['ALTER TABLE cost_rows ADD COLUMN run_id TEXT',
                    'ALTER TABLE cost_rows ADD COLUMN note TEXT',
                    'ALTER TABLE cost_rows ADD COLUMN raw TEXT',
                    'ALTER TABLE cost_rows ADD COLUMN lane_id TEXT',
                    'ALTER TABLE cost_rows ADD COLUMN guard_fp TEXT',  // TEST-CHANGE BH-2537: 25 -> 26
                    'ALTER TABLE cost_rows ADD COLUMN participant TEXT']);  // TEST-CHANGE BH-5349
});

test('GET /api/metrics/cost-rows filters by account and project', async () => {
  const r = await call('/api/metrics/cost-rows?auth_account=client-project-2-max&project=project-2&limit=5', {
    state: { costRows: [{ box: 'project-2', row_hash: 'h1', auth_account: 'client-project-2-max' }] }
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.cost_rows.length, 1);
  const [q] = sqlOf(r.db, /FROM cost_rows/);
  assert.match(q.sql, /auth_account=\?2/);
  assert.match(q.sql, /project=\?1/);
  assert.deepEqual(q.binds, ['project-2', 'client-project-2-max']);
  assert.match(q.sql, /LIMIT 5$/);
});

test('a model-prices push is a whole-table UPSERT, never a replace', async () => {
  // WHY UPSERT AND NOT DELETE+INSERT: a refresh that fetched fewer models than
  // last time must not un-price the ones it missed. An un-priced model does not
  // read as an error anywhere — it reads as a free lane.
  const none = await call('/api/model-prices', { method: 'POST', body: { rows: [] } });
  assert.equal(none.status, 400);
  const tooMany = await call('/api/model-prices', {
    method: 'POST', body: { rows: new Array(501).fill({ model: 'm' }) }
  });
  assert.equal(tooMany.status, 400);
  const nameless = await call('/api/model-prices', { method: 'POST', body: { rows: [{ prompt: 1 }] } });
  assert.equal(nameless.status, 400);

  const r = await call('/api/model-prices', {
    method: 'POST',
    body: { source: 'openrouter', rows: [
      { model: 'claude-opus-5', slug: 'anthropic/claude-opus-5', prompt: '0.000015',
        completion: '0.000075', cache_read: '0.0000015', cache_write: '0.00001875' },
      { model: 'grok-4.6', slug: 'x-ai/grok-4.6', prompt: 0.000002, completion: 0.00001,
        cache_read: 0.0000005, cache_write: null, cliff_tokens: '200000' }] }
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.accepted, 2);
  const writes = sqlOf(r.db, /INSERT INTO model_prices/);
  assert.equal(writes.length, 2);
  assert.match(writes[0].sql, /ON CONFLICT\(model\) DO UPDATE SET/);
  assert.doesNotMatch(writes[0].sql, /DELETE FROM model_prices/);
  assert.equal(writes[0].binds[0], 'claude-opus-5');
  assert.equal(writes[0].binds[2], 0.000015);        // prompt coerced from a string
  assert.equal(writes[0].binds[6], null);            // no cliff -> NULL, never 0
  assert.equal(writes[0].binds[7], 'openrouter');
  assert.equal(writes[1].binds[5], null);            // a vendor with no cache-write rate
  assert.equal(writes[1].binds[6], 200000);          // cliff coerced to an INTEGER
  // A row with no source named still lands under a source, never under "".
  const r2 = await call('/api/model-prices', { method: 'POST', body: { rows: [{ model: 'm', prompt: 1 }] } });
  assert.equal(sqlOf(r2.db, /INSERT INTO model_prices/)[0].binds[7], 'openrouter');
});

test('GET /api/model-prices answers in catalog/model-prices.json shape', async () => {
  // The SHAPE is the contract: bin/model-prices-sync.sh writes this body
  // straight to $HARNESS/state/model-prices.json, which is the path
  // cost_price_tokens / cost_model_cliff / transcript-cost already prefer. A
  // shape the consumers have to translate is a second place to be wrong.
  const r = await call('/api/model-prices', { state: { modelPrices: [
    { model: 'claude-opus-5', slug: 'anthropic/claude-opus-5', prompt: 0.000015, completion: 0.000075,
      cache_read: 0.0000015, cache_write: 0.00001875, cliff_tokens: null,
      source: 'openrouter', updated_at: '2026-09-20T04:30:00Z' },
    { model: 'grok-4.6', slug: 'x-ai/grok-4.6', prompt: 0.000002, completion: 0.00001,
      cache_read: 0.0000005, cache_write: null, cliff_tokens: 200000,
      source: 'openrouter', updated_at: '2026-09-19T04:30:00Z' }] } });
  assert.equal(r.status, 200);
  assert.equal(r.body.models, 2);
  assert.equal(r.body.updated_at, '2026-09-20T04:30:00Z');   // the NEWEST row's stamp
  assert.equal(r.body.source, 'openrouter');
  assert.deepEqual(r.body.per_token['claude-opus-5'], {
    prompt: 0.000015, completion: 0.000075, cache_read: 0.0000015,
    cache_write: 0.00001875, slug: 'anthropic/claude-opus-5' });
  // cliff_tokens OMITTED, never null: cost_model_cliff reads `.cliff_tokens |
  // numbers` and a null key would be a model that claims a cliff of nothing.
  assert.ok(!('cliff_tokens' in r.body.per_token['claude-opus-5']));
  assert.equal(r.body.per_token['grok-4.6'].cliff_tokens, 200000);
  assert.equal(r.body.per_token['grok-4.6'].cache_write, null);
  assert.match(sqlOf(r.db, /FROM model_prices/)[0].sql, /ORDER BY model/);
  // An empty table answers a shape, never a 500 — the CLIENT decides that a
  // thin table is not worth writing (MODEL_PRICES_MIN), and it needs a body to
  // decide with.
  const empty = await call('/api/model-prices', { state: { modelPrices: [] } });
  assert.equal(empty.status, 200);
  assert.equal(empty.body.models, 0);
  assert.deepEqual(empty.body.per_token, {});
});

test('the metrics routes are behind the same bearer as everything else', async () => {
  for (const path of ['/api/metrics/burn', '/api/metrics/pr-costs', '/api/metrics/cost-rows',
                      '/api/metrics/extra-usage', '/api/metrics/reconcile',
                      '/api/metrics/outcomes', '/api/metrics/cli-versions',
                      '/api/metrics/flakes', '/api/metrics/llm-spend']) {
    const r = await call(path, { secret: null });
    assert.equal(r.status, 401, `${path} answered ${r.status} with no bearer`);
  }
});
