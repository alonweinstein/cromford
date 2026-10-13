// Meter-anchored cost, as the COSTS screen reads it.
//
// The arithmetic is the WORKER's (GET /api/metrics/cost-anchored, and the
// METER-ANCHORED COST block above computeAnchored in worker/jobs/src/index.js).
// Nothing here multiplies anything: a second implementation of the factor in a
// browser would eventually disagree with the endpoint about what a PR cost, and
// the disagreement would surface as two screens quoting two numbers.
//
// What lives here is the part a screen owns — which of two figures is the
// believable one, what a state means in English, and where an identity cell
// links to.

export const ANCHOR_WINDOWS = [
  { key: '24h', label: '24H' },
  { key: '7d', label: '7D' }
];

// A multiplier nobody could measure is `—`, never "1.00x". Those are opposite
// claims: 1.00x says "measured, and the rows were right", a dash says "not
// measured". The screen's whole job is to keep those apart.
export function fmtFactor(f, state) {
  if (state && state !== 'metered') return '—';
  if (f === null || f === undefined || !Number.isFinite(Number(f))) return '—';
  return `${Number(f).toFixed(2)}x`;
}

// An anchored dollar figure is only a different number when something anchored
// it. Where the factor is 1 the two columns are the same figure, and saying so
// is what stops a reader from reading the second column as confirmation.
export const isAnchored = (row) => Boolean(row) && Number(row.factor) !== 1;

export function anchorState(account) {
  const state = account && account.state;
  if (state === 'metered') {
    return {
      state, label: account.factor_capped ? 'METERED (CAPPED)' : 'METERED',
      tone: account.factor_capped ? 'warn' : 'ok',
      note: account.reason || 'the account meter moved across this window and the rows were scaled onto it'
    };
  }
  if (state === 'unmeasured') {
    return { state, label: 'UNMEASURED', tone: 'warn', note: account.reason || 'this window cannot be measured against the meter' };
  }
  return {
    state: 'no-login', label: 'NO METER', tone: 'faint',
    note: (account && account.reason) || 'no meter for this account'
  };
}

// The headline a human reads before the tables: is ANY of this anchored, and by
// how much did anchoring move the total.
export function anchorHeadline(data) {
  if (!data) return { ready: false, disabled: false };
  if (data.disabled) {
    return { ready: false, disabled: true, reason: data.reason || 'meter anchoring is off' };
  }
  const totals = data.totals || {};
  const accounts = data.accounts || [];
  const metered = accounts.filter((a) => a.state === 'metered');
  const raw = totals.rows_usd ?? null;
  const anchored = totals.rows_anchored_usd ?? null;
  return {
    ready: true,
    disabled: false,
    window: data.window || null,
    from: data.from || null,
    to: data.to || null,
    accounts: accounts.length,
    metered: metered.length,
    // NOTHING METERED IS THE COMMON CASE and it is not an error: 8 of 9 boxes
    // cannot read the usage endpoint at all. It is a state with a sentence.
    anyAnchored: metered.length > 0,
    rawUsd: raw,
    anchoredUsd: anchored,
    meterUsd: totals.meter_delta_usd ?? null,
    uplift: (raw && anchored && raw > 0) ? anchored / raw : null,
    gaps: data.gaps || []
  };
}

// Every identity cell links. A PR knows its fleet project only when its build
// dir named one, so the fallback is the real GitHub url rather than a dead cell
// or a route that would 404 on a null project.
export function prLink(row) {
  if (!row) return null;
  if (row.project && row.number) {
    return { kind: 'route', to: `/pr/${encodeURIComponent(row.project)}/${encodeURIComponent(row.number)}` };
  }
  if (row.pr_url && /^https:\/\/github\.com\//.test(row.pr_url)) {
    return { kind: 'external', to: row.pr_url };
  }
  return null;
}

// A ticket drills into the BUILD that spent the money — the build dir is the
// id /builds/:id already takes, so this is the whole trail from a dollar to the
// session that spent it.
export function ticketLink(row) {
  return row && row.build_dir ? { kind: 'route', to: `/builds/${encodeURIComponent(row.build_dir)}` } : null;
}

export const boxLink = () => ({ kind: 'route', to: '/machines' });

// "execute $65.00, review $15.00" — the stage split of a ticket, biggest first,
// as one readable line rather than a second table inside a row.
export function stageLine(stages, fmt) {
  const entries = Object.entries(stages || {}).filter(([, v]) => Number.isFinite(Number(v)));
  if (!entries.length) return null;
  return entries.sort((a, b) => b[1] - a[1]).map(([k, v]) => `${k} ${fmt(v)}`).join(', ');
}

const num = (v) => (Number.isFinite(Number(v)) ? Number(v) : 0);

// The totals row under each table. It is computed from the rows ON THE PAGE and
// labelled as such when the page was truncated, because a footer that silently
// means something different from the column above it is the dishonest kind.
export function tableTotals(rows) {
  return {
    n: (rows || []).length,
    raw_usd: (rows || []).reduce((n2, r) => n2 + num(r.raw_usd), 0),
    anchored_usd: (rows || []).reduce((n2, r) => n2 + num(r.anchored_usd), 0)
  };
}
