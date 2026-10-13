// BH-2556 (BH-2540.3): the view model for the LLM sites list. Pure functions of
// the GET /api/metrics/llm-sites payload (shape: worker/jobs/src/routes/llm-sites.js).
// Absent money stays null all the way to the cell, where it reads `—`.
import { fmtUsdExact } from './spend.js';

// Preferred column order for runners we know. Only runners present in the data
// become columns; any other runner follows these, alphabetically.
const RUNNER_ORDER = ['claude', 'codex', 'grok', 'openrouter', 'fireworks'];

// A number, or a non-blank numeric string; anything else is absent (null), never 0.
const num = (v) => {
  if (typeof v === 'number') return Number.isFinite(v) ? v : null;
  if (typeof v === 'string' && v.trim() !== '' && Number.isFinite(Number(v))) return Number(v);
  return null;
};

export const money = (n) => fmtUsdExact(n);

export function runnerColumns(payload) {
  const seen = new Set();
  for (const s of payload?.sites || []) {
    for (const w of [s.usd_24h, s.usd_7d]) {
      for (const k of Object.keys(w?.by_runner || {})) seen.add(k);
    }
  }
  const known = RUNNER_ORDER.filter((r) => seen.has(r));
  const rest = [...seen].filter((r) => !RUNNER_ORDER.includes(r)).sort();
  return [...known, ...rest];
}

export const BADGE_TITLES = {
  'no row': 'no cost rows recorded for this site in the last 7 days',
  'no knob': 'no settings knob is bound to this site',
  'no kill': 'no context-kill threshold guards this site',
};

// Only an explicit `true` from the worker shows a badge.
export function badges(row) {
  const b = row?.badges || {};
  const out = [];
  if (b.no_row === true) out.push('no row');
  if (b.no_knob === true) out.push('no knob');
  if (b.no_kill === true) out.push('no kill');
  return out;
}

export const drillHref = (id) => '/llm-sites/' + encodeURIComponent(id);

const part = (v) => (num(v) === null ? '—' : String(num(v)));

export function refusedText(r) {
  return `${part(r?.gate)}/${part(r?.guard)}/${part(r?.context_kill)}`;
}

export function cashText(row) {
  const unknown = num(row?.unknown_billing_7d);
  return `${money(row?.cash_7d)} cash · ${money(row?.notional_7d)} notional`
    + (unknown !== null && unknown > 0 ? ` · ${unknown} unknown` : '');
}

export function incompleteText(payload) {
  const inc = payload?.incomplete;
  return Array.isArray(inc) && inc.length ? inc.join(', ') : null;
}

function byRunner(win, runners) {
  const out = {};
  for (const r of runners) out[r] = win ? num(win.by_runner?.[r]) : null;
  return out;
}

export function siteViewRows(payload) {
  const runners = runnerColumns(payload);
  return (payload?.sites || []).map((s) => {
    const knobs = Array.isArray(s.knobs_bound) ? s.knobs_bound : [];
    const refused = { gate: num(s.refused_7d?.gate), guard: num(s.refused_7d?.guard), kill: num(s.refused_7d?.context_kill) };
    return {
      id: s.id, lane: s.lane ?? null, stage: s.stage ?? null, kind: s.kind ?? null,
      usd24: byRunner(s.usd_24h, runners),
      usd7: byRunner(s.usd_7d, runners),
      total24: num(s.usd_24h?.total),
      total7: num(s.usd_7d?.total),
      cash_7d: num(s.cash_7d), notional_7d: num(s.notional_7d), unknown_billing_7d: num(s.unknown_billing_7d),
      calls_7d: num(s.calls_7d),
      refused,
      refusedText: refusedText(s.refused_7d),
      guard_k: num(s.guard_k), guard_enforced: s.guard_enforced === true,
      kill_tokens: num(s.kill_tokens), cap_usd_day: num(s.cap_usd_day), today_usd: num(s.today_usd),
      knobsBound: knobs.length, knobsList: knobs.join(', '),
      shared: s.shared === true, attribution: s.attribution ?? null,
      badges: badges(s),
    };
  });
}
