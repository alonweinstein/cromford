// Raw field names read as jargon on a phone. plainLabel turns one into words,
// and because it always has a mechanical fallback an unmapped field can never
// render as SNAKE_CASE. Where a screen has a real label (a settings row's own
// copy), it uses that; this is the floor, not the source.

// The handful the mechanical fallback gets wrong: acronyms it would lowercase
// and codes that mean nothing spelled out. Keep this short on purpose.
const PLAIN = { RC: 'exit code', PR: 'PR', PR_URL: 'PR link', CI: 'CI', SHA: 'commit', USD: '$' };

export function plainLabel(field) {
  if (field === null || field === undefined) return '';
  const raw = String(field).trim();
  if (!raw) return '';
  const hit = PLAIN[raw.toUpperCase()];
  if (hit) return hit;
  return raw.replace(/[_\s-]+/g, ' ').trim().toLowerCase();
}

// What a merge tier means, in the words an operator would use. Tier 1 merges
// itself once the gate passes; tier 2 waits for a review.
export const TIER_LABEL = Object.freeze({ 1: 'auto-merge', 2: 'reviewed merge' });

// D1 hands numbers back as strings, so '2' is tier 2. An unknown tier says its
// number rather than rendering bare or crashing; 0 is a value, not a missing one.
export function tierLabel(t) {
  if (t === null || t === undefined || t === '') return 'no tier';
  return TIER_LABEL[Number(t)] || `tier ${t}`;
}
