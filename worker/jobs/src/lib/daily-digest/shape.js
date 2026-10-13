// daily-digest shape — BH-3703 (BH-3688 slice 1): the pure helpers every
// digest slice shares. No imports, no clock: the route passes its `t` in.

const DAY_RE = /^\d{4}-\d{2}-\d{2}$/;

// The eleven section keys, split by the reader module that answers them.
export const SECTION_KEYS = {
  core: ["throughput", "spend", "autonomy"],
  state: ["tripwires", "self_heals", "holds", "human_verdict_prs", "model_watch", "spotcheck_candidates", "factory", "pr_health", "past_sla"],
};

// [day, day+1) in UTC, or null for a malformed, unreal or future day. Today
// itself is allowed (a partial day).
export function dayWindow(day, nowIso) {
  if (typeof day !== "string" || !DAY_RE.test(day)) return null;
  const [y, m, d] = day.split("-").map(Number);
  const start = new Date(Date.UTC(y, m - 1, d));
  if (start.toISOString().slice(0, 10) !== day) return null;
  const now = typeof nowIso === "string" ? new Date(nowIso) : null;
  if (!now || Number.isNaN(now.getTime())) return null;
  if (day > now.toISOString().slice(0, 10)) return null;
  const next = new Date(Date.UTC(y, m - 1, d + 1)).toISOString().slice(0, 10);
  return { day, from: `${day}T00:00:00Z`, to: `${next}T00:00:00Z` };
}

export function capList(rows, limit) {
  if (!Array.isArray(rows)) throw new TypeError("capList: rows must be an array");
  return { rows: rows.slice(0, limit), truncated: rows.length > limit };
}

// True only when every section read fine AND every counter is a real 0
// (self_heals is read but not counted: a fix the harness made is quiet). A
// missing or non-number counter is not zero, so it is never "empty", and a
// stale stuck-work snapshot's 0 is not a quiet day either.
export function isEmptyDigest(d) {
  if (!d || typeof d !== "object") return false;
  const keys = [...SECTION_KEYS.core, ...SECTION_KEYS.state];
  if (!keys.every((k) => d[k]?.ok === true)) return false;
  const a = d.autonomy;
  return [
    d.throughput?.merged, d.spend?.calls,
    a?.batch_dequeues?.n, a?.manual_requeues?.n, a?.rebuild_loops?.n, a?.rebuild_loops?.abandoned,
    a?.human_interventions?.n, d.tripwires?.n, d.holds?.n,
    d.model_watch?.rows?.length, d.spotcheck_candidates?.rows?.length, d.pr_health?.rows?.length, d.past_sla?.total,
  ].every((n) => n === 0) && d.past_sla?.stale !== true;
}

export function notBuilt() {
  return { ok: false, error: "not built yet (BH-3688)" };
}

// Runs one reader. A throw makes every one of its keys {ok:false,error}; a key
// the reader left out is {ok:false} too, so a section is never silently absent.
export async function guardSections(keys, fn) {
  let got;
  try {
    got = await fn();
  } catch (err) {
    const error = String(err?.message || err);
    return Object.fromEntries(keys.map((k) => [k, { ok: false, error }]));
  }
  return Object.fromEntries(keys.map((k) => [k, got?.[k] ?? { ok: false, error: "section missing from reader" }]));
}
