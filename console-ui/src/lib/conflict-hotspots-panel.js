// The CONFLICT HOTSPOTS section of /p/<project> (BH-5267), the pure half. Body
// shape from GET /api/conflict-hotspots (worker/jobs): `prs` is the raw
// comma-separated PR-ids column bin/conflict-hotspots.sh prints (`#12,#7,ticket/x`),
// `run.repo` an owner/name slug or null, `ref_sha` the sha the window was
// measured at.
import { whenLabel } from './format.js';

// The panel's own read size: a display page, not the worker's clamp. The body's
// `truncated` and `total` say whether more rows exist behind it.
export const HOTSPOTS_SHOWN = 50;

const PR_ID = /^#(\d+)$/;
const REPO = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;
const SHA = /^[0-9a-f]{7,40}$/i;
const text = (v) => (v === null || v === undefined ? '' : String(v).trim());
// whenLabel says 'never' / 'unreadable' for a missing or bad stamp; here the run
// did happen, so the honest wording is that its time is unknown.
const when = (iso, now) => {
  const w = whenLabel(iso, now);
  return w === 'never' || w === 'unreadable' ? 'at an unknown time' : w;
};

// Only `#<digits>` (above 0) is a PR the console has a page for. Anything else
// (an unmerged branch name) stays plain text, never a guessed link.
function prCell(label, project) {
  const m = PR_ID.exec(label);
  const n = m ? Number(m[1]) : 0;
  return { label, href: n > 0 ? `/pr/${encodeURIComponent(project)}/${n}` : null };
}

// The file's history at the measured sha, only when the run named a repo and a
// sha: without both there is no true URL, so it is null (D26).
function fileHref(file, repo, sha) {
  if (!file || !REPO.test(repo) || !SHA.test(sha)) return null;
  const path = file.split('/').map(encodeURIComponent).join('/');
  return `https://github.com/${repo}/commits/${sha}/${path}`;
}

export function hotspotCells(row, project, run) {
  const prs = text(row && row.prs).split(',').map((s) => s.trim()).filter(Boolean)
    .map((label) => prCell(label, project));
  const sha = text(row && row.ref_sha) || text(run && run.ref_sha);
  return { prs, fileHref: fileHref(text(row && row.file), text(run && run.repo), sha) };
}

// One line about the run the rows came from. Each branch is only reachable in
// the state it describes: a failed latest run never reads as "last measured".
export function panelNote(run, now = Date.now()) {
  if (!run) return 'never measured';
  const detail = text(run.detail);
  if (run.status === 'ok') {
    const days = Number(run.window_days);
    const window = text(run.window_days) !== '' && Number.isFinite(days) ? `, ${days}-day window` : '';
    return `last measured ${when(run.run_at, now)}${window}`;
  }
  const head = `latest run failed: ${text(run.status) || 'unknown'}${detail ? ` (${detail})` : ''}`;
  return run.last_ok_at
    ? `${head} — showing the window from ${when(run.last_ok_at, now)}`
    : `${head} — no successful run yet`;
}
