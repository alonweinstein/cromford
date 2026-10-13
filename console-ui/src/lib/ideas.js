import { safeHttpsUrl } from './format.js';

// The IDEAS screen's pure logic: the proposal lifecycle, how a row is labelled,
// and the counts the strip reports. Kept out of the screen so the parts where a
// regression would be silent (a state that stops reading as "waiting on the operator",
// a count that quietly excludes a project) are unit-tested.

// The ledger's own vocabulary, in lifecycle order — bin/run-product.sh writes
// candidate/gate_pending, bin/product-cmd.sh writes vetoed, post-proposal.sh
// writes posted, and the client's answer moves it on from there.
export const STATUS_ORDER = [
  'gate_pending',
  'candidate',
  'posted',
  'client_approved',
  'building',
  'shipped',
  'client_rejected',
  'vetoed',
  'expired'
];

const STATUS_LABEL = {
  gate_pending: 'AWAITING DECISION',
  candidate: 'CANDIDATE',
  posted: 'POSTED TO CLIENT',
  client_approved: 'CLIENT APPROVED',
  client_rejected: 'CLIENT REJECTED',
  building: 'BUILDING',
  shipped: 'SHIPPED',
  vetoed: 'VETOED',
  expired: 'EXPIRED'
};

export const statusLabel = (status) =>
  STATUS_LABEL[status] || (status ? String(status).toUpperCase().replace(/_/g, ' ') : 'UNKNOWN');

// warn = something is waiting on a human here. dead = this idea is over.
// ok = it is moving. muted = it is parked and nobody is blocked by it.
const STATUS_TONE = {
  gate_pending: 'warn',
  candidate: 'muted',
  posted: 'ok',
  client_approved: 'ok',
  building: 'ok',
  shipped: 'ok',
  client_rejected: 'dead',
  vetoed: 'dead',
  expired: 'dead'
};

export const statusTone = (status) => STATUS_TONE[status] || 'muted';

// The gate is the one state that costs something by sitting still: the proposal
// is drafted, shot, and waiting for an approve/kill that only the operator can give.
export const awaitingDecision = (row) => Boolean(row) && row.status === 'gate_pending';

export const statusRank = (status) => {
  const i = STATUS_ORDER.indexOf(status);
  return i === -1 ? STATUS_ORDER.length : i;
};

// SYNTH classifies every idea derisk -> unclog -> scale, and SELECT picks in
// that order, so the bucket is worth showing as its own column.
const DUS_LABEL = { derisk: 'DERISK', unclog: 'UNCLOG', scale: 'SCALE' };
export const dusLabel = (dus) => DUS_LABEL[dus] || null;
export const DUS_ORDER = ['derisk', 'unclog', 'scale'];
export const dusRank = (dus) => {
  const i = DUS_ORDER.indexOf(dus);
  return i === -1 ? DUS_ORDER.length : i;
};

// score is written by run-product.sh as impact x confidence / effort. It is
// shown as the stored number; this only spells out where that number came from,
// and says nothing at all when a part is missing rather than inventing a 1.
export function scoreExplain(row) {
  if (!row) return null;
  const parts = [row.impact, row.confidence, row.effort];
  if (parts.some((v) => v === null || v === undefined || v === '' || !Number.isFinite(Number(v)))) return null;
  return `impact ${Number(row.impact)} × confidence ${Number(row.confidence)} ÷ effort ${Number(row.effort)}`;
}

// The strip over the table. Every count is of the rows PASSED IN, so a filtered
// view reports the filtered set and never the whole ledger behind it.
export function summarise(rows) {
  const list = Array.isArray(rows) ? rows : [];
  const byStatus = {};
  for (const r of list) {
    const s = r && r.status ? r.status : 'unknown';
    byStatus[s] = (byStatus[s] || 0) + 1;
  }
  return {
    total: list.length,
    byStatus,
    awaiting: list.filter(awaitingDecision).length,
    withMockup: list.filter(hasMockup).length,
    posted: list.filter((r) => ['posted', 'client_approved', 'building', 'shipped'].includes(r && r.status)).length,
    shipped: list.filter((r) => r && r.status === 'shipped').length,
    projects: [...new Set(list.map((r) => r && r.project).filter(Boolean))].sort()
  };
}

// Distinct values for a filter row, in a stable order: lifecycle order for
// status, alphabetical for anything else.
export function facet(rows, key) {
  const list = Array.isArray(rows) ? rows : [];
  const values = [...new Set(list.map((r) => r && r[key]).filter((v) => v !== null && v !== undefined && v !== ''))];
  if (key === 'status') return values.sort((a, b) => statusRank(a) - statusRank(b));
  if (key === 'dus') return values.sort((a, b) => dusRank(a) - dusRank(b));
  return values.sort();
}

export const ideaPath = (row) =>
  `/ideas/${encodeURIComponent(row.project)}/${encodeURIComponent(row.slug)}`;

export const assetUrl = (project, slug, kind) =>
  `/api/ideas/asset/${encodeURIComponent(project)}/${encodeURIComponent(slug)}/${encodeURIComponent(kind)}`;

// A proposal's mockup exists in two places, and the screen has to be honest
// about both. `mockup_url` is the interactive mockup post-proposal.sh attached
// to the client's board (only proposals that were actually posted have one, and
// only if that upload succeeded). `shots` counts the desktop/mobile PNGs
// bin/push-proposal-assets.sh pushed into the console's own asset store, which
// is everything the drafting stage rendered. The mockup.html itself never
// reaches the console, so these two are the whole of what is clickable from
// here. Neither of them means the idea never got past scoring, which is a real
// state and not a failed upload.

export const MOCKUP_HASH = '#mockup';

// Only https, and never a base URL: a "//evil.example/x" that resolved would be
// an arbitrary host wearing the client's board link.
export const mockupLink = (row) => safeHttpsUrl(row && row.mockup_url);

export function mockupShots(row) {
  const n = Number(row && row.shots);
  return Number.isFinite(n) && n > 0 ? Math.trunc(n) : 0;
}

export const hasMockup = (row) => Boolean(mockupLink(row)) || mockupShots(row) > 0;

// 'live' = there is a mockup the client can open. 'shots' = we have the
// screenshots but it never went to a board. 'none' = there is nothing to click.
export function mockupState(row) {
  if (mockupLink(row)) return 'live';
  if (mockupShots(row) > 0) return 'shots';
  return 'none';
}

const MOCKUP_RANK = { live: 2, shots: 1 };
// null, not 0: "no mockup" is missing, so it sinks whichever way the arrow
// points rather than owning the top of a descending sort.
export const mockupRank = (row) => MOCKUP_RANK[mockupState(row)] || null;

export const mockupAnchor = (row) => `${ideaPath(row)}${MOCKUP_HASH}`;

export function withMockups(rows, only) {
  const list = Array.isArray(rows) ? rows : [];
  return only ? list.filter(hasMockup) : list;
}

// Said over the rows in view BEFORE the toggle narrows them, so turning the
// filter on never collapses the count to "12 of 12".
export function mockupCountText(rows) {
  const list = Array.isArray(rows) ? rows : [];
  return `${list.filter(hasMockup).length} of ${list.length} have a mockup`;
}
