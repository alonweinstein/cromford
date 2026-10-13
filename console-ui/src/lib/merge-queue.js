// BH-3158 (BH-2325.3): the read side of the /merge-queue screen. Pure functions
// over useApi-shaped results ({data, error}), so the tests drive them directly.

// The worker clamps GET /api/merge-queue to 1..500 and orders by enqueued_at
// ASC, so a read that comes back at this length may be missing its NEWEST rows.
export const MQ_READ_LIMIT = 500;

// One read per status. Landed rows are history, not the queue, and are never read.
export const MQ_STATUSES = ['queued', 'blocked', 'dropped'];

const mqList = (res) => (res && !res.error && res.data && Array.isArray(res.data.merge_queue) ? res.data.merge_queue : null);

// A failed read (error, or no merge_queue array) is listed in `failed` and its
// rows are absent. It is never an empty list.
export function mqRows(...reads) {
  const rows = [];
  const capped = [];
  const failed = [];
  MQ_STATUSES.forEach((status, i) => {
    const list = mqList(reads[i]);
    if (!list) { failed.push(status); return; }
    if (list.length >= MQ_READ_LIMIT) capped.push(status);
    rows.push(...list);
  });
  return { rows, capped, failed };
}

const parse = (s) => {
  if (s === null || s === undefined) return undefined;
  try { return JSON.parse(s); } catch { return undefined; }
};
const statusOf = (v) => (v && typeof v === 'object' && v.status !== null && v.status !== undefined ? String(v.status) : '—');

function changeText(c) {
  const after = parse(c.after_json);
  if (c.kind === 'held_page' && after === null) return 'released';
  return `${statusOf(parse(c.before_json))} → ${statusOf(after)}`;
}

const AUDIT_KINDS = ['merge_queue', 'held_page'];

// Both audit kinds, merged newest first (at, then id). A kind whose read failed
// is named in `failed`; a kind the worker truncated is named in `truncated`.
export function auditRows(mqChanges, heldChanges) {
  const rows = [];
  const failed = [];
  const truncated = [];
  [mqChanges, heldChanges].forEach((res, i) => {
    const kind = AUDIT_KINDS[i];
    const list = res && !res.error && res.data && Array.isArray(res.data.changes) ? res.data.changes : null;
    if (!list) { failed.push(kind); return; }
    if (res.data.truncated) truncated.push(kind);
    for (const c of list) rows.push({ ...c, kind: c.kind || kind, what: `${c.kind || kind} ${c.name ?? ''}`.trim(), change: changeText({ ...c, kind: c.kind || kind }) });
  });
  rows.sort((a, b) => (String(b.at || '').localeCompare(String(a.at || ''))) || (Number(b.id) || 0) - (Number(a.id) || 0));
  return { rows, failed, truncated };
}

// The same test as _flag_on_row in bin/lib/jobs/queue.sh: 1|on|true|yes, trimmed
// and lowercased. A failed read is 'unread', never 'off'.
export function rowsOnlyState(res) {
  if (!res || res.error || !res.data) return 'unread';
  const s = res.data.setting;
  if (!s) return 'off';
  return ['1', 'on', 'true', 'yes'].includes(String(s.value ?? '').trim().toLowerCase()) ? 'on' : 'off';
}

const errText = (r) => String(r && r.error ? r.error.message || r.error : 'no answer');

// What the boxes do in each state, per bin/merge-queue.sh and queue.sh.
export function rowsOnlyBanner(state, res) {
  if (state === 'on') {
    return "Rows-only is ON: the queued rows plus any queue files still on disk are the queue, minus blocked rows and .blocked files. If a box can't read the rows, it falls back to its files for that tick.";
  }
  if (state === 'unread') return `Rows-only setting unreadable: ${errText(res)}. What each box is doing isn't known from here.`;
  if (res && res.data && !res.data.setting) {
    return "No merge_queue_rows_only row. Each box uses its own MERGE_QUEUE_ROWS_ONLY env, default off, which this console can't see.";
  }
  return "Rows-only is OFF: each box's queue directory is the queue, and queued rows are copied into it as files.";
}
