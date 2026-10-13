// BH-2566 (BH-2511.3): the CAPS table's shaping. Pure, so the tests feed it
// the settings rows the worker returns and the section only lays them out.
//
// Key families (BH-2411): conf.cost-caps.{budget.<p>,default,ceiling} and
// conf.lane-caps.{lane.<l>,noise.<l>,default}, each optionally followed by
// .<box> for one box's row. The value is the rest of the conf line. The
// readers are bin/lib/cost-budget.sh (_cb_row_ok) and bin/lib/lane-caps.sh
// (_lc_row_ok); the grammar below mirrors them. The worker is the authority on
// a write; this only holds SAVE back early.

const FILES = ['cost-caps', 'lane-caps'];
// Directives that take a subject (budget.<p>) and those that do not (default).
const SUBJECT_DIRECTIVES = { 'cost-caps': ['budget'], 'lane-caps': ['lane', 'noise'] };
const BARE_DIRECTIVES = { 'cost-caps': ['default', 'ceiling'], 'lane-caps': ['default'] };
const SUBJECT_SCOPE = { budget: 'project', lane: 'lane', noise: 'lane' };

// kind -> the value it takes, as the modal shows it.
export const CAP_GRAMMAR = {
  'cost-caps.budget': '<usd per PR> [min PRs]',
  'cost-caps.default': '<usd per PR> [min PRs]',
  'cost-caps.ceiling': '<usd>',
  'lane-caps.lane': '<usd per day|off> [prompt bytes]',
  'lane-caps.default': '<usd per day|off> [prompt bytes]',
  'lane-caps.noise': '<sessions per day|off>',
};

// `rest` is the key after conf.<file>. -> {kind, scope, subject, box}.
function parseRest(file, rest) {
  const unknown = { kind: 'unknown', scope: '?', subject: rest, box: null };
  const parts = rest.split('.');
  if (parts.some((p) => p === '')) return unknown;
  const [d, ...tail] = parts;
  if (SUBJECT_DIRECTIVES[file].includes(d)) {
    if (tail.length < 1 || tail.length > 2) return unknown;
    // noise.default is the fleet-wide noise cap, not a lane named "default".
    const fleet = d === 'noise' && tail[0] === 'default';
    return { kind: `${file}.${d}`, scope: fleet ? 'fleet' : SUBJECT_SCOPE[d], subject: tail[0], box: tail[1] || null };
  }
  if (BARE_DIRECTIVES[file].includes(d)) {
    if (tail.length > 1) return unknown;
    return { kind: `${file}.${d}`, scope: 'fleet', subject: d, box: tail[0] || null };
  }
  return unknown;
}

const str = (v) => (v === null || v === undefined ? null : String(v));

// settingsRows is GET /api/settings' `settings` array. Anything else is a read
// that failed, never "no caps".
export function capRows(settingsRows) {
  if (!Array.isArray(settingsRows)) return { rows: [], unreadable: true };
  const rows = [];
  for (const s of settingsRows) {
    if (!s || s.key === null || s.key === undefined) continue;
    const key = String(s.key).trim().toLowerCase();
    const file = FILES.find((f) => key.startsWith(`conf.${f}.`));
    if (!file) continue;
    const parsed = parseRest(file, key.slice(`conf.${file}.`.length));
    const value = str(s.value);
    // One row per key: the seed's value until an operator writes the key.
    const seeded = s.actor === 'registry-seed';
    const catalog = seeded ? value : null;
    const override = seeded ? null : value;
    rows.push({
      key, file, ...parsed,
      catalog, override, applies: override ?? catalog,
      actor: s.actor || null, updatedAt: s.updated_at || null,
      editable: !parsed.box && parsed.kind !== 'unknown'
    });
  }
  return { rows, unreadable: false };
}

const NUM = /^(\d+\.?\d*|\.\d+)$/;
const posNum = (s) => NUM.test(s) && Number(s) > 0;
const nonNeg = (s) => NUM.test(s) && Number(s) >= 0;
const posInt = (s) => /^\d+$/.test(s) && Number(s) > 0;
const count = (s) => /^\d+$/.test(s);

// fields -> true when every one is what the kind takes, and no more of them.
const FIELDS_OK = {
  'cost-caps.budget': (f) => f.length <= 2 && posNum(f[0]) && (f.length < 2 || posNum(f[1])),
  'cost-caps.default': (f) => f.length <= 2 && posNum(f[0]) && (f.length < 2 || posNum(f[1])),
  'cost-caps.ceiling': (f) => f.length === 1 && posNum(f[0]),
  'lane-caps.lane': (f) => f.length <= 2 && (f[0] === 'off' || nonNeg(f[0])) && (f.length < 2 || posInt(f[1])),
  'lane-caps.default': (f) => f.length <= 2 && (f[0] === 'off' || nonNeg(f[0])) && (f.length < 2 || posInt(f[1])),
  'lane-caps.noise': (f) => f.length === 1 && (f[0] === 'off' || count(f[0])),
};

export function validateCapInput(kind, value) {
  const check = FIELDS_OK[kind];
  if (!check) return { ok: false, error: 'this key is not one the cap readers take' };
  if (typeof value !== 'string' || !value.trim()) return { ok: false, error: 'a value is required' };
  if (/[\t\r\n]/.test(value)) return { ok: false, error: 'one line, fields separated by spaces' };
  if (!check(value.trim().split(/ +/))) return { ok: false, error: `${kind} takes ${CAP_GRAMMAR[kind]}` };
  return { ok: true, error: '' };
}

export function editFormState(value, reason, kind) {
  if (typeof reason !== 'string' || !reason.trim()) return { blocked: true, hint: 'say why this cap changes' };
  const v = validateCapInput(kind, value);
  return v.ok ? { blocked: false, hint: '' } : { blocked: true, hint: v.error };
}

// The EDIT click, as a factory so the tests drive the same code the section
// runs (the makeResetAction pattern). `form` is a fresh object per click that
// the modal's inputs write through. Nothing is reported as set unless the
// worker answered 2xx; the proxy stamps the actor, so none is sent.
export function makeEditAction({ confirm, put, reload, onMsg, onPending, renderForm }) {
  const inFlight = new Set();
  return async (row) => {
    if (!row || !row.editable || inFlight.has(row.key)) return;
    const form = { value: row.applies ?? '', reason: '' };
    const ok = await confirm({
      title: 'EDIT CAP', confirmLabel: 'SAVE',
      confirmBlocked: editFormState(form.value, form.reason, row.kind).blocked,
      form,
      body: renderForm ? ({ setBlocked }) => renderForm(row, form, setBlocked) : null
    });
    if (!ok) return;
    const value = typeof form.value === 'string' ? form.value.trim() : '';
    const reason = typeof form.reason === 'string' ? form.reason.trim() : '';
    const state = editFormState(value, reason, row.kind);
    if (state.blocked) {
      onMsg({ ok: false, text: `EDIT refused — ${state.hint}` });
      return;
    }
    inFlight.add(row.key);
    if (onPending) onPending(row.key);
    try {
      await put({ key: row.key, value, reason });
      onMsg({ ok: true, text: `cap ${row.key} set to ${value}` });
      reload();
    } catch (e) {
      onMsg({ ok: false, text: `EDIT failed — ${e && e.message ? e.message : String(e)}` });
    } finally {
      inFlight.delete(row.key);
      if (onPending) onPending(null);
    }
  };
}
