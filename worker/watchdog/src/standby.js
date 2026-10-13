/**
 * Warm-standby hub contract (BH-401, issue #1920). Pure read helpers; nothing
 * here writes KV.
 *
 * KV layout:
 *   standby:<box>     {ts, of, snapshot, ok}
 *     ts        ms epoch, stamped by the watchdog when the standby reports
 *     of        the hub the standby streams from
 *     snapshot  id of the last snapshot it applied, YYYYMMDDTHHMMSSZ (UTC)
 *     ok        boolean, the standby's own health verdict
 *   The standby POSTs {of, snapshot, ok}; the watchdog adds ts.
 *
 *   failover:<epoch>  {ts, from, to, result}
 *     result    "pending" | "promoted" | "failed:<status>"
 *   30-day TTL, written by the failover child of #401.
 */

export const STANDBY_PREFIX = "standby:";
export const standbyKey = (box) => `${STANDBY_PREFIX}${box}`;
export const failoverKey = (epoch) => `failover:${epoch}`;

const SNAPSHOT_RE = /^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$/;

// Whole minutes since a snapshot id. null for anything unparseable (including
// calendar-invalid ids like month 13), never 0 and never NaN.
export function snapshotAgeMin(id, nowMs) {
  if (typeof id !== "string") return null;
  const m = SNAPSHOT_RE.exec(id);
  if (!m) return null;
  const [y, mo, d, h, mi, s] = m.slice(1).map(Number);
  const t = Date.UTC(y, mo - 1, d, h, mi, s);
  const dt = new Date(t);
  if (dt.getUTCFullYear() !== y || dt.getUTCMonth() !== mo - 1 || dt.getUTCDate() !== d ||
      dt.getUTCHours() !== h || dt.getUTCMinutes() !== mi || dt.getUTCSeconds() !== s) return null;
  if (!Number.isFinite(nowMs)) return null;
  return Math.floor((nowMs - t) / 60000);
}

// Every standby:<box> row, following KV cursors to the end. A value that is not
// a JSON object is skipped.
export async function listStandbys(env, nowMs) {
  const rows = [];
  let cursor;
  for (;;) {
    const page = await env.KV.list({ prefix: STANDBY_PREFIX, ...(cursor ? { cursor } : {}) });
    for (const { name } of page.keys) {
      let v;
      try { v = JSON.parse(await env.KV.get(name)); } catch { continue; }
      if (!v || typeof v !== "object" || Array.isArray(v)) continue;
      rows.push({
        box: name.slice(STANDBY_PREFIX.length),
        of: v.of,
        snapshot: v.snapshot,
        ok: v.ok === true,
        report_age_min: Number.isFinite(v.ts) && Number.isFinite(nowMs) ? Math.floor((nowMs - v.ts) / 60000) : null,
        stream_age_min: snapshotAgeMin(v.snapshot, nowMs),
      });
    }
    if (page.list_complete || !page.cursor) break;
    cursor = page.cursor;
  }
  return rows;
}
