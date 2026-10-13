// The pure half of the console registry-seed apply (BH-2521.2). The routes are
// in ../routes/settings.js; nothing here touches D1.

// Documented fallbacks for the settings rows `seed_gate_tick_window_s` and
// `seed_gate_max_age_s` (a row wins when it is a positive int). The same
// numbers as bin/harness-ctl.sh `_seed_gate`, so the console and the CLI refuse
// the same fleet.
export const SEED_GATE_TICK_WINDOW_S = 86400;
export const SEED_GATE_MAX_AGE_S = 7200;

const byCodeUnit = (a, b) => (a < b ? -1 : a > b ? 1 : 0);

// planFingerprint(plan) -> 64 lowercase hex: SHA-256 of the canonical JSON of
// what the seed would write. `prune` comes from an unordered SELECT, so every
// list is sorted (code-unit order, not localeCompare, so no runtime's locale
// can move it). Counts are left out: they follow from the lists.
export async function planFingerprint(plan) {
  const canon = {
    insert: [...(plan.insert || [])].sort(byCodeUnit),
    update: (plan.update || []).map(({ key, from, to }) => ({ key, from, to }))
      .sort((a, b) => byCodeUnit(a.key, b.key)),
    prune: [...(plan.prune || [])].sort(byCodeUnit),
  };
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify(canon)));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// fleetGateVerdict({ticks, boxes, nowS, maxAgeS}) -> {ok, bad:[{box, reason}]}.
// `ticks` is every box that ticked a lane inside the window (those are the
// boxes that read settings rows); `boxes` is box_status. Mirrors the CLI's
// `_seed_gate_box` minus its git-ancestry check, which needs a checkout the
// worker does not have. A box_status row with no tick is not checked (a
// CLI-sweep alias or a retired box), same as the CLI.
export function fleetGateVerdict({ ticks, boxes, nowS, maxAgeS }) {
  const names = [...new Set(ticks || [])].sort(byCodeUnit);
  if (!names.length) return { ok: false, bad: [{ box: "-", reason: "no box ticked a lane in the window" }] };
  const rows = new Map((boxes || []).map((b) => [b.box, b]));
  const bad = [];
  for (const box of names) {
    const r = rows.get(box);
    const commit = r?.harness_commit, at = r?.harness_reported_at;
    if (!commit || !at) {
      bad.push({ box, reason: "ticks lanes but never reported a harness commit" });
      continue;
    }
    const ms = Date.parse(at);
    if (Number.isNaN(ms)) { bad.push({ box, reason: `unreadable report time '${at}'` }); continue; }
    const age = nowS - Math.floor(ms / 1000);
    if (age > maxAgeS) bad.push({ box, reason: `last reported ${age}s ago (stale, limit ${maxAgeS}s)` });
  }
  return { ok: bad.length === 0, bad };
}
