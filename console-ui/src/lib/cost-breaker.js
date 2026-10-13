import { settingKey } from './settings.js';

// BH-2331: the COST BREAKER section's shaping. Pure, so the tests can feed it
// the payloads the worker returns and the section only lays them out.

// The registry default for COST_AUTOHALT (catalog/lanes.d/pipeline-health.json).
// It applies when no settings row exists, and it is what bin/pipeline-health.sh's
// cb_knob falls back to for a value that is not a number. BH-2397: only the
// fallback for "the hub has not published cost.autohalt.effective yet".
export const AUTOHALT_DEFAULT_ON = true;
export const AUTOHALT_KEY = settingKey('pipeline-health', 'COST_AUTOHALT');
// BH-2397: what the autohalt actually does on the hub, written by
// bin/pipeline-health.sh there as `on|off <flag-file|settings|env|default>`.
// It sees what this page cannot: the env and the hub's flags/cost-autohalt-off.
export const AUTOHALT_EFFECTIVE_KEY = 'cost.autohalt.effective';
const EFFECTIVE_RE = /^(on|off) (flag-file|settings|env|default)$/;

// GET /api/call-guard answers at most this many keys and carries no truncated
// flag, so a full page is read as "there may be more".
export const GUARD_LIMIT = 200;

// cb_halt in bin/pipeline-health.sh writes exactly these two suffixes. Anything
// else on a spend-hold-<p> or paused-<p> row is someone else's.
const AUTOHALT_SUFFIXES = ['(cost autohalt)', '(zero-merge breaker)'];

export function isAutohaltReason(reason) {
  if (typeof reason !== 'string') return false;
  const r = reason.trim();
  return AUTOHALT_SUFFIXES.some((s) => r.endsWith(s));
}

// BH-5526: the breaker writes spend-hold-<p> (it holds new builds only).
// paused-<p> rows with a breaker reason are from before that change, and are
// still listed, as kind 'pause'. <prefix>-all, -box-<b> and -lane-<l> are not
// projects.
const PROJECT_FLAG_RE = /^(paused|spend-hold)-(.+)$/;
const NOT_A_PROJECT_RE = /^(?:paused|spend-hold)-(all$|box-|lane-)/;

export function autohaltTrips(payload) {
  if (!payload || !Array.isArray(payload.flags)) return { trips: [], unreadable: true };
  const trips = [];
  for (const f of payload.flags) {
    if (!f || (f.active !== 1 && f.active !== '1')) continue;
    const name = String(f.name || '');
    const m = PROJECT_FLAG_RE.exec(name);
    if (!m || NOT_A_PROJECT_RE.test(name)) continue;
    if (!isAutohaltReason(f.reason)) continue;
    trips.push({
      project: m[2], kind: m[1] === 'spend-hold' ? 'hold' : 'pause',
      reason: f.reason.trim(), since: f.updated_at || null, actor: f.actor || null
    });
  }
  return { trips, unreadable: false };
}

// What the breaker will do. `on: null` is "could not read", never ON: the
// settings read failing is not the default applying. The hub's published row
// wins; a malformed one is UNKNOWN rather than a guess. With no hub row the
// settings row / registry default is read as before (source settings|default).
export function autohaltState(payload) {
  if (!payload || !Array.isArray(payload.settings)) return { on: null, source: null, raw: null };
  const hub = payload.settings.find((s) => s && String(s.key).toLowerCase() === AUTOHALT_EFFECTIVE_KEY);
  if (hub) {
    const raw = hub.value === null || hub.value === undefined ? '' : String(hub.value).trim();
    const m = EFFECTIVE_RE.exec(raw);
    if (!m) {
      return {
        on: null, source: 'hub', raw,
        note: `the hub published "${raw}" for ${AUTOHALT_EFFECTIVE_KEY}, which is not on|off <source>`
      };
    }
    return { on: m[1] === 'on', source: 'hub', why: m[2], asOf: hub.updated_at || null, raw };
  }
  const row = payload.settings.find((s) => s && String(s.key).toLowerCase() === AUTOHALT_KEY);
  if (!row || row.value === null || row.value === undefined) {
    return { on: AUTOHALT_DEFAULT_ON, source: 'default', raw: null };
  }
  const raw = String(row.value).trim();
  // Same test as cb_knob: only digits and dots are a value; anything else is
  // ignored there and the default applies, so the card says that.
  if (raw === '' || /[^0-9.]/.test(raw)) {
    return {
      on: AUTOHALT_DEFAULT_ON, source: 'default', raw,
      note: `the settings row holds "${raw}", which pipeline-health ignores, so the default applies`
    };
  }
  return { on: raw !== '0', source: 'settings', raw };
}

const num = (v) => {
  const n = Number(v);
  return v === null || v === undefined || v === '' || !Number.isFinite(n) ? null : n;
};

export function callGuardRows(payload) {
  if (!payload || !Array.isArray(payload.rows)) return { rows: [], capped: false, unreadable: true };
  const rows = payload.rows.map((r) => {
    const refused = num(r.refused);
    // BH-2397: CAP HIT follows the refusals since the last RESET. A worker that
    // predates the field sends none, and then the total decides, as before.
    const refusedSinceReset = num(r.refused_since_reset);
    const live = refusedSinceReset ?? refused;
    return {
      key: `${r.project}|${r.stage}|${r.fp}`,
      project: r.project, stage: r.stage, fp: r.fp,
      paid: num(r.paid), refused, refusedSinceReset, resetAt: r.reset_at || null, lastAt: r.last_at || null,
      capHit: live !== null && live > 0
    };
  });
  return { rows, capped: rows.length >= GUARD_LIMIT, unreadable: false };
}

export function resetFormState(reason) {
  const blank = typeof reason !== 'string' || !reason.trim();
  return { blocked: blank, hint: blank ? 'say why this key may be paid for again' : '' };
}

// The RESET click, as a factory so the tests drive the same code the section
// runs. `confirm` is useConfirm's; `form` is a fresh object per click that the
// modal's reason input writes through. Nothing is reported as reset unless the
// worker answered with a count.
export function makeResetAction({ confirm, reset, reload, onMsg, onPending, renderForm }) {
  const inFlight = new Set();
  return async (row) => {
    if (inFlight.has(row.key)) return;
    const form = { reason: '' };
    const ok = await confirm({
      title: 'RESET CALL GUARD', confirmLabel: 'RESET', tone: 'danger',
      confirmBlocked: resetFormState(form.reason).blocked,
      form,
      body: renderForm ? ({ setBlocked }) => renderForm(row, form, setBlocked) : null
    });
    if (!ok) return;
    const reason = typeof form.reason === 'string' ? form.reason.trim() : '';
    if (resetFormState(reason).blocked) {
      onMsg({ ok: false, text: 'RESET refused — a reason is required' });
      return;
    }
    inFlight.add(row.key);
    if (onPending) onPending(row.key);
    try {
      const res = await reset({ project: row.project, stage: row.stage, fp: row.fp, reason });
      if (!res || typeof res.reset !== 'number') {
        onMsg({ ok: false, text: `RESET for ${row.project}/${row.stage} answered without a count — check the guard table` });
        return;
      }
      onMsg({ ok: true, text: `reset ${res.reset} paid row(s) for ${row.project}/${row.stage}` });
      reload();
    } catch (e) {
      onMsg({ ok: false, text: `RESET failed — ${e && e.message ? e.message : String(e)}` });
    } finally {
      inFlight.delete(row.key);
      if (onPending) onPending(null);
    }
  };
}
