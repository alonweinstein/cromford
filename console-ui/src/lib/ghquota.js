// BH-1484 — how the Fleet screen reads `gh_rest_quota.<box>` out of the hub's
// fleet_status snapshot.
//
// The hub and the pool boxes run every lane under ONE GitHub App installation,
// so one 6,600/h primary bucket carries every repo. On 2026-09-22 it burned
// ~5,700/h and emptied in the last five minutes of each window; the only
// symptom anywhere was a burst of "UNVERIFIABLE (HTTP 000)" lines in
// merge-conductor.log, and nothing on any screen carried the number. The box
// tile now does.
//
// `gh_quota_remaining` / `gh_quota_limit` / `gh_quota_reset` are what the REST
// reads themselves saw (bin/lib/gh-rest-ledger.sh writes them from the
// `X-RateLimit-*` headers, at zero API cost), so this renders the same reading
// the reserve gate refuses optional reads on.
//
// BH-1509: the App bucket arrives keyed by installation (`app-<id>`), because
// the fleet is no longer one installation — see gh_quota_bucket in
// bin/lib/gh-rest-ledger.sh.

// The documented code fallback for the `gh.quota.reserve` knob, matching
// _GH_QUOTA_RESERVE_DEFAULT in bin/lib/gh-rest-ledger.sh. It is the FALLBACK
// and not the rule: the hub pushes `gh_quota_reserve` beside the readings, so
// an operator who raises the row moves the pill and the gate together. A
// threshold compiled into the bundle alone would turn a box red at a number
// nothing was actually refusing reads at.
export const GH_QUOTA_RESERVE = 600;

const UNKNOWN = {
  text: 'gh quota —', tone: 'unknown', low: false, known: false, badge: null,
  title: 'the hub pushed no GitHub REST quota reading for this box'
};

// ghQuotaBadge(entry, reserve) -> { text, tone, low, known, badge, title }
//
// Never throws, and never invents. Anything it does not recognise is `unknown`,
// because silence from the hub is not evidence that a bucket is empty — which
// is the same rule the library itself keeps: an unread quota renders `?`, never
// 0. A pool box the hub cannot read has no entry and renders nothing at all.
export function ghQuotaBadge(entry, reserve = GH_QUOTA_RESERVE) {
  if (!entry || typeof entry !== 'object') return UNKNOWN;
  const rem = Number(entry.gh_quota_remaining);
  // A key present with no number is not a reading. Number(null) and Number('')
  // are both 0, and 0 remaining is the loudest thing this field can say — so it
  // is the one value that must never be arrived at by coercion.
  if (entry.gh_quota_remaining === null || entry.gh_quota_remaining === undefined
      || !Number.isFinite(rem)) return UNKNOWN;
  // Same type check for the threshold, and for the same reason inverted: a
  // reserve that coerced to 0 would be a gate that never fires, rendering every
  // box healthy at the moment the bucket empties. A real 0 IS a legitimate
  // operator setting ("never refuse a read"), so it is honoured.
  const res = typeof reserve === 'number' && Number.isFinite(reserve) && reserve >= 0
    ? reserve : GH_QUOTA_RESERVE;
  const lim = Number(entry.gh_quota_limit);
  const hasLim = Number.isFinite(lim) && lim > 0;
  const low = rem < res;
  // WHICH METER THIS IS (BH-1484 review I-1). The fleet spends from several
  // GitHub rate-limit buckets: every installation token of the App shares one
  // 6,600/h, and each PAT in the token ladder carries its own 5,000/h. The hub
  // pushes the `app` bucket — the shared one the ticket measured — and names
  // it, so a number on a tile can never be read as the fleet's headroom when it
  // is one PAT's. An entry with no name is the App bucket: that is the only
  // thing the hub has ever pushed here.
  const bucket = typeof entry.gh_quota_bucket === 'string' && entry.gh_quota_bucket
    ? entry.gh_quota_bucket : 'app';
  // `app-<installation id>` since BH-1509: two installations are two separate
  // 6,600/h meters, so the tooltip NAMES the one it is showing and two boxes on
  // two Apps read as two numbers rather than one that is neither box's. A bare
  // `app` is a box whose token was minted before that landed, and it keeps
  // exactly its old wording — an id it does not have must not render as
  // "installation undefined".
  const appInst = /^app-(\d+)$/.exec(bucket);
  const where = bucket === 'app'
    ? 'the shared GitHub App installation'
    : appInst
      ? `the shared GitHub App installation ${appInst[1]}`
      : `the ${bucket} bucket`;
  return {
    text: hasLim ? `gh quota ${rem}/${lim}` : `gh quota ${rem}`,
    tone: low ? 'dead' : 'ok',
    low,
    known: true,
    bucket,
    badge: low ? 'QUOTA LOW' : null,
    title: `${rem} REST call(s) left on ${where}`
      + `${hasLim ? ` of ${lim}` : ''} — optional reads are refused below ${res}`
      + `${resetText(entry)}`
  };
}

// The reset is rendered only when it is a real epoch: a `reset —` reads as "it
// never refills", which is the opposite of what an unknown means.
function resetText(entry) {
  const t = Number(entry.gh_quota_reset);
  if (!Number.isFinite(t) || t <= 0) return '';
  return `, window resets at ${new Date(t * 1000).toISOString().slice(11, 19)}Z`;
}
