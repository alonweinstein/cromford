import { html } from '../router.js';
import { SortableTable } from './SortableTable.js';
import { Stat, Skeleton, Empty, ErrorBox } from './primitives.js';
import { safeHttpsUrl, whenLabel } from '../lib/format.js';

// BH-4981: the merges the main-red safety net reverted, read from the jobs
// worker's ledger (kind main_red_attrib, key <slug>@<culprit sha>, status
// gap|no-gap|serial|unknown, detail a JSON string the hub lane wrote). Shown on
// /ci with the risk tier and queue lane each culprit merged under, so a pattern
// (scoped lane, low tier, still red) is visible without reading the ledger.

const DASH = '-';
const TIERS = ['high', 'low', 'unknown'];
const LANES = ['scoped', 'serial', 'unknown'];

// The detail is the hub's text, so a row whose detail is missing or not JSON
// still renders: its slug and sha come from the key, every detail cell is '-'.
function parseDetail(text) {
  if (!text || typeof text !== 'string') return null;
  try {
    const d = JSON.parse(text);
    return d && typeof d === 'object' && !Array.isArray(d) ? d : null;
  } catch {
    return null;
  }
}

const word = (v) => (typeof v === 'string' && v.trim() ? v.trim() : DASH);

// `{ledgers:[...]}` -> one row per ledger entry. Anything not shaped like that
// is no rows, never a throw.
export function mainRedRevertRows(data) {
  const list = data && Array.isArray(data.ledgers) ? data.ledgers : [];
  return list.filter((l) => l && typeof l === 'object').map((l) => {
    const key = String(l.key || '');
    const at = key.indexOf('@');
    const d = parseDetail(l.detail) || {};
    const pr = Number.isInteger(Number(d.pr)) && Number(d.pr) > 0 ? Number(d.pr) : null;
    return {
      key,
      slug: at > 0 ? key.slice(0, at) : (key || DASH),
      sha: at > 0 ? key.slice(at + 1) : DASH,
      status: word(l.status),
      pr,
      prTitle: word(d.pr_title),
      lane: word(d.lane),
      risk: word(d.risk_tier),
      reason: word(d.reason),
      missed: Array.isArray(d.missed) ? d.missed.filter((m) => typeof m === 'string') : [],
      revertUrl: safeHttpsUrl(d.revert_url),
      gapUrl: safeHttpsUrl(d.gap_url),
      updatedAt: l.updated_at || null,
    };
  });
}

// Counts over the rows read. A tier or lane outside the known three keeps its
// own count rather than being folded into unknown; '-' (no detail) is unknown.
export function mainRedCounters(rows) {
  const byRisk = Object.fromEntries(TIERS.map((t) => [t, 0]));
  const byLane = Object.fromEntries(LANES.map((t) => [t, 0]));
  let gaps = 0;
  for (const r of rows) {
    const risk = r.risk === DASH ? 'unknown' : r.risk;
    const lane = r.lane === DASH ? 'unknown' : r.lane;
    byRisk[risk] = (byRisk[risk] || 0) + 1;
    byLane[lane] = (byLane[lane] || 0) + 1;
    if (r.status === 'gap') gaps++;
  }
  return { total: rows.length, byRisk, byLane, gaps };
}

const link = (href, text, title) => html`<a href=${href} target="_blank" rel="noopener noreferrer" title=${title}>${text}</a>`;

const columns = (now) => [
  {
    key: 'pr', label: 'CULPRIT', sort: (r) => r.pr,
    cell: (r) => (r.pr === null ? DASH
      : link(`https://github.com/${r.slug}/pull/${r.pr}`, `#${r.pr}`, `${r.slug} · ${r.prTitle} · ${r.sha.slice(0, 8)}`))
  },
  { key: 'revert', label: 'REVERT', sort: (r) => r.revertUrl, cell: (r) => (r.revertUrl ? link(r.revertUrl, 'revert') : 'none') },
  { key: 'status', label: 'MAP GAP', sort: (r) => r.status, cell: (r) => (r.gapUrl ? link(r.gapUrl, r.status) : r.status) },
  { key: 'lane', label: 'LANE', sort: (r) => r.lane, cell: (r) => r.lane },
  { key: 'risk', label: 'RISK TIER', sort: (r) => r.risk, cell: (r) => r.risk },
  {
    key: 'missed', label: 'MISSED SUITES', flex: true, sort: (r) => r.missed.length,
    cell: (r) => html`<span style="overflow-wrap:anywhere" title=${r.reason}>${r.missed.length ? r.missed.join(', ') : DASH}</span>`
  },
  {
    key: 'when', label: 'WHEN', sort: (r) => r.updatedAt,
    cell: (r) => (r.updatedAt ? html`<span title=${r.updatedAt}>${whenLabel(r.updatedAt, now)}</span>` : DASH)
  },
];

// state is a useApi read: { loading, error, data, reload }. A failed read shows
// the error and no counters, because a 0 there would read as "none reverted".
export function MainRedRevertsView({ state, now = Date.now(), limit = 200 }) {
  if (!state || (state.loading && !state.data && !state.error)) return html`<${Skeleton} rows=${3} height=${20}/>`;
  if (state.error || !state.data) {
    return html`<${ErrorBox} error=${'could not read the main-red reverts'} onRetry=${state.reload}/>`;
  }
  const rows = mainRedRevertRows(state.data);
  if (!rows.length) return html`<${Empty} title="No main-red reverts recorded."/>`;
  const c = mainRedCounters(rows);
  return html`
    <div class="stats" style="margin-bottom:10px">
      <${Stat} label="TOTAL" value=${c.total}/>
      <${Stat} label="RISK TIER" value=${`${c.byRisk.high}/${c.byRisk.low}/${c.byRisk.unknown}`} unit="high/low/unknown" tone="sm"/>
      <${Stat} label="LANE" value=${`${c.byLane.scoped}/${c.byLane.serial}/${c.byLane.unknown}`} unit="scoped/serial/unknown" tone="sm"/>
      <${Stat} label="MAP GAPS" value=${c.gaps} tone=${c.gaps ? 'warn' : null}/>
    </div>
    ${rows.length >= limit ? html`<div class="footnote" style="margin-bottom:6px"><span style="color:var(--faint)">newest ${limit} shown; counters cover these only</span></div>` : null}
    <${SortableTable} wide columns=${columns(now)} rows=${rows} rowKey=${(r) => r.key}
      defaultSort="when" defaultDir="desc"/>`;
}
