// BH-4957 (BH-4950.4): the pure half of /lead-reviews. Everything here is a
// function of worker answers, so the tests drive it without a DOM.
//
// Sources:
// - the auto repos are the LEAD_REVIEW_AUTO_REPOS knob's catalog default on the
//   lead-review-land lane (settable:false, so no settings row overrides it);
// - the two limits are the settings rows below, written by this screen and read
//   by the lead-review lane (BH-4956);
// - worklist and gate facts are GET /api/pr-state/needs-review and /gate
//   (worker/jobs/src/lib/pr-gate.js), one call per auto repo.

export const SPEND_KEY = 'lead_review.daily_spend_usd';
export const CONCURRENCY_KEY = 'lead_review.concurrency';
export const AUTO_REPOS_LANE = 'lead-review-land';
export const AUTO_REPOS_ENV = 'LEAD_REVIEW_AUTO_REPOS';
// Page sizes. Each is a ceiling the worker honours, and a page that comes back
// full is flagged incomplete in the UI rather than read as the whole set.
export const DRIFT_LIMIT = 1000;
export const WORKLIST_LIMIT = 200;
export const RUNNING_LIMIT = 100;
export const FAILED_LIMIT = 100;

const SHA_RE = /^[0-9a-f]{40}$/;
const low = (s) => (typeof s === 'string' ? s.toLowerCase() : '');

// The auto repo list, or null when the registry does not carry the knob. null
// is an error on the screen, never "no repos" and never a hardcoded repo.
export function autoReposFrom(registry) {
  const lanes = registry && Array.isArray(registry.lanes) ? registry.lanes : null;
  if (!lanes) return null;
  const lane = lanes.find((l) => l && l.id === AUTO_REPOS_LANE);
  const knob = lane && Array.isArray(lane.knobs) ? lane.knobs.find((k) => k && k.env === AUTO_REPOS_ENV) : null;
  if (!knob || typeof knob.default !== 'string') return null;
  const repos = knob.default.split(/[\s,]+/).filter(Boolean);
  return repos.length ? repos : null;
}

// owner/repo (lowercased) -> console project, from GET /api/projects. A repo
// two projects claim maps to neither (D17): a PR link that picks one would be
// a guess.
export function projectByRepo(projects) {
  const rows = projects && Array.isArray(projects.projects) ? projects.projects : [];
  const map = new Map();
  const dup = new Set();
  for (const p of rows) {
    if (!p || typeof p.repo !== 'string' || typeof p.project !== 'string') continue;
    const k = low(p.repo);
    if (map.has(k) && map.get(k) !== p.project) dup.add(k);
    map.set(k, p.project);
  }
  for (const k of dup) map.delete(k);
  return map;
}

// /pr/<project>/<n> for a mapped repo; null for one with no console project,
// where the cell links to GitHub instead.
export function prHref(map, repo, n) {
  const project = map && map.get(low(repo));
  return project ? `/pr/${encodeURIComponent(project)}/${encodeURIComponent(n)}` : null;
}

// Reconcile events in one page of pr_state_events. A full page means there
// may be more, so the count is a floor and says so.
export function driftCount(rows, limit) {
  const list = Array.isArray(rows) ? rows : [];
  return { n: list.filter((r) => r && r.reason === 'reconcile').length, capped: list.length >= limit };
}

// The newest failed request for (repo, pr, head), or null.
function failedRequestFor(requests, repo, number, head) {
  const hits = (Array.isArray(requests) ? requests : []).filter((r) => r && r.status === 'failed'
    && low(r.repo) === low(repo) && Number(r.pr) === Number(number) && low(r.head_sha) === low(head));
  hits.sort((a, b) => String(b.updated_at || '').localeCompare(String(a.updated_at || '')));
  return hits[0] || null;
}

// Gate rows whose review failed on the head the PR has now, each joined to
// its failed request row for the detail and the job.
export function failedRows(gateRows, failedRequests) {
  return (Array.isArray(gateRows) ? gateRows : [])
    .filter((g) => g && g.review_failed_sha && g.head && low(g.review_failed_sha) === low(g.head))
    .map((g) => {
      const req = failedRequestFor(failedRequests, g.repo, g.number, g.head);
      return {
        repo: g.repo, number: g.number, head: g.head, url: g.url || null,
        detail: req ? req.detail || null : null,
        job_id: req ? req.job_id || null : null,
        failed_at: req ? req.updated_at || null : null,
        joined: Boolean(req)
      };
    });
}

// The PR screen's question: did a lead review fail on the head this PR has
// NOW? A failure on an older head, a request for another PR, or a head that is
// not a full sha is no. `{detail, job_id}` for yes, null for no.
export function leadReviewFailure({ liveHead, number, gateRow, failedRequests }) {
  const head = low(liveHead);
  if (!SHA_RE.test(head)) return null;
  const gateHit = Boolean(gateRow && Number(gateRow.number) === Number(number) && low(gateRow.review_failed_sha) === head);
  const req = (Array.isArray(failedRequests) ? failedRequests : []).filter((r) => r && r.status === 'failed'
    && Number(r.pr) === Number(number) && low(r.head_sha) === head)
    .sort((a, b) => String(b.updated_at || '').localeCompare(String(a.updated_at || '')))[0] || null;
  if (!gateHit && !req) return null;
  return { detail: req ? req.detail || null : null, job_id: req ? req.job_id || null : null };
}

// A value typed into the EDIT modal, refused rather than clamped (D11).
// spend: a dollar amount >= 0. concurrency: a whole number >= 1.
export function parseLimit(kind, raw) {
  const s = typeof raw === 'string' ? raw.trim() : '';
  if (kind === 'spend') {
    if (!/^\d+(\.\d+)?$/.test(s)) return { ok: false, error: 'a dollar amount, 0 or more (e.g. 25 or 12.50)' };
    return { ok: true, value: Number(s) };
  }
  if (kind === 'concurrency') {
    if (!/^\d+$/.test(s) || Number(s) < 1) return { ok: false, error: 'a whole number, 1 or more' };
    return { ok: true, value: Number(s) };
  }
  return { ok: false, error: `unknown limit ${kind}` };
}

// A settings read as what the strip says. `state` is useApi's.
//   {kind:'loading'} | {kind:'error', text} | {kind:'none'} | {kind:'bad', raw} | {kind:'ok', value}
export function limitState(kind, state) {
  if (!state || (state.loading && !state.data)) return { kind: 'loading' };
  if (state.error && !state.data) return { kind: 'error', text: String(state.error.message || state.error) };
  const row = state.data && state.data.setting;
  if (!row) return { kind: 'none' };
  const parsed = parseLimit(kind, String(row.value ?? ''));
  return parsed.ok ? { kind: 'ok', value: parsed.value } : { kind: 'bad', raw: String(row.value) };
}

// The 24h window's start, in the worker's fixed-width form (no millis), so it
// compares lexically against pr_state_events.at.
export function sinceIso(nowMs, hours = 24) {
  return new Date(nowMs - hours * 3600e3).toISOString().replace(/\.\d{3}Z$/, 'Z');
}

// The lead review job's PR number. job_open keys it lr-<pr>-<sha12>
// (bin/lead-review.sh); anything else has no PR to show.
export function prOfJob(job) {
  const m = job && typeof job.ticket_id === 'string' ? job.ticket_id.match(/^lr-(\d+)-[0-9a-f]{12}$/) : null;
  return m ? Number(m[1]) : null;
}

// The worklist across repos. `position` is the row's place in its repo's
// worker order (the order the lane takes them in), 1-based.
export function worklistRows(perRepo) {
  const out = [];
  for (const r of perRepo || []) {
    if (!r || !Array.isArray(r.needs)) continue;
    r.needs.forEach((row, i) => out.push({ ...row, repo: row.repo || r.repo, position: i + 1 }));
  }
  return out;
}
