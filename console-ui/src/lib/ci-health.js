// BH-2634: the /ci screen's shaping. Pure, so the tests feed it the payloads
// the worker returns and the screen only lays them out. Each read is passed as
// its parsed payload, or null when it failed: a failed read is `unread`, never
// zero, and a read that worked but holds no row for a repo is `absent`.

// The window the FLAKES 7D column counts, and the most rows GET
// /api/metrics/flakes answers (the worker's own max, no cursor).
export const FLAKE_WINDOW_DAYS = 7;
export const FLAKES_LIMIT = 2000;

export const sinceDay = (now, days) => new Date(now - days * 86400000).toISOString().slice(0, 10);

const num = (v) => ((typeof v === 'number' || (typeof v === 'string' && v.trim() !== '')) && Number.isFinite(Number(v)) ? Number(v) : null);
const list = (payload, key) => (payload && Array.isArray(payload[key]) ? payload[key] : null);
const isActive = (r) => r.active === 1 || r.active === '1' || r.active === true;
const payloadOf = (r) => {
  if (typeof r.payload !== 'string') return r.payload || {};
  try { return JSON.parse(r.payload) || {}; } catch { return {}; }
};

// One metric cell: [value, state]. `read(payload)` answers the value or null.
function metric(health, repo, name, read) {
  if (!health) return [null, 'unread'];
  const row = health.find((r) => r.repo === repo && r.metric === name);
  if (!row) return [null, 'absent'];
  const v = read(payloadOf(row));
  return v === null ? [null, 'unread'] : [v, 'ok'];
}

export function ciHealthRows(health, flakes, quarantine) {
  const h = list(health, 'rows');
  const f = list(flakes, 'flakes');
  const q = list(quarantine, 'rows');
  const repos = new Set([...(h || []), ...(f || []), ...(q || [])].map((r) => r.repo).filter(Boolean));
  const rows = [...repos].sort().map((repo) => {
    const [minutes24h, minutesState] = metric(h, repo, 'minutes', (p) => (p.unread ? null : num(p.est_24h)));
    const [runners, runnersState] = metric(h, repo, 'runners', (p) => {
      const online = num(p.online), total = num(p.total);
      return p.unreadable || online === null || total === null ? null : { online, total };
    });
    let flakes7d = null, reds7d = null, flakeRate = null;
    if (f) {
      const mine = f.filter((r) => r.repo === repo);
      const heads = (kind) => new Set(mine.filter((r) => !kind || r.kind === kind).map((r) => r.head)).size;
      flakes7d = heads('flake');
      reds7d = heads('red');
      const all = heads(null);
      flakeRate = all ? flakes7d / all : null;
    }
    const quarantined = q ? q.filter((r) => r.repo === repo && isActive(r)).length : null;
    return { repo, minutes24h, minutesState, runners, runnersState, flakes7d, reds7d, flakeRate, quarantined };
  });
  return { rows, capped: Boolean(f && f.length >= FLAKES_LIMIT) };
}

// The worker refuses a quarantine on these synthetic names (a whole job or
// workflow is not one test), so they render without a toggle.
const SYNTHETIC = /^(job|workflow):/;

// One row per test of `repo`: its flaky heads in the window, or an active
// quarantine (so a quarantine can always be turned OFF). Red-only tests are not
// flaky and are left out. null when the flakes read failed.
export function flakeRows(flakes, quarantine, repo) {
  const f = list(flakes, 'flakes');
  if (!f) return null;
  const q = list(quarantine, 'rows');
  const on = new Set((q || []).filter((r) => r.repo === repo && isActive(r)).map((r) => r.test));
  const tests = new Map([...on].map((t) => [t, { heads: new Set(), lastDay: null }]));
  for (const r of f) {
    if (r.repo !== repo || r.kind !== 'flake') continue;
    const t = tests.get(r.test) || { heads: new Set(), lastDay: null };
    t.heads.add(r.head);
    if (!t.lastDay || r.day > t.lastDay) t.lastDay = r.day;
    tests.set(r.test, t);
  }
  const rows = [...tests].map(([test, t]) => {
    const quarantined = q ? on.has(test) : null;
    return { test, flakyHeads: t.heads.size, lastDay: t.lastDay, quarantined, toggleable: quarantined !== null && !SYNTHETIC.test(test) };
  });
  return { rows, capped: f.length >= FLAKES_LIMIT };
}

export function quarantineFormState({ reason } = {}) {
  const blank = !String(reason ?? '').trim();
  return { blocked: blank, hint: blank ? 'say why this test is (or is no longer) quarantined' : '' };
}

// The QUARANTINE toggle, as a factory so the tests drive the same code the
// screen runs (the makeResetAction pattern). `form` is a fresh object per click
// that the modal's reason input writes through. Success is only an `ok: true`
// answer; the table then reloads from the worker, so ON/OFF is never a guess.
export function makeQuarantineAction({ confirm: ask, put, reload, onMsg, onPending, renderForm }) {
  const inFlight = new Set();
  return async (repo, row) => {
    const key = `${repo}|${row.test}`;
    if (!row.toggleable || inFlight.has(key)) return;
    const next = !row.quarantined;
    const form = { reason: '' };
    const confirmed = await ask({
      title: next ? 'QUARANTINE TEST' : 'END QUARANTINE', confirmLabel: next ? 'QUARANTINE' : 'END', tone: 'warn',
      confirmBlocked: true, form,
      body: renderForm ? ({ setBlocked }) => renderForm(repo, row, next, form, setBlocked) : null
    });
    if (!confirmed) return;
    const reason = String(form.reason ?? '').trim();
    if (quarantineFormState({ reason }).blocked) {
      onMsg({ ok: false, text: 'quarantine refused — a reason is required' });
      return;
    }
    inFlight.add(key);
    if (onPending) onPending(key);
    try {
      const res = await put({ repo, test: row.test, active: next ? 1 : 0, reason });
      if (!res || res.ok !== true) {
        onMsg({ ok: false, text: `quarantine for ${row.test} was not confirmed by the worker — check the table` });
        return;
      }
      onMsg({ ok: true, text: `${row.test} quarantine ${next ? 'ON' : 'OFF'} for ${repo}` });
      reload();
    } catch (e) {
      onMsg({ ok: false, text: `quarantine failed — ${e && e.message ? e.message : String(e)}` });
    } finally {
      inFlight.delete(key);
      if (onPending) onPending(null);
    }
  };
}
