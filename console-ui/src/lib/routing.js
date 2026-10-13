// The ROUTING section of /p/<project> (BH-2328): the project's routing row
// (worker/jobs/src/routes/routing.js), whether the `routing_rows` knob makes
// that row the actual routing, and its routing_changes audit trail.
//
// A failed read is never shown as a state it did not report: a row read that
// failed is an error, not "not halted", and a knob read that failed is
// unknown (null), not "off".

// A rendering bound, not a data one (as PIPELINE_SHIPPED_LIMIT): the worker
// says `truncated` when older rows exist, and the panel says so.
export const ROUTING_CHANGES_LIMIT = 50;

const NA = '—';

// true / false / null from a useApi-shaped `{data, error}` of
// GET /api/settings/routing_rows. The box reads the value exact "on"
// (bin/lib/jobs/routing.sh routing_rows_on), and a missing row is the seeded
// default, off.
function rowsOnFrom(knob) {
  if (!knob || knob.error || !knob.data) return null;
  if (!('setting' in knob.data)) return null;
  const s = knob.data.setting;
  if (s === null) return false;
  if (!s || typeof s.value !== 'string') return null;
  return s.value === 'on';
}

// row: useApi-shaped `{data, error}` of GET /api/routing/<p>. The latest read
// decides: useApi clears `error` on success, so an error here means the row
// as it is NOW is not known, whatever an earlier poll said.
export function routingState(row, knob) {
  const rowsOn = rowsOnFrom(knob);
  if (row && row.error) {
    if (row.error.status === 404) return { kind: 'none', rowsOn };
    return { kind: 'error', error: row.error, rowsOn };
  }
  if (row && row.data && row.data.routing) return { kind: 'row', row: row.data.routing, rowsOn };
  if (row && row.data) return { kind: 'error', error: new Error('bad response'), rowsOn };
  return { kind: 'loading', rowsOn };
}

// The PUT body for a HALT or UNHALT: project, halted and reason, nothing else.
// builder and pool_app are never sent: the coord proxy copies them from the
// worker's current row, so this write cannot re-route anything. It carries no
// actor either (the proxy stamps it). A blank HALT reason gets a default; a
// blank UNHALT reason stays blank, and haltAction refuses it before any call.
export function haltBody(fresh, wantHalted, reason) {
  const r = typeof reason === 'string' ? reason.trim() : '';
  return {
    project: fresh.project,
    halted: wantHalted ? 1 : 0,
    reason: wantHalted ? (r || 'HALT from Mission Control') : r
  };
}

// The confirm dialog's gate: an UNHALT lifts a halt someone set on purpose,
// so it needs a reason; a HALT may take the default.
export function haltFormState(target, reason) {
  const blank = typeof reason !== 'string' || !reason.trim();
  const blocked = !target && blank;
  return { blocked, hint: blocked ? 'an UNHALT needs a reason: say why this halt can be lifted' : '' };
}

// Who set the current halt and why: the newest routing_changes row that moved
// halted to 1 (a row created halted counts; a later write that kept it at 1 is
// not the halt). {found:false, why} when the loaded log does not say.
export function currentHalt(changes) {
  if (!changes || !changes.data) {
    return { found: false, why: changes && changes.error ? 'the change log could not be read' : 'the change log is still loading' };
  }
  const list = Array.isArray(changes.data.changes) ? [...changes.data.changes] : [];
  list.sort((a, b) => Number(b.id) - Number(a.id));
  const hit = list.find((c) => Number(c.after_halted) === 1
    && (c.before_halted === null || c.before_halted === undefined || Number(c.before_halted) !== 1));
  if (!hit) return { found: false, why: `not in the newest ${ROUTING_CHANGES_LIMIT} changes` };
  return { found: true, actor: hit.actor ?? null, reason: hit.reason ?? null, at: hit.at ?? null };
}

// Why the toggle is off, or null when it is live.
export function haltDisabledReason(state) {
  if (state.kind === 'loading') return 'routing is loading';
  if (state.kind === 'error') return 'routing could not be read';
  if (state.kind === 'none') return 'no routing row for this project; seed it with routing-seed-rows.sh --apply';
  if (state.rowsOn === false) return 'routing_rows is off: rows do not drive flags/ yet, so a HALT here would stop nothing';
  if (state.rowsOn !== true) return 'could not read routing_rows';
  return null;
}

const shown = (v) => (v === null || v === undefined || v === '' ? NA : String(v));

// One routing_changes row, flattened for the table. A null before_builder is
// the row's first write (a row always has a builder), so every field reads
// "(new) → x"; otherwise a changed field is "before → after" and an unchanged
// one is its value.
export function changeCells(c) {
  const isNew = c.before_builder === null || c.before_builder === undefined;
  const cell = (field) => {
    const after = shown(c[`after_${field}`]);
    if (isNew) return `(new) → ${after}`;
    const before = shown(c[`before_${field}`]);
    return before === after ? after : `${before} → ${after}`;
  };
  return {
    at: c.at,
    actor: shown(c.actor),
    reason: shown(c.reason),
    builder: cell('builder'),
    pool_app: cell('pool_app'),
    halted: cell('halted')
  };
}

// The toggle's write: re-read the row, send nothing if it already says what
// was asked, else PUT haltBody over the fresh row. The outcome is read from
// the row the worker returns, never assumed. A 409 means the row moved since
// the re-read (BH-2488): it is reported as a conflict and never retried, and
// the caller reloads the row. Returns {ok, text[, conflict]}.
export async function haltAction({ apiObj, project, target, reason }) {
  const label = target ? 'HALT' : 'UNHALT';
  const want = target ? 1 : 0;
  if (haltFormState(target, reason).blocked) return { ok: false, text: `${label} refused — a reason is required` };
  let fresh;
  try {
    fresh = (await apiObj.routing(project)).routing;
  } catch (e) {
    return { ok: false, text: `${label} refused — could not re-read the routing row: ${e.message}` };
  }
  if (!fresh) return { ok: false, text: `${label} refused — could not re-read the routing row: bad response` };
  if (Number(fresh.halted) === want) return { ok: true, text: target ? 'already halted' : 'already running' };
  let res;
  try {
    res = await apiObj.putRouting(haltBody(fresh, target, reason));
  } catch (e) {
    if (e && e.status === 409) return { ok: false, conflict: true, text: `${label} refused — routing changed underneath you, try again` };
    return { ok: false, text: `${label} refused — ${e.message}` };
  }
  const now = res && res.routing ? Number(res.routing.halted) : NaN;
  if (now !== want) {
    return { ok: false, text: `${label} sent, but the worker's row says halted=${Number.isNaN(now) ? 'unknown' : now}` };
  }
  return {
    ok: true,
    text: target
      ? `${project} halted; each box stops new pool spawns at its next routing sync`
      : `${project} unhalted; pool spawns resume at each box's next routing sync`
  };
}
