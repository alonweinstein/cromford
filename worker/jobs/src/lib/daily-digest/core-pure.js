// daily-digest core, the pure half — BH-3704 (BH-3688 slice 2). No DB, no
// clock: core-sections.js reads the rows and hands them here.
import { percentile, doraMs } from "../core.js";

// The system actor that requeues on its own. Never a human, even if listed.
const WATCHDOG = "jobs-watchdog";

const norm = (s) => (typeof s === "string" ? s.trim().toLowerCase() : "");

// A human is an email-shaped actor or a name the caller lists. Normalized here
// and only here (D17), so the list may arrive un-normalized.
export function isHumanActor(actor, list) {
  const a = norm(actor);
  if (!a || a === WATCHDOG) return false;
  if (a.includes("@")) return true;
  return Array.isArray(list) && list.some((x) => norm(x) === a);
}

// Filing-to-merge for one day's merges. The attribution is computeDora's
// (core.js): a review / review-verdict job built nothing and is skipped, and
// the EARLIEST job on a PR wins, so a rebuild cannot shorten the span. A merge
// with no attributable job, no issue_created_at, a bad stamp or a negative
// span is counted in unmeasured_n and in by_project, never in the median.
export function filingToMerge(merges, artifacts, jobs) {
  const byPr = new Map();
  for (const a of artifacts || []) {
    if (!a || a.job_kind === "review" || a.job_kind === "review-verdict") continue;
    const rec = { project: a.project || null, ticket_id: a.ticket_id || null, at: doraMs(a.job_created_at) };
    const prev = byPr.get(a.artifact_ref);
    if (!prev || (rec.at !== null && (prev.at === null || rec.at < prev.at))) byPr.set(a.artifact_ref, rec);
  }
  const issued = new Map();
  for (const j of jobs || []) issued.set(`${j.project}\u0000${j.ticket_id}`, j.issue_created_at);

  const spans = [];
  let unmeasured = 0;
  const counts = new Map();
  for (const m of merges || []) {
    const att = byPr.get(m.key);
    const project = att?.project ?? null;
    counts.set(project, (counts.get(project) || 0) + 1);
    const issue = att?.ticket_id ? doraMs(issued.get(`${att.project}\u0000${att.ticket_id}`)) : null;
    const merged = doraMs(m.created_at);
    const span = issue === null || merged === null ? null : Math.round((merged - issue) / 1000);
    if (span === null || span < 0) unmeasured += 1;
    else spans.push(span);
  }
  spans.sort((a, b) => a - b);
  const by_project = [...counts].map(([project, merged]) => ({ project, merged })).sort((a, b) =>
    b.merged - a.merged
    || (a.project === null) - (b.project === null)
    || String(a.project).localeCompare(String(b.project)));
  return {
    filing_to_merge: { p50_s: percentile(spans, 50), measured_n: spans.length, unmeasured_n: unmeasured },
    by_project,
  };
}
