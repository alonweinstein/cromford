// The MERGE TRAINS table in the QUEUES section of /p/<project> (BH-3153), the
// pure half. Row shape from worker/jobs/src/routes/merge-trains.js: train_pr is
// an INTEGER or null, members a csv of PR numbers in train order, or null.

// The panel's own read size: a display page, not the worker's 200 clamp. A
// read that comes back with this many rows may have older trains behind it.
export const TRAINS_SHOWN = 50;
const SUMMARY_SHOWN = 3;

// A positive integer PR number, or null. Blank, null and '' never coerce to 0.
function prNumber(v) {
  if (v === null || v === undefined || String(v).trim() === '') return null;
  const n = Number(v);
  return Number.isInteger(n) && n > 0 ? n : null;
}

const prHref = (project, n) => `/pr/${encodeURIComponent(project)}/${n}`;

export function trainCells(row, project) {
  const pr = prNumber(row && row.train_pr);
  const members = String((row && row.members) || '').split(',')
    .map(prNumber).filter((n) => n !== null)
    .map((number) => ({ number, href: prHref(project, number) }));
  const shown = members.slice(0, SUMMARY_SHOWN);
  const more = Math.max(0, members.length - SUMMARY_SHOWN);
  const text = shown.map((m) => `#${m.number}`).join(', ');
  return {
    prHref: pr === null ? null : prHref(project, pr),
    prLabel: pr === null ? '—' : `#${pr}`,
    members,
    membersShown: shown,
    membersMore: more,
    membersSummary: members.length ? (more ? `${text} +${more} more` : text) : 'none'
  };
}

export const trainsCapped = (rows) => rows.length >= TRAINS_SHOWN;
