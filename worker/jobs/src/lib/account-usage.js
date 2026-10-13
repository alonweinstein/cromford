// account-usage — GET /api/metrics/account-usage (BH-167.0 contract, BH-167.1 compute).
//
// usageWindow picks the trailing window. shapeAccountUsage turns the route's
// cost_rows groups, project groups, meter snapshots and poll-span sums into one
// entry per auth_account, with the vendor meter joined as a cross-check. It is
// pure: every row it needs is an argument.

import { meterAccounts, anchorAccountState, anchorRound, numOrNull } from "./core.js";

/**
 * One entry of `accounts[]`.
 *
 * @typedef {object} AccountUsageEntry
 * @property {string|null} account
 * @property {number} calls
 * @property {number|null} usd            null when every row is unpriced, never 0
 * @property {number} unpriced_calls
 * @property {number} input_toks
 * @property {number} output_toks
 * @property {number} cache_read
 * @property {number} cache_write
 * @property {number} untokened_calls
 * @property {string|null} first_ts
 * @property {string|null} last_ts
 * @property {Array<{project: string|null, calls: number, usd: number|null, unpriced_calls: number,
 *   input_toks: number, output_toks: number, cache_read: number, cache_write: number}>} projects
 * @property {{label: string, session_pct: number|null, weekly_pct: number|null,
 *   weekly_resets_at: string|null, extra_used_usd: number|null, polls: number}|null} meter  polls counts meter READINGS; a failed poll is not one (BH-3985)
 * @property {{state: 'comparable', meter_delta_usd: number, rows_usd: number, unpriced_in_span: number,
 *   gap_usd: number, gap_pct: number, span_from: string, span_to: string}
 *   | {state: 'no-login'|'unmeasured', reason: string}} cross_check
 *   the no-login/unmeasured variant carries NO gap keys
 */

export const EMPTY_TRUNCATED = Object.freeze({ groups: false, projects: false, snapshots: false });

// 12h (BH-3985) is the span bin/extra-usage-track.sh holds a flat meter against.
const SPANS = { "5h": 5 * 3600e3, "12h": 12 * 3600e3, "7d": 168 * 3600e3 };
const isoZ = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");

/**
 * Trailing window ending at `now` (epoch ms), half-open [from, to). "5h", "12h"
 * and "7d" (168h) are the only windows; anything else resolves to "5h", and the
 * resolved name is echoed so a caller can see the fallback.
 */
export function usageWindow({ window, now }) {
  const w = Object.hasOwn(SPANS, window) ? window : "5h";
  return { window: w, from: isoZ(now - SPANS[w]), to: isoZ(now) };
}

const COUNTERS = ["calls", "unpriced_calls", "input_toks", "output_toks", "cache_read", "cache_write"];
const round2 = (n) => Math.round(n * 100) / 100;
// Counters are COUNT/COALESCE(SUM) columns, never NULL on a real read. Money is
// NOT read through this: usd stays null when no row was priced.
const count = (v) => Number(v) || 0;
// NULL, '' and whitespace-only are ONE "no account" key, never folded into a
// named account. Same normalisation as the route's NULLIF(TRIM(auth_account),'').
const accountKey = (a) => (a == null || String(a).trim() === "" ? null : String(a).trim());

function blank() {
  const a = { priced_calls: 0, priced_usd: 0, untokened_calls: 0, first_ts: null, last_ts: null };
  for (const c of COUNTERS) a[c] = 0;
  return a;
}

function add(a, r) {
  for (const c of COUNTERS) a[c] += count(r[c]);
  a.untokened_calls += count(r.untokened_calls);
  a.priced_calls += count(r.priced_calls);
  if (r.usd != null && Number.isFinite(Number(r.usd))) a.priced_usd += Number(r.usd);
  if (r.first_ts && (a.first_ts === null || r.first_ts < a.first_ts)) a.first_ts = r.first_ts;
  if (r.last_ts && (a.last_ts === null || r.last_ts > a.last_ts)) a.last_ts = r.last_ts;
}

// usd is the sum of PRICED rows, and null when the group has none: an
// all-unpriced account did not cost $0, its cost is unknown.
const usdOf = (a) => (a.priced_calls > 0 ? anchorRound(a.priced_usd) : null);

const byUsdDesc = (x, y) => (x.usd === null) - (y.usd === null) || (y.usd ?? 0) - (x.usd ?? 0);

// The vendor meter against our own rows for the same account over the same
// poll span. Comparability is decided by the METER alone: anchorAccountState's
// "no priced rows" guard protects the anchor's division BY rows, but the gap
// here divides by the meter delta, so rows of $0 (all unpriced, or none at all)
// are the largest possible gap, 100%, and must reach the alert (#2068 lead
// review). The rows argument is therefore a stand-in 1; its factor is unused.
function crossCheck(meter, span) {
  const s = anchorAccountState(meter, 1, Infinity);
  if (s.state !== "metered") return { state: s.state, reason: s.reason };
  const rows = anchorRound(span.usd ?? 0);
  const gap = meter.meter_delta_usd - rows;
  return {
    state: "comparable",
    meter_delta_usd: meter.meter_delta_usd,
    rows_usd: rows,
    unpriced_in_span: span.unpriced,
    gap_usd: round2(gap),
    gap_pct: round2((Math.abs(gap) / meter.meter_delta_usd) * 100),
    span_from: meter.span_from,
    span_to: meter.span_to,
  };
}

/**
 * One entry per auth_account over the window, heaviest first.
 *
 * @param {object} [input]
 * @param {Array<object>} [input.groups]  Read 1 rows: account, calls, priced_calls, usd
 *   (SUM(cost_usd), NULL when nothing is priced), unpriced_calls, the four token sums,
 *   untokened_calls, first_ts, last_ts
 * @param {Array<object>} [input.projects]  Read 2 rows: the same aggregates per
 *   (account, project), without first/last ts
 * @param {Array<object>} [input.snapshots]  Read 3 rows: extra_usage_snapshots in the window
 * @param {Object<string, {usd: number, unpriced: number}>} [input.spanSums]  per span
 *   candidate label, the priced sum and the unpriced count between its first and last poll
 * @param {Map<string, string>} [input.accountMap]  meter box -> account label (parseAccountMap)
 * @param {{groups: boolean, projects: boolean, snapshots: boolean}} [input.truncated]
 *   which read came back at its LIMIT; copied, defaults to all false
 * @param {"5h"|"12h"|"7d"} [input.window] the resolved window from usageWindow
 * @param {string} [input.from]
 * @param {string} [input.to]
 * @returns {{window: string, from: string, to: string, accounts: AccountUsageEntry[],
 *   totals: {calls: number, usd: number|null, unpriced_calls: number, input_toks: number,
 *   output_toks: number, cache_read: number, cache_write: number},
 *   truncated: {groups: boolean, projects: boolean, snapshots: boolean}}}
 */
export function shapeAccountUsage({
  groups = [], projects = [], snapshots = [], spanSums = {}, accountMap = new Map(),
  truncated = EMPTY_TRUNCATED, window, from, to,
} = {}) {
  const acc = new Map();
  for (const g of groups) {
    if (!g) continue;
    const k = accountKey(g.account);
    if (!acc.has(k)) acc.set(k, blank());
    add(acc.get(k), g);
  }

  const proj = new Map();
  for (const p of projects) {
    if (!p) continue;
    const k = accountKey(p.account);
    if (!proj.has(k)) proj.set(k, new Map());
    const per = proj.get(k);
    const name = p.project ?? null;
    if (!per.has(name)) per.set(name, blank());
    add(per.get(name), p);
  }

  const meters = new Map(meterAccounts({ snapshots, accountMap, from, to }).map((m) => [m.label, m]));
  for (const label of meters.keys()) if (!acc.has(label)) acc.set(label, blank());

  // meterAccounts carries the latest weekly_pct but not session_pct.
  const latest = new Map();
  for (const s of snapshots) {
    const label = s && accountMap.get(String(s.box ?? ""));
    const ts = s && String(s.ts ?? "");
    if (!label || !ts || ts < from || ts >= to) continue;
    if (!latest.has(label) || ts > String(latest.get(label).ts)) latest.set(label, s);
  }

  const accounts = [];
  for (const [account, a] of acc) {
    const m = account === null ? null : meters.get(account) || null;
    const last = m && latest.get(account);
    accounts.push({
      account,
      calls: a.calls,
      usd: usdOf(a),
      unpriced_calls: a.unpriced_calls,
      input_toks: a.input_toks,
      output_toks: a.output_toks,
      cache_read: a.cache_read,
      cache_write: a.cache_write,
      untokened_calls: a.untokened_calls,
      first_ts: a.first_ts,
      last_ts: a.last_ts,
      projects: [...(proj.get(account) || new Map())].map(([project, p]) => ({
        project, calls: p.calls, usd: usdOf(p), unpriced_calls: p.unpriced_calls,
        input_toks: p.input_toks, output_toks: p.output_toks,
        cache_read: p.cache_read, cache_write: p.cache_write,
      })).sort((x, y) => byUsdDesc(x, y)
        || (x.project === null) - (y.project === null) || String(x.project).localeCompare(String(y.project))),
      meter: m && {
        label: m.meter_box,
        session_pct: last ? numOrNull(last.session_pct) : null,
        weekly_pct: m.weekly_pct,
        weekly_resets_at: m.weekly_resets_at,
        extra_used_usd: m.extra_used_usd,
        polls: m.snapshots,
      },
      cross_check: crossCheck(m, (account !== null && spanSums[account]) || { usd: 0, unpriced: 0 }),
    });
  }
  accounts.sort((x, y) => byUsdDesc(x, y) || y.calls - x.calls
    || (x.account === null) - (y.account === null) || String(x.account).localeCompare(String(y.account)));

  const totals = { calls: 0, usd: null, unpriced_calls: 0, input_toks: 0, output_toks: 0, cache_read: 0, cache_write: 0 };
  for (const e of accounts) {
    for (const c of COUNTERS) totals[c] += e[c];
    if (e.usd !== null) totals.usd = (totals.usd ?? 0) + e.usd;
  }
  if (totals.usd !== null) totals.usd = anchorRound(totals.usd);

  return { window, from, to, accounts, totals, truncated: { ...EMPTY_TRUNCATED, ...truncated } };
}
