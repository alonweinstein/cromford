import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { LLM_SITES, siteAttribution } from '../src/lib/llm-sites-catalog.js';
import { LANES_REGISTRY } from '../src/lib/core.js';
import { siteRows } from '../src/lib/llm-sites.js';

// BH-2554 (BH-2540.1) — GET /api/metrics/llm-sites answers one real row per
// catalog site: spend, refusals and knobs, from ONE GROUP BY over cost_rows and
// one settings read. Every case goes through the real worker.fetch (D2) on the
// real schema.sql, with the clock fixed at 2026-09-26T09:00:00Z.

const SECRET = 'test-secret';
const NOW_MS = Date.parse('2026-09-26T09:00:00Z');
const BUDGETS = JSON.parse(readFileSync(new URL('../../../catalog/context-budgets.json', import.meta.url), 'utf8'));
const ago = (h) => new Date(NOW_MS - h * 3600e3).toISOString().replace(/\.\d{3}Z$/, 'Z');
const regDefault = (env) => LANES_REGISTRY.libs.find((l) => l.id === 'call-guard').knobs.find((k) => k.env === env).default;

async function open(t, hooks) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const env = await openDb(hooks);
  if (!env) t.skip('node:sqlite unavailable on this runtime');
  return env;
}

let n = 0;
function row(db, { ts, stage, lane_id = null, runner = 'claude', cost_usd = null, billing_mode = 'metered', row_source = 'transcript', note = null }) {
  n += 1;
  db.prepare(`INSERT INTO cost_rows (box, row_hash, line_no, ts, stage, lane_id, runner, cost_usd, billing_mode, row_source, note, inserted_at)
              VALUES ('hub', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
    .run(`h${n}`, n, ts, stage, lane_id, runner, cost_usd, billing_mode, row_source, note, ago(0));
}

function setting(db, key, value, actor = 'console') {
  db.prepare(`INSERT OR REPLACE INTO settings (key, value, note, actor, updated_at) VALUES (?, ?, 'test', ?, ?)`)
    .run(key, value, actor, ago(0));
}

async function get(DB, { secret = SECRET } = {}) {
  const headers = secret === null ? {} : { authorization: `Bearer ${secret}` };
  const res = await worker.fetch(new Request('https://jobs.test/api/metrics/llm-sites', { headers }), { DB, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json() };
}

const siteOf = (body, id) => body.sites.find((s) => s.id === id);

test('W1: one entry per catalog site, in order, with windows and the request clock; 401 without the bearer', async (t) => {
  const env = await open(t); if (!env) return;
  const r = await get(env.DB);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body.sites.map((s) => s.id), LLM_SITES.map((s) => s.id));
  for (const s of LLM_SITES) {
    const got = siteOf(r.body, s.id);
    assert.equal(got.lane, s.lane, s.id);
    assert.equal(got.stage, s.stage, s.id);
    assert.equal(got.kind, s.kind, s.id);
    assert.equal(got.attribution, siteAttribution(s).attribution, s.id);
  }
  assert.deepEqual(r.body.windows, { since_7d: '2026-09-19T09:00:00Z', since_24h: '2026-09-25T09:00:00Z', today: '2026-09-26T00:00:00Z' });
  assert.equal(r.body.as_of, '2026-09-26T09:00:00Z');
  assert.deepEqual(r.body.incomplete, []);
  assert.equal((await get(env.DB, { secret: null })).status, 401);
});

test('W1b: the "*" site totals every priced row; a none site totals nothing', async (t) => {
  const env = await open(t); if (!env) return;
  row(env.db, { ts: ago(3), stage: 'triage', lane_id: 'alert-triage', cost_usd: 0.5 });
  row(env.db, { ts: ago(30), stage: 'review', lane_id: 'review-prs', runner: 'grok', cost_usd: 1.5 });
  row(env.db, { ts: ago(50), stage: 'mine', cost_usd: 0.25 });
  row(env.db, { ts: ago(50), stage: 'mine', cost_usd: null });
  const r = await get(env.DB);
  const all = siteOf(r.body, 'agent-call');
  assert.equal(all.usd_7d.total, 2.25);
  assert.deepEqual(all.usd_7d.by_runner, { claude: 0.75, grok: 1.5 });
  assert.equal(all.calls_7d, 4);
  // BH-2562 put oauth-refresh on stage canary; grok-envelope-probe is the none site now.
  assert.equal(siteOf(r.body, 'grok-envelope-probe').usd_7d, null);
});

test('W2: alert-triage per-runner 24h/7d spend; 8d row excluded; other-lane row not counted, NULL-lane row counted', async (t) => {
  const env = await open(t); if (!env) return;
  row(env.db, { ts: ago(3), stage: 'triage', lane_id: 'alert-triage', runner: 'claude', cost_usd: 0.5 });
  row(env.db, { ts: ago(72), stage: 'triage', lane_id: 'alert-triage', runner: 'grok', cost_usd: 0.25 });
  row(env.db, { ts: ago(8 * 24), stage: 'triage', lane_id: 'alert-triage', runner: 'claude', cost_usd: 2 });
  let r = await get(env.DB);
  let s = siteOf(r.body, 'alert-triage');
  assert.deepEqual(s.usd_24h, { by_runner: { claude: 0.5 }, total: 0.5 });
  assert.deepEqual(s.usd_7d, { by_runner: { claude: 0.5, grok: 0.25 }, total: 0.75 });
  assert.equal(s.calls_7d, 2);
  assert.equal(s.badges.no_row, false);

  row(env.db, { ts: ago(5), stage: 'triage', lane_id: 'alerts-medic', runner: 'claude', cost_usd: 2 });
  row(env.db, { ts: ago(5), stage: 'triage', lane_id: null, runner: 'claude', cost_usd: 1.5 });
  r = await get(env.DB);
  s = siteOf(r.body, 'alert-triage');
  assert.deepEqual(s.usd_7d, { by_runner: { claude: 2, grok: 0.25 }, total: 2.25 });
  assert.equal(s.calls_7d, 3);
  assert.equal(siteOf(r.body, 'alerts-medic').usd_7d.total, 3.5);
});

test('W3: metered / subscription / unknown billing split; unpriced rows counted apart', async (t) => {
  const env = await open(t); if (!env) return;
  row(env.db, { ts: ago(10), stage: 'mine', lane_id: 'rule-miner', cost_usd: 1.5, billing_mode: 'metered' });
  row(env.db, { ts: ago(10), stage: 'mine', lane_id: 'rule-miner', cost_usd: 0.5, billing_mode: 'subscription' });
  row(env.db, { ts: ago(10), stage: 'mine', lane_id: 'rule-miner', runner: 'grok', cost_usd: 0.25, billing_mode: null });
  row(env.db, { ts: ago(10), stage: 'mine', lane_id: 'rule-miner', runner: 'codex', cost_usd: null, billing_mode: 'metered' });
  const s = siteOf((await get(env.DB)).body, 'rule-miner');
  assert.equal(s.cash_7d, 1.5);
  assert.equal(s.notional_7d, 0.5);
  assert.equal(s.unknown_billing_7d, 0.25);
  assert.equal(s.unpriced_7d, 1);
  assert.equal(s.calls_7d, 4);
  assert.deepEqual(s.usd_7d, { by_runner: { claude: 2, grok: 0.25 }, total: 2.25 });
  assert.ok(!('codex' in s.usd_7d.by_runner), 'an unpriced row never becomes a 0 in by_runner');
});

test('W4: today_usd counts only rows since UTC midnight', async (t) => {
  const env = await open(t); if (!env) return;
  row(env.db, { ts: '2026-09-26T01:00:00Z', stage: 'mine', lane_id: 'rule-miner', cost_usd: 0.5 });
  row(env.db, { ts: '2026-09-25T23:00:00Z', stage: 'mine', lane_id: 'rule-miner', cost_usd: 0.25 });
  const s = siteOf((await get(env.DB)).body, 'rule-miner');
  assert.equal(s.today_usd, 0.5);
  assert.equal(s.usd_24h.total, 0.75);
  assert.equal(siteOf((await get(env.DB)).body, 'review-prs').today_usd, 0, 'an attributed site with no rows is a measured 0');
});

test('W5: refusal classes and their negatives', async (t) => {
  const env = await open(t); if (!env) return;
  const r0 = { stage: 'triage', lane_id: 'alert-triage', ts: ago(4) };
  row(env.db, { ...r0, row_source: 'refused', note: 'refused:runner-not-allowed' });
  row(env.db, { ...r0, row_source: 'refused', note: 'refused:call-guard:repeat' });
  row(env.db, { ...r0, note: 'context-kill:ceiling=400000', cost_usd: 0.5 });
  row(env.db, { ...r0, note: 'cliff-avoided:grok', cost_usd: 0.25 });
  row(env.db, { ...r0, note: 'cache_ttl=1h', cost_usd: 0.25 });
  row(env.db, { ...r0, row_source: 'transcript', note: 'refused:rate_limited' });
  row(env.db, { ...r0, note: 'context-kill-off', cost_usd: 0.25 });
  const s = siteOf((await get(env.DB)).body, 'alert-triage');
  assert.deepEqual(s.refused_7d, { gate: 1, guard: 1, context_kill: 2 });
  assert.equal(s.calls_7d, 7);
  row(env.db, { ...r0, row_source: 'refused', note: null });
  assert.deepEqual(siteOf((await get(env.DB)).body, 'alert-triage').refused_7d, { gate: 2, guard: 1, context_kill: 2 }, 'a refused row with no note is gate');
});

test('W6: guard_k from the registry map; a non-seed row overrides, a seed row does not', async (t) => {
  const env = await open(t); if (!env) return;
  const reg = regDefault('CALL_GUARD_MAX_MAP');
  const regK = Number(/(?:^|[\s,])triage=(\d+)/.exec(reg)[1]);
  assert.equal(siteOf((await get(env.DB)).body, 'alert-triage').guard_k, regK);
  setting(env.db, 'lib.call-guard.call_guard_max_map', 'triage=4 default=2', 'registry-seed');
  assert.equal(siteOf((await get(env.DB)).body, 'alert-triage').guard_k, regK);
  setting(env.db, 'lib.call-guard.call_guard_max_map', 'triage=4 default=2', 'console');
  let r = await get(env.DB);
  assert.equal(siteOf(r.body, 'alert-triage').guard_k, 4);
  assert.equal(siteOf(r.body, 'rule-miner').guard_k, 2, 'a stage with no pair takes default=');
  assert.equal(siteOf(r.body, 'grok-envelope-probe').guard_k, null, 'no stage, no K');
  assert.deepEqual(r.body.incomplete, []);
});

test('W6b: a malformed operator map falls back to the registry and names guard_k in incomplete', async (t) => {
  const env = await open(t); if (!env) return;
  setting(env.db, 'lib.call-guard.call_guard_max_map', 'triage=x', 'console');
  const r = await get(env.DB);
  const regK = Number(/(?:^|[\s,])triage=(\d+)/.exec(regDefault('CALL_GUARD_MAX_MAP'))[1]);
  assert.equal(siteOf(r.body, 'alert-triage').guard_k, regK);
  assert.deepEqual(r.body.incomplete, ['guard_k']);
});

test('W6c: guard_enforced follows CALL_GUARD_STAGES', async (t) => {
  const env = await open(t); if (!env) return;
  let r = await get(env.DB);
  assert.equal(siteOf(r.body, 'alert-triage').guard_enforced, true);
  assert.equal(siteOf(r.body, 'rule-miner').guard_enforced, false);
  setting(env.db, 'lib.call-guard.call_guard_stages', 'mine', 'console');
  r = await get(env.DB);
  assert.equal(siteOf(r.body, 'alert-triage').guard_enforced, false);
  assert.equal(siteOf(r.body, 'rule-miner').guard_enforced, true);
  setting(env.db, 'lib.call-guard.call_guard_stages', 'all', 'console');
  assert.equal(siteOf((await get(env.DB)).body, 'alert-triage').guard_enforced, true);
  setting(env.db, 'lib.call-guard.call_guard_stages', 'triage none', 'console');
  assert.equal(siteOf((await get(env.DB)).body, 'alert-triage').guard_enforced, false);
});

test('W7: kill_tokens is the min project-less budget for the stage; no match is null + no_kill', async (t) => {
  const env = await open(t); if (!env) return;
  const r = await get(env.DB);
  const free = BUDGETS.lanes.filter((l) => !('project' in l) && Number.isInteger(l.context_kill_tokens) && l.context_kill_tokens > 0);
  const want = Math.min(...free.filter((l) => l.stage === 'triage').map((l) => l.context_kill_tokens));
  assert.ok(Number.isFinite(want));
  const at = siteOf(r.body, 'alert-triage');
  assert.equal(at.kill_tokens, want);
  assert.equal(at.badges.no_kill, false);
  const miss = LLM_SITES.find((s) => {
    const a = siteAttribution(s);
    return a.attribution !== 'none' && !a.all && !a.stages.some((st) => free.some((l) => l.stage === st));
  });
  assert.ok(miss, 'the committed catalog has a site with no matching budget');
  assert.equal(siteOf(r.body, miss.id).kill_tokens, null);
  assert.equal(siteOf(r.body, miss.id).badges.no_kill, true);
  assert.equal(siteOf(r.body, 'agent-call').kill_tokens, null);
});

test('W8: cap_usd_day from a non-seed row, else the registry default; knobs_bound names bound LLM_ knobs', async (t) => {
  const env = await open(t); if (!env) return;
  const lane = LANES_REGISTRY.lanes.find((l) => l.id === 'alert-triage');
  const capDefault = Number(lane.knobs.find((k) => k.env === 'LLM_USD_CAP_DAY').default);
  let s = siteOf((await get(env.DB)).body, 'alert-triage');
  assert.equal(s.cap_usd_day, capDefault);
  assert.deepEqual(s.knobs_bound, []);
  assert.equal(s.badges.no_knob, false);
  setting(env.db, 'lane.alert-triage.llm_usd_cap_day', '5', 'console');
  s = siteOf((await get(env.DB)).body, 'alert-triage');
  assert.equal(s.cap_usd_day, 5);
  assert.deepEqual(s.knobs_bound, ['LLM_USD_CAP_DAY']);
});

test('W8b: a lane that declares no LLM_USD_CAP_DAY has a null cap', () => {
  // Every lane the committed catalog names declares the cap today, so the
  // registry is the real one with that one knob taken off alert-triage.
  const registry = {
    ...LANES_REGISTRY,
    lanes: LANES_REGISTRY.lanes.map((l) => (l.id === 'alert-triage' ? { ...l, knobs: l.knobs.filter((k) => k.env !== 'LLM_USD_CAP_DAY') } : l)),
  };
  const sites = [LLM_SITES.find((s) => s.id === 'alert-triage'), { id: 'ghost', lane: 'no-such-lane', stage: 'triage' }];
  const settings = [{ key: 'lane.alert-triage.llm_usd_cap_day', value: '5', actor: 'console' }];
  const r = siteRows({ sites, agg: [], settings, registry, budgets: BUDGETS });
  assert.equal(r.sites[0].cap_usd_day, null);
  assert.equal(r.sites[0].badges.no_knob, false, 'LLM_LANE_ENABLED is still declared');
  assert.equal(r.sites[1].cap_usd_day, null);
  assert.equal(r.sites[1].badges.no_knob, true, 'a lane the registry does not know declares no knob');
  assert.deepEqual(r.incomplete, []);
});

test('W8c: a registry-seed row is not bound; a malformed cap row falls back and is named', async (t) => {
  const env = await open(t); if (!env) return;
  setting(env.db, 'lane.alert-triage.llm_usd_cap_day', '9', 'registry-seed');
  setting(env.db, 'lane.alert-triage.llm_lane_enabled', '0', 'console');
  let r = await get(env.DB);
  let s = siteOf(r.body, 'alert-triage');
  assert.deepEqual(s.knobs_bound, ['LLM_LANE_ENABLED']);
  assert.equal(s.cap_usd_day, 0);
  setting(env.db, 'lane.alert-triage.llm_usd_cap_day', 'lots', 'console');
  r = await get(env.DB);
  assert.equal(siteOf(r.body, 'alert-triage').cap_usd_day, 0);
  assert.deepEqual(r.body.incomplete, ['cap_usd_day']);
});

test('W9: badges no_row / no_knob; a none site has null money', async (t) => {
  const env = await open(t); if (!env) return;
  const r = await get(env.DB);
  assert.equal(siteOf(r.body, 'lane-probe').badges.no_row, true);
  assert.equal(siteOf(r.body, 'run-decompose').badges.no_knob, true);
  assert.equal(siteOf(r.body, 'alert-triage').badges.no_knob, false);
  const o = siteOf(r.body, 'grok-envelope-probe');
  for (const k of ['usd_24h', 'usd_7d', 'cash_7d', 'notional_7d', 'unknown_billing_7d', 'today_usd']) assert.equal(o[k], null, k);
  assert.equal(o.calls_7d, 0);
  const rd = siteOf(r.body, 'run-decompose');
  assert.deepEqual(rd.usd_7d, { by_runner: {}, total: 0 });
  assert.equal(rd.cash_7d, 0);
});

function throwing(DB, needle) {
  return {
    ...DB,
    prepare(sql) {
      if (sql.includes(needle)) throw new Error(`boom: ${needle}`);
      return DB.prepare(sql);
    },
  };
}

test('R-settings: a failed settings read nulls the knob fields and names itself; money stays', async (t) => {
  const env = await open(t); if (!env) return;
  row(env.db, { ts: ago(3), stage: 'triage', lane_id: 'alert-triage', cost_usd: 0.5 });
  const r = await get(throwing(env.DB, "key LIKE 'lib.call-guard.%'"));
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body.incomplete, ['settings']);
  const s = siteOf(r.body, 'alert-triage');
  for (const k of ['guard_k', 'guard_enforced', 'cap_usd_day', 'knobs_bound']) assert.equal(s[k], null, k);
  assert.equal(s.usd_7d.total, 0.5);
});

test('R500: a failed main aggregate is a 500', async (t) => {
  const env = await open(t); if (!env) return;
  const r = await get(throwing(env.DB, 'GROUP BY stage, lane_id, runner, billing_mode'));
  assert.equal(r.status, 500);
  assert.deepEqual(r.body, { error: 'llm-sites aggregate failed' });
});

test('R-readonly: a GET writes nothing', async (t) => {
  const env = await open(t); if (!env) return;
  row(env.db, { ts: ago(3), stage: 'triage', lane_id: 'alert-triage', cost_usd: 0.5 });
  setting(env.db, 'lane.alert-triage.llm_usd_cap_day', '5', 'console');
  const count = () => env.db.prepare('SELECT (SELECT COUNT(*) FROM cost_rows) AS c, (SELECT COUNT(*) FROM settings) AS s').get();
  const before = count();
  assert.equal((await get(env.DB)).status, 200);
  assert.deepEqual(count(), before);
});
