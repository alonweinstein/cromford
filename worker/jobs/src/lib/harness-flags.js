// harness_flags — the ported flag families' rows (BH-4153, BH-4141.1).
//
// For the names FLAG_PORTED_RE matches, the ROW is the truth: the box reads it
// first, falls back to a last-good cache, and writes no flags/ file. Every other
// flag name stays a pause_flags row with the BH-1370 file reconcile, untouched.
//
// FLAG_PORTED_RE is written on ONE line on purpose: tests/flags-db.bh-4153-test.sh
// sed-extracts the text between the slashes and compares it with the shell copy
// in bin/lib/jobs/flags.sh, so the two lists cannot drift.
//
// THE MIRROR: a fleet-scoped ported write also upserts the pause_flags row in
// the same batch (mirrorStmts), because checkPause and four other worker readers
// still read pause_flags. Box-scoped rows are not mirrored: no worker reader
// reads lanedown-* there. Wave 2 ports those readers and retires the mirror.

export const FLAG_PORTED_RE = /^(paused-.+|automerge-disabled|automerge-disabled-.+|lanedown-.+)$/;

// Flag names become file names under flags/ on every box (the non-ported ones
// still do), so the alphabet is the one that cannot escape that directory.
export const FLAG_NAME_RE = /^[A-Za-z0-9._-]+$/;
const SCOPE_RE = /^[A-Za-z0-9._-]{1,64}$/;

export const VALUE_MAX = 512;

export const isPortedFlag = (name) => FLAG_PORTED_RE.test(String(name || ""));

// 'fleet' when absent or empty, the scope when it is a box-name-shaped string,
// null (the caller's 400) otherwise.
export function validScope(s) {
  if (s === undefined || s === null || s === "") return "fleet";
  const v = String(s);
  return SCOPE_RE.test(v) ? v : null;
}

// A harness_flags row plus the legacy keys every pause_flags reader expects
// (flag_sync, /config, config-detail.js, lane-switch.sh): ON is active=1.
export function legacyShape(row) {
  if (!row) return null;
  const { scope, name, value, set_by, reason, set_at, cleared_at } = row;
  return {
    scope, name, value: value ?? null, set_by: set_by ?? null, reason: reason ?? null,
    set_at, cleared_at: cleared_at ?? null,
    active: cleared_at == null ? 1 : 0,
    actor: set_by ?? null,
    updated_at: cleared_at ?? set_at,
  };
}

// A pause_flags row in the same shape: fleet scope, no value, its one stamp
// standing for set_at (and for cleared_at when it is off). The original
// columns ride along unchanged.
export function projectPauseRow(row) {
  if (!row) return null;
  const on = Number(row.active) === 1;
  return {
    scope: "fleet", name: row.name, value: null, set_by: row.actor ?? null, reason: row.reason ?? null,
    set_at: row.updated_at, cleared_at: on ? null : row.updated_at,
    ...row,
  };
}

// The pause_flags upsert a fleet-scoped write carries, the legacy PUT's own SQL
// and binds. [] for any other scope.
export function mirrorStmts(env, { scope, name, active, actor, reason }, t) {
  if (scope !== "fleet") return [];
  return [
    env.DB.prepare(
      `INSERT INTO pause_flags (name, active, actor, reason, updated_at) VALUES (?1,?2,?3,?4,?5)
       ON CONFLICT(name) DO UPDATE SET active=?2, actor=COALESCE(?3, actor), reason=?4, updated_at=?5`
    ).bind(name, active ? 1 : 0, actor ?? null, reason ?? null, t),
  ];
}

// The current row of a ported name, in the full shape, or null. A fleet name
// with no harness_flags row yet falls back to its pause_flags row: that is the
// row the backfill would copy, so a worker running ahead of the backfill never
// answers "no row" for a pause that exists.
export async function readPortedFlag(env, scope, name) {
  const row = await env.DB.prepare("SELECT * FROM harness_flags WHERE scope=?1 AND name=?2").bind(scope, name).first();
  if (row) return legacyShape(row);
  if (scope !== "fleet") return null;
  const legacy = await env.DB.prepare("SELECT * FROM pause_flags WHERE name=?1").bind(name).first();
  return projectPauseRow(legacy);
}

// The harness_flags upsert. ON writes set_at=t, cleared_at=NULL; OFF keeps the
// stored set_at and writes cleared_at=t (a soft clear: the row is history).
export function upsertStmt(env, { scope, name, value, actor, reason, setAt, clearedAt }) {
  return env.DB.prepare(
    `INSERT INTO harness_flags (scope, name, value, set_by, reason, set_at, cleared_at) VALUES (?1,?2,?3,?4,?5,?6,?7)
     ON CONFLICT(scope, name) DO UPDATE SET value=?3, set_by=COALESCE(?4, set_by), reason=?5,
       set_at=CASE WHEN ?7 IS NULL THEN ?6 ELSE harness_flags.set_at END, cleared_at=?7`
  ).bind(scope, name, value ?? null, actor ?? null, reason ?? null, setAt, clearedAt ?? null);
}
