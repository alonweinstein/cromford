// The standby heartbeat rows of the HUB screen (BH-2641 / BH-2519.3). Pure:
// reads the `standbys` array and `role.standby` from the GET /api/hub/recovery
// answer the page already holds, and never fetches.

export const STANDBY_CONTRACT_ERROR = 'standbys_missing';

const SNAPSHOT_RE = /^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$/;

// Whole minutes since a snapshot id, YYYYMMDDTHHMMSSZ (UTC). The same rule as
// the watchdog's snapshotAgeMin (worker/watchdog/src/standby.js), copied
// because console-ui cannot import from that package: null for anything
// unparseable, including calendar-invalid ids like month 13, never 0 or NaN.
export function snapshotAgeMin(id, nowMs) {
  if (typeof id !== 'string') return null;
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

// Whole minutes since an ISO-8601 report stamp; null when it does not parse.
export function reportAgeMin(iso, nowMs) {
  if (typeof iso !== 'string' || iso === '') return null;
  const t = Date.parse(iso);
  if (!Number.isFinite(t) || !Number.isFinite(nowMs)) return null;
  return Math.max(0, Math.floor((nowMs - t) / 60000));
}

// [{box, ofHub, snapshot, ok, reportedAt, reportAgeMin, streamAgeMin}], or
// {error: STANDBY_CONTRACT_ERROR, standby} when the answer names standby boxes
// but carries no rows for them: a contract break never reads as "no standby".
// `ok` is true only for 1/true; an unknown stream never reads healthy.
export function standbyRows(recovery, now) {
  const list = recovery && recovery.standbys;
  if (!Array.isArray(list)) {
    const named = recovery && recovery.role && recovery.role.standby;
    return Array.isArray(named) && named.length ? { error: STANDBY_CONTRACT_ERROR, standby: named } : [];
  }
  return list
    .filter((r) => r && typeof r === 'object' && !Array.isArray(r))
    .map((r) => ({
      box: r.box,
      ofHub: r.of_hub ?? null,
      snapshot: r.snapshot ?? null,
      ok: r.ok === 1 || r.ok === true,
      reportedAt: r.reported_at ?? null,
      reportAgeMin: reportAgeMin(r.reported_at, now),
      streamAgeMin: snapshotAgeMin(r.snapshot, now),
    }));
}
