// The OUTCOMES screen's pure logic. Kept out of the screen because this is the
// half where a regression is SILENT: a denominator that quietly counts a PR
// twice, a week bucket that lands a Sunday in the wrong week, a rate that
// exceeds 1 because one PR was both reverted and reopened.
//
// ONE THING THIS FILE DELIBERATELY DOES NOT DO: decide whether a repo is
// tightened. That rule lives in bin/review-tighten.sh and nowhere else — a
// second implementation here would disagree with the one that actually parks
// PRs the first run after somebody edits a threshold. The gate column reads
// `tightened` off the review_gate row the detector wrote, and the numbers
// beside it are DESCRIPTIVE: how the fleet is doing right now, over whatever
// window the operator is looking at, which is a different question from the
// one the gate answered on its own schedule.

// The findings bin/outcome-metrics.sh writes. `merged_then_red` is tracked and
// shown but is NOT part of the revert/reopen rate — same split as the detector.
export const BAD_OUTCOMES = ['reverted', 'reopened'];
export const ALL_OUTCOMES = ['reverted', 'reopened', 'merged_then_red'];

const OUTCOME_LABEL = {
  reverted: 'REVERTED',
  reopened: 'REOPENED',
  merged_then_red: 'MAIN WENT RED'
};
export const outcomeLabel = (o) =>
  OUTCOME_LABEL[o] || (o ? String(o).toUpperCase().replace(/_/g, ' ') : 'UNKNOWN');

// reverted and reopened are the two that mean "this merge did not hold" and are
// what the gate acts on. main-red is a warning, so it gets the softer tone.
const OUTCOME_TONE = { reverted: 'dead', reopened: 'dead', merged_then_red: 'warn' };
export const outcomeTone = (o) => OUTCOME_TONE[o] || 'muted';

// https://github.com/<owner>/<name>/pull/<n> -> "<owner>/<name>". Untrusted
// input: these urls arrive in D1 from a shell script, so anything that is not
// exactly a github pull url yields null rather than a guessed slug.
export function repoFromPrUrl(url) {
  if (!url || typeof url !== 'string') return null;
  const m = url.match(/^https:\/\/github\.com\/([^/]+\/[^/]+)\/pull\/\d+(?:[/?#].*)?$/);
  return m ? m[1] : null;
}

export function prNumber(url) {
  if (!url || typeof url !== 'string') return null;
  const m = url.match(/^https:\/\/github\.com\/[^/]+\/[^/]+\/pull\/(\d+)(?:[/?#].*)?$/);
  return m ? Number(m[1]) : null;
}

// A timestamp we cannot read is NOT "recent". Every window test here excludes
// the unreadable row, because including it would inflate the denominator the
// revert rate is divided by with a merge nobody can place in time.
export function withinDays(iso, days, now = Date.now()) {
  if (!iso || typeof iso !== 'string') return false;
  const t = Date.parse(iso);
  if (Number.isNaN(t)) return false;
  return t >= now - days * 86400000 && t <= now + 86400000;
}

// The UTC Monday that starts the ISO week containing `iso`, as YYYY-MM-DD.
export function weekStart(iso) {
  if (!iso) return null;
  const d = new Date(`${String(iso).slice(0, 10)}T00:00:00Z`);
  if (Number.isNaN(d.getTime())) return null;
  // getUTCDay() is 0 for Sunday, which belongs to the week that STARTED six
  // days earlier — the off-by-one that puts every Sunday in the wrong bucket.
  const dow = (d.getUTCDay() + 6) % 7;
  d.setUTCDate(d.getUTCDate() - dow);
  return d.toISOString().slice(0, 10);
}

const num = (v) => {
  if (v === null || v === undefined || v === '') return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
};

// ── merged PRs, per repo, inside the view window ─────────────────────────────
// Only `merged` counts. parked / flagged / failed-alerted rows never reached
// main, so asking whether they held is a question with no subject.
export function mergedInWindow(merges, days, now = Date.now()) {
  const byRepo = new Map();
  for (const m of merges || []) {
    if (!m || m.status !== 'merged') continue;
    const repo = repoFromPrUrl(m.key);
    if (!repo) continue;
    if (!withinDays(m.updated_at || m.created_at, days, now)) continue;
    if (!byRepo.has(repo)) byRepo.set(repo, new Map());
    byRepo.get(repo).set(m.key, m);
  }
  return byRepo;
}

// ── the per-repo table ───────────────────────────────────────────────────────
// `bad` counts DISTINCT PRs, never finding rows: a PR that was reverted AND
// reopened is one merge that did not hold, and counting rows would let a rate
// exceed 1 and read as 150%.
export function perRepo({ merges, outcomes, prCosts, gates }, days, now = Date.now()) {
  const merged = mergedInWindow(merges, days, now);
  const gateBy = new Map((gates || []).filter((g) => g && g.repo).map((g) => [g.repo, g]));

  const cost = new Map();
  for (const c of prCosts || []) {
    const repo = repoFromPrUrl(c && c.pr_url);
    if (!repo) continue;
    // Priced only where the PR is in the window's merged set, so the cost
    // column answers "what did these landings cost", not "what has this repo
    // ever cost" beside a 14-day rate.
    const inWindow = merged.get(repo);
    if (!inWindow || !inWindow.has(c.pr_url)) continue;
    const usd = num(c.cost_usd);
    if (usd === null) continue;
    const prev = cost.get(repo) || { usd: 0, priced: 0 };
    cost.set(repo, { usd: prev.usd + usd, priced: prev.priced + 1 });
  }

  const badPrs = new Map();
  const counts = new Map();
  for (const o of outcomes || []) {
    if (!o || !o.pr || !o.outcome) continue;
    const repo = repoFromPrUrl(o.pr) || o.repo;
    const inWindow = merged.get(repo);
    if (!inWindow || !inWindow.has(o.pr)) continue;
    const c = counts.get(repo) || { reverted: 0, reopened: 0, merged_then_red: 0 };
    if (c[o.outcome] !== undefined) c[o.outcome] += 1;
    counts.set(repo, c);
    if (BAD_OUTCOMES.includes(o.outcome)) {
      if (!badPrs.has(repo)) badPrs.set(repo, new Set());
      badPrs.get(repo).add(o.pr);
    }
  }

  const rows = [];
  for (const [repo, prs] of merged) {
    const c = counts.get(repo) || { reverted: 0, reopened: 0, merged_then_red: 0 };
    const bad = (badPrs.get(repo) || new Set()).size;
    const money = cost.get(repo) || { usd: 0, priced: 0 };
    const gate = gateBy.get(repo) || null;
    rows.push({
      repo,
      merged: prs.size,
      reverted: c.reverted,
      reopened: c.reopened,
      mainRed: c.merged_then_red,
      bad,
      rate: prs.size ? bad / prs.size : null,
      costUsd: money.priced ? money.usd : null,
      pricedPrs: money.priced,
      // A cost-per-PR over the PRICED PRs, not over every merge: dividing by
      // merges the rollup never priced would report a number that goes DOWN
      // when attribution gets worse.
      costPerPr: money.priced ? money.usd / money.priced : null,
      gate,
      tightened: Boolean(gate && Number(gate.tightened) === 1)
    });
  }
  return rows;
}

// ── the weekly burn trend ────────────────────────────────────────────────────
// burn_days is one row per UTC day. A week with fewer than seven measured days
// says so rather than reading as a cheap week: `days` rides on the row and the
// delta against the prior week is only computed when BOTH weeks are complete,
// because "burn halved" is otherwise just "the tracker missed four days".
export function weeklyBurn(burnDays) {
  const weeks = new Map();
  for (const d of burnDays || []) {
    const wk = weekStart(d && d.day);
    if (!wk) continue;
    const w = weeks.get(wk) || { week: wk, days: 0, usd: 0, output: 0, peakCacheRead: 0, apiCalls: 0 };
    w.days += 1;
    w.usd += num(d.usd_equiv) || 0;
    w.output += num(d.output) || 0;
    w.apiCalls += num(d.api_calls) || 0;
    w.peakCacheRead = Math.max(w.peakCacheRead, num(d.peak_cache_read) || 0);
    weeks.set(wk, w);
  }
  const rows = [...weeks.values()].sort((a, b) => (a.week < b.week ? 1 : a.week > b.week ? -1 : 0));
  const max = rows.reduce((m, r) => Math.max(m, r.usd), 0);
  return rows.map((r, i) => {
    const prev = rows[i + 1];
    const comparable = Boolean(prev) && r.days === 7 && prev.days === 7;
    return {
      ...r,
      complete: r.days === 7,
      deltaUsd: comparable ? r.usd - prev.usd : null,
      deltaPct: comparable && prev.usd > 0 ? (r.usd - prev.usd) / prev.usd : null,
      share: max > 0 ? r.usd / max : 0
    };
  });
}

// ── the findings list ────────────────────────────────────────────────────────
// One row per finding, joined to what that PR cost and to the job that built
// it, so every row can be clicked into something concrete rather than ending at
// a repo name.
export function findingRows({ outcomes, prCosts, merges }) {
  const costBy = new Map((prCosts || []).filter((c) => c && c.pr_url).map((c) => [c.pr_url, c]));
  const mergeBy = new Map((merges || []).filter((m) => m && m.key).map((m) => [m.key, m]));
  return (outcomes || [])
    .filter((o) => o && o.pr && o.outcome)
    .map((o) => {
      const cost = costBy.get(o.pr) || null;
      const merge = mergeBy.get(o.pr) || null;
      return {
        ...o,
        repo: repoFromPrUrl(o.pr) || o.repo || null,
        number: prNumber(o.pr),
        costUsd: cost ? num(cost.cost_usd) : null,
        jobId: merge && merge.job_id ? merge.job_id : null,
        mergedAt: merge ? merge.updated_at || merge.created_at : null
      };
    });
}

// ── the costliest landings ───────────────────────────────────────────────────
export function costRows({ prCosts, merges, outcomes }, days, now = Date.now()) {
  const merged = mergedInWindow(merges, days, now);
  const inWindow = new Map();
  for (const [, prs] of merged) for (const [url, m] of prs) inWindow.set(url, m);
  const badBy = new Map();
  for (const o of outcomes || []) {
    if (!o || !o.pr || !o.outcome) continue;
    const list = badBy.get(o.pr) || [];
    list.push(o.outcome);
    badBy.set(o.pr, list);
  }
  return (prCosts || [])
    .filter((c) => c && c.pr_url && inWindow.has(c.pr_url))
    .map((c) => {
      const m = inWindow.get(c.pr_url);
      return {
        pr: c.pr_url,
        repo: repoFromPrUrl(c.pr_url),
        number: prNumber(c.pr_url),
        costUsd: num(c.cost_usd),
        stageBreakdown: c.stage_breakdown || null,
        jobId: m && m.job_id ? m.job_id : null,
        mergedAt: m ? m.updated_at || m.created_at : null,
        outcomes: badBy.get(c.pr_url) || []
      };
    });
}

// ── the strip over the tables ────────────────────────────────────────────────
// Every count is of the rows IN VIEW, so a filtered window reports the filtered
// set and never the whole ledger behind it.
export function summarise(repoRows, gates) {
  const merged = repoRows.reduce((n, r) => n + r.merged, 0);
  const bad = repoRows.reduce((n, r) => n + r.bad, 0);
  const priced = repoRows.reduce((n, r) => n + r.pricedPrs, 0);
  const usd = repoRows.reduce((n, r) => n + (r.costUsd || 0), 0);
  return {
    repos: repoRows.length,
    merged,
    bad,
    mainRed: repoRows.reduce((n, r) => n + r.mainRed, 0),
    // The fleet rate is bad/merged over the whole view, NOT the mean of the
    // per-repo rates: averaging rates would give a repo with two merges the
    // same weight as one with sixty.
    rate: merged ? bad / merged : null,
    usd: priced ? usd : null,
    pricedPrs: priced,
    costPerPr: priced ? usd / priced : null,
    tightened: (gates || []).filter((g) => g && Number(g.tightened) === 1).length
  };
}

export const pct = (r) =>
  r === null || r === undefined || !Number.isFinite(Number(r)) ? '—' : `${(Number(r) * 100).toFixed(0)}%`;

// The thresholds ladder, for DISPLAY only: which row the detector would have
// resolved for this repo. It never decides anything — the decision is already
// on the gate row — so it has no fallback constants of its own to drift from
// the ones in bin/review-tighten.sh.
export function thresholdFor(thresholds, repo) {
  const list = thresholds || [];
  return list.find((t) => t && t.scope === repo) || list.find((t) => t && t.scope === '*') || null;
}
