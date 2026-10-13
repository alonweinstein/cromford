// llm-sites — BH-2554 (BH-2540.1): one row per catalog LLM site, resolved from
// the cost_rows GROUP BY, the settings rows and the registry the deploy baked
// in. Pure: routes/llm-sites.js does the reads and hands them over.

import { siteAttribution } from "./llm-sites-catalog.js";
import { REGISTRY_SEED_ACTOR } from "./core.js";

const MAP_TOKEN = /^[a-z0-9._-]+=\d+$/;
const tokens = (s) => String(s ?? "").split(/[\s,]+/).filter(Boolean);

// CALL_GUARD_MAX_MAP: `stage=K` pairs, `default=` for the rest. `ok` is false
// when any token is not a stage=K pair (bin/lib/call-guard.sh would skip it or
// switch the stage off; this page reports the registry value and says so).
export function parseGuardMap(s) {
  const map = {};
  let ok = true;
  for (const w of tokens(s)) {
    if (!MAP_TOKEN.test(w)) { ok = false; continue; }
    const i = w.indexOf("=");
    map[w.slice(0, i)] = Number(w.slice(i + 1));
  }
  return { map, ok };
}

// CALL_GUARD_STAGES: a list, `all`, or `none` (`none` wins, as in call-guard.sh).
export function guardStagesSet(s) {
  const list = tokens(s);
  if (list.includes("none")) return () => false;
  if (list.includes("all")) return () => true;
  return (st) => list.includes(st);
}

// Min positive context_kill_tokens over project-less budget entries whose
// stage is one of `stages`; null when none match.
export function killTokensFor(budgets, stages) {
  let min = null;
  for (const l of budgets?.lanes || []) {
    if ("project" in l || !stages.includes(l.stage)) continue;
    const k = l.context_kill_tokens;
    if (Number.isInteger(k) && k > 0 && (min === null || k < min)) min = k;
  }
  return min;
}

function money() { return { by_runner: {}, total: 0 }; }
function addMoney(m, runner, usd) {
  if (usd == null) return;
  const r = runner ?? "unknown";
  m.by_runner[r] = (m.by_runner[r] || 0) + usd;
  m.total += usd;
}

export function siteRows({ sites, agg, settings, registry, budgets }) {
  const incomplete = [];
  const flag = (k) => { if (!incomplete.includes(k)) incomplete.push(k); };
  if (settings === null) flag("settings");

  // A registry-seed row is the DB's copy of the default, not an operator value
  // (the rule routes/lanes.js applies inline; restated, not imported).
  const own = new Map();
  for (const r of settings || []) if (r.actor !== REGISTRY_SEED_ACTOR) own.set(r.key, r);

  const guardLib = (registry.libs || []).find((l) => l.id === "call-guard");
  const guardDefault = (env) => guardLib?.knobs?.find((k) => k.env === env)?.default;
  let guardMap = parseGuardMap(guardDefault("CALL_GUARD_MAX_MAP")).map;
  const mapRow = own.get("lib.call-guard.call_guard_max_map");
  if (mapRow) {
    const p = parseGuardMap(mapRow.value);
    if (p.ok) guardMap = p.map; else flag("guard_k");
  }
  const stagesRow = own.get("lib.call-guard.call_guard_stages");
  const enforced = guardStagesSet(stagesRow ? stagesRow.value : guardDefault("CALL_GUARD_STAGES"));

  const out = sites.map((site) => {
    const a = siteAttribution(site, sites);
    const none = a.attribution === "none";
    const groups = none ? [] : agg.filter((g) => a.all || (a.stages.includes(g.stage)
      && (a.attribution !== "lane" || g.lane_id === a.lane || g.lane_id == null)));

    const usd_24h = money(), usd_7d = money();
    let cash = 0, notional = 0, unknown = 0, today = 0, unpriced = 0, calls = 0;
    const refused_7d = { gate: 0, guard: 0, context_kill: 0 };
    for (const g of groups) {
      addMoney(usd_24h, g.runner, g.usd_24h);
      addMoney(usd_7d, g.runner, g.usd_7d);
      if (g.usd_7d != null) {
        if (g.billing_mode === "metered") cash += g.usd_7d;
        else if (g.billing_mode === "subscription") notional += g.usd_7d;
        else unknown += g.usd_7d;
      }
      if (g.usd_today != null) today += g.usd_today;
      unpriced += Number(g.unpriced) || 0;
      calls += Number(g.calls) || 0;
      refused_7d.gate += Number(g.r_gate) || 0;
      refused_7d.guard += Number(g.r_guard) || 0;
      refused_7d.context_kill += Number(g.r_ctx) || 0;
    }

    const regLane = a.lane ? (registry.lanes || []).find((l) => l.id === a.lane) : null;
    const laneKnobs = regLane?.knobs || [];
    let guard_k = null, guard_enforced = null, cap_usd_day = null, knobs_bound = null;
    if (settings !== null) {
      if (a.stages.length) {
        guard_k = guardMap[a.stages[0]] ?? guardMap.default ?? null;
        guard_enforced = a.stages.some(enforced);
      }
      const capKnob = laneKnobs.find((k) => k.env === "LLM_USD_CAP_DAY");
      if (capKnob) {
        const r = own.get(`lane.${a.lane}.llm_usd_cap_day`);
        const v = r && String(r.value).trim() !== "" ? Number(r.value) : NaN;
        if (r && !Number.isFinite(v)) flag("cap_usd_day");
        cap_usd_day = Number.isFinite(v) ? v : Number(capKnob.default);
      }
      knobs_bound = laneKnobs.filter((k) => k.env.startsWith("LLM_") && own.has(`lane.${a.lane}.${k.env.toLowerCase()}`)).map((k) => k.env);
    }
    const kill_tokens = killTokensFor(budgets, a.stages);

    return {
      id: site.id, lane: site.lane, stage: site.stage, stages: a.stages, kind: site.kind,
      runners: site.runners, script: site.script, note: site.note,
      attribution: a.attribution, shared: a.shared,
      usd_24h: none ? null : usd_24h, usd_7d: none ? null : usd_7d,
      cash_7d: none ? null : cash, notional_7d: none ? null : notional,
      unknown_billing_7d: none ? null : unknown, unpriced_7d: unpriced, calls_7d: calls,
      refused_7d, today_usd: none ? null : today,
      guard_k, guard_enforced, kill_tokens, cap_usd_day, knobs_bound,
      badges: {
        no_row: calls === 0,
        no_knob: !laneKnobs.some((k) => ["LLM_LANE_ENABLED", "LLM_RUNNER_ALLOWED", "LLM_USD_CAP_DAY"].includes(k.env)),
        no_kill: kill_tokens === null,
      },
    };
  });
  return { sites: out, incomplete };
}
