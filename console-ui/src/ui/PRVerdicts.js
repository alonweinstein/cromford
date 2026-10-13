import { html, Link } from '../router.js';
import { SortableTable } from './SortableTable.js';
import { Skeleton, Empty, ErrorBox } from './primitives.js';
import { safeHttpsUrl } from '../lib/format.js';
import { leadReviewFailure } from '../lib/lead-reviews.js';

export { leadReviewFailure };

// BH-1952 — the PR screen's VERDICTS history (the jobs worker's head-bound
// review rows, GET /api/verdicts) and the REQUEST LEAD REVIEW door. Kept out of
// PR.js so the rendering and the request flow can be driven by a test.

const SHA_RE = /^[0-9a-f]{40}$/;

// The owner/repo of a GitHub PR url, or null for anything else.
export function repoFromPrUrl(url) {
  if (typeof url !== 'string') return null;
  const m = url.match(/^https:\/\/github\.com\/([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)\/pull\/\d+\/?$/);
  return m ? m[1] : null;
}

// The PR's live head, only when the payload carries a full sha. Never guessed
// from a verdict row or padded from a short one.
export function liveHeadOf(data) {
  if (!data) return null;
  const raw = data.head_sha || (data.gh && data.gh.head_sha);
  if (typeof raw !== 'string') return null;
  const sha = raw.toLowerCase();
  return SHA_RE.test(sha) ? sha : null;
}

// The sha of the standing verdict for the live head (BH-4439): the worker only
// answers `standing` for the head it was asked about, and this re-checks that,
// so a verdict for any other head is never returned. null when there is none.
export function standingShaOf(resp, liveHead) {
  const standing = resp && resp.standing;
  if (!liveHead || !standing || typeof standing.head_sha !== 'string') return null;
  const sha = standing.head_sha.toLowerCase();
  return SHA_RE.test(sha) && sha === liveHead ? sha : null;
}

export function verdictColumns(repo, resp, liveHead) {
  const standing = resp && resp.standing;
  const isStanding = (r) => Boolean(liveHead && r.head_sha === liveHead && standing && standing.id === r.id);
  return [
    { key: 'created_at', label: 'CREATED', sort: (r) => r.created_at,
      cell: (r) => html`<span class="num">${r.created_at}</span>` },
    { key: 'head_sha', label: 'HEAD', sort: (r) => r.head_sha,
      cell: (r) => (repo && SHA_RE.test(r.head_sha || '')
        ? html`<a href=${`https://github.com/${repo}/commit/${r.head_sha}`} target="_blank" rel="noopener noreferrer" class="num">${r.head_sha.slice(0, 12)}</a>`
        : html`<span class="na">${String(r.head_sha || '—').slice(0, 12)}</span>`) },
    { key: 'verdict', label: 'VERDICT', sort: (r) => r.verdict,
      cell: (r) => html`<span class=${r.verdict === 'BLOCK' ? 'tag tag--warn' : 'tag tag--green'}>${r.verdict}</span>
        ${isStanding(r) ? html` <span class="tag" title="the verdict the merge lanes read for the live head">STANDING</span>` : null}` },
    { key: 'source', label: 'SOURCE', sort: (r) => r.source,
      cell: (r) => html`<span class="tag">${r.source}</span>` },
    { key: 'reviewer_model', label: 'MODEL', sort: (r) => r.reviewer_model,
      cell: (r) => (r.reviewer_model ? html`<span>${r.reviewer_model}</span>` : html`<span class="na">—</span>`) },
    { key: 'report_url', label: 'REPORT', sort: (r) => r.report_url,
      cell: (r) => {
        if (!r.report_url) return html`<span class="na">—</span>`;
        const href = safeHttpsUrl(r.report_url);
        return href
          ? html`<a href=${href} target="_blank" rel="noopener noreferrer">report ↗</a>`
          : html`<span class="na" title="not https, not linked">${r.report_url}</span>`;
      } }
  ];
}

// state: useApi's { loading, error, data, reload }.
export function VerdictsView({ repo, liveHead, state }) {
  if (state.loading && !state.data) return html`<${Skeleton} rows=${3}/>`;
  if (state.error && !state.data) return html`<${ErrorBox} error=${state.error} onRetry=${state.reload}/>`;
  const data = state.data || {};
  const rows = data.rows || [];
  if (!rows.length) {
    return html`<${Empty} title="No verdicts recorded for this PR"
      note="No lead, human or box review verdict row exists for this PR in the jobs DB." />`;
  }
  return html`
    <div style="overflow-x:auto;max-width:100%">
      <${SortableTable}
        columns=${verdictColumns(repo, data, liveHead)}
        rows=${rows}
        rowKey=${(r) => r.id}
        defaultSort="created_at" defaultDir="desc" />
    </div>
    ${data.truncated ? html`<div class="footnote"><span>showing the newest 100 verdict rows; older ones exist</span></div>` : null}`;
}

// The REQUEST LEAD REVIEW flow. `confirm` is useConfirm's promise; `action` is
// api.action. Returns null (nothing asked) without a full head sha, {sent:false}
// on cancel, otherwise {ok, text} with the command id or the error verbatim.
export async function requestLeadReview({ confirm, action, project, repo, pr, headSha, notes }) {
  if (typeof headSha !== 'string' || !SHA_RE.test(headSha) || !repo) return null;
  const ok = await confirm({
    title: 'REQUEST LEAD REVIEW',
    body: html`Ask the lead to review <b>${repo}#${pr}</b> at head <b>${headSha.slice(0, 12)}</b>?
      The request is bound to this head. A push after it is not covered.`,
    confirmLabel: 'REQUEST REVIEW'
  });
  if (!ok) return { sent: false };
  try {
    const res = await action({ type: 'lead_review', project, repo, pr, head_sha: headSha, notes });
    return { ok: true, text: `lead review requested as command #${res && res.command_id}` };
  } catch (e) {
    return { ok: false, text: e.message };
  }
}

// BH-4957: "Lead review failed" on the PR screen, only when the failure is on
// the head this PR has NOW. `state` is useApi's over {gate, failed}: the repo's
// gate facts (GET /api/pr-state/gate) and its failed lead_review_requests
// rows. A read that failed is said as such, never as "not failed".
export function LeadReviewFailedLine({ number, liveHead, state }) {
  if (!state || !liveHead) return null;
  if (state.loading && !state.data) return null;
  const data = state.data;
  const gateRows = data && data.gate && Array.isArray(data.gate.rows) ? data.gate.rows : null;
  const requests = data && data.failed && Array.isArray(data.failed.requests) ? data.failed.requests : null;
  if (!gateRows || !requests) {
    return html`<div class="footnote"><span>lead review state unreadable${state.error ? ` (${state.error.message || state.error})` : ''}</span></div>`;
  }
  const gateRow = gateRows.find((g) => g && Number(g.number) === Number(number)) || null;
  const hit = leadReviewFailure({ liveHead, number, gateRow, failedRequests: requests });
  if (!hit) {
    return !gateRow && data.failed.truncated
      ? html`<div class="footnote"><span>no gate facts for this PR, and only the oldest failed lead review rows were read</span></div>`
      : null;
  }
  return html`
    <div class="banner" role="status" data-lead-review-failed>
      <span>Lead review failed: <b>${hit.detail || 'no detail recorded'}</b>
        ${hit.job_id ? html` · <${Link} to=${`/jobs/${encodeURIComponent(hit.job_id)}`}>job<//>` : null}</span>
      <${Link} to="/lead-reviews" class="btn btn--sm" style="margin-left:auto">LEAD REVIEWS<//>
    </div>`;
}
