// BH-3687 (slice BH-3712): the factory-stop switch, as the Fleet screen reads
// and writes it. The switch is ONE settings row, `switch.factory-stop`, the
// same row bin/factory-stop.sh writes and bin/lib/factory-stop.sh reads. The
// console keeps nothing of its own: what it shows is the last GET.

export const FACTORY_STOP_KEY = 'switch.factory-stop';

function minutesSinceIso(iso, now) {
  const t = typeof iso === 'string' ? Date.parse(iso) : NaN;
  return Number.isNaN(t) ? null : Math.max(0, Math.floor((now - t) / 60000));
}

// `GET /api/coord/settings/<key>` answers `{key, setting: row|null, source}`.
// No row is off. A value reads as _ls_row reads it (lowercased, never
// trimmed): 1/on/true is on, 0/off/false is off. Anything else, and any answer
// without a `setting` field, is `unknown` — never on.
export function shapeFactoryStop(payload, now = Date.now()) {
  const unknown = { state: 'unknown', sinceIso: null, forMin: null, actor: null, reason: null };
  if (!payload || typeof payload !== 'object' || Array.isArray(payload) || !('setting' in payload)) return unknown;
  const s = payload.setting;
  if (s === null) return { state: 'off', sinceIso: null, forMin: null, actor: null, reason: null };
  if (!s || typeof s !== 'object' || s.value === undefined || s.value === null) return unknown;
  const v = String(s.value).toLowerCase();
  const state = ['1', 'on', 'true'].includes(v) ? 'on' : ['0', 'off', 'false'].includes(v) ? 'off' : 'unknown';
  if (state === 'unknown') return unknown;
  return {
    state,
    sinceIso: s.updated_at || null,
    forMin: minutesSinceIso(s.updated_at, now),
    actor: s.actor || null,
    reason: s.note || null
  };
}

// The PUT body. No actor: the coord proxy stamps the signed-in one.
export function factoryStopBody(state, reason) {
  const r = String(reason ?? '').trim();
  if (!r) return { error: 'reason required' };
  if (state !== 'on' && state !== 'off') return { error: 'invalid state' };
  return { key: FACTORY_STOP_KEY, value: state === 'on' ? '1' : '0', reason: r, note: r };
}

// The one call the toggle's confirm makes: write, then re-read, and report
// what the RE-READ says. A resolved PUT alone is never reported as ON/OFF.
export async function runFactoryStop(api, state, reason) {
  const body = factoryStopBody(state, reason);
  if (body.error) return { ok: false, text: body.error };
  try {
    await api.setCoordSetting(body);
  } catch (e) {
    return { ok: false, text: `factory-stop not recorded: ${e.message}` };
  }
  let now;
  try {
    now = shapeFactoryStop(await api.coordSetting(FACTORY_STOP_KEY)).state;
  } catch (e) {
    return { ok: false, text: `write sent, but the row could not be re-read: ${e.message}` };
  }
  if (now === state) return { ok: true, text: `factory-stop is ${state.toUpperCase()}` };
  return { ok: false, text: `write sent, re-read still says ${now}` };
}
