// PR gate-fact WRITERS (BH-4954 / BH-4950.1). The contract (pr-gate.js) holds
// the table, the fold and the eligibility rule; this file only turns what three
// existing routes already see into gate events:
//   recordGithubGate    a signed GitHub delivery (routes/webhooks.js)
//   recordBuilderApprove a builder verdict / pr_url artifact put (routes/job-artifacts.js)
//   recordLeadVerdict   a standing row (lead, human, risk-tier) in POST /api/verdicts (routes/verdicts.js)
// Every writer runs AFTER its route's own write and NEVER throws: a lost gate
// write is a console.warn, the route answers exactly as before, and
// bin/pr-state-reconcile.sh heals the fact on its next sweep.
//
// recordGateEvent binds without postGate's validation, so every value is
// checked here: a malformed payload maps to [] and writes nothing.

import { STANDING_SOURCES } from "./verdict-sources.js";
import { WAKE_REPO_RE } from "./core.js";
import { recordGateEvent } from "./pr-gate.js";

const SHA40 = /^[0-9a-f]{40}$/;
const SOURCE_MAX = 64; // postGate's cap on `since`, which is the dedupe key.
const PR_ACTIONS = ["opened", "reopened", "synchronize", "ready_for_review", "converted_to_draft", "closed"];
const PR_URL_RE = /^https:\/\/github\.com\/([^/]+\/[^/]+)\/pull\/(\d+)$/;

// bin/lib/hold.sh's PR-thread grammar (HOLD_LIFT_LINE_RE, HOLD_ABANDON_LINE_RE,
// HOLD_BODY_RE), in its decision order: lift, then abandon, then hold.
const LIFT_RE = /^(RESUME|UNHOLD)(?![A-Za-z0-9_-])/m;
const ABANDON_RE = /^(ABANDON|CLOSE-PR)(?![A-Za-z0-9_-])/m;
const HOLD_RE = /^HOLD[ \t]*(?:[:—–-]|$)/m;
const decide = (s) => (LIFT_RE.test(s) ? "lift" : ABANDON_RE.test(s) ? "abandon" : HOLD_RE.test(s) ? "hold" : null);

const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const prNumber = (v) => (Number.isInteger(v) && v > 0 && v < 1e9 ? v : null);
const sha40 = (v) => {
  const s = typeof v === "string" ? v.toLowerCase() : "";
  return SHA40.test(s) ? s : null;
};

// holdWordOf(body) — "hold" | "abandon" | "lift" | null. The FIRST line's word,
// but only when hold_classify_thread's whole-body `decide` says the same: a
// first-line HOLD with a later RESUME line is a lift to hold.sh, so it records
// nothing here and the sweep settles it.
export function holdWordOf(body) {
  if (typeof body !== "string") return null;
  const text = body.replace(/\r/g, "");
  const first = decide(text.split("\n")[0]);
  return first && first === decide(text) ? first : null;
}

// githubGateEvents(event, payload, deliveryId) — PURE. [] or the gate events
// the delivery proves, each {repo, number, source, reason, actor, url?, ...fields}.
export function githubGateEvents(event, payload, deliveryId) {
  if (!isObj(payload)) return [];
  if (typeof deliveryId !== "string" || !deliveryId || deliveryId.length > SOURCE_MAX) return [];
  const repo = isObj(payload.repository) ? payload.repository.full_name : null;
  if (typeof repo !== "string" || !WAKE_REPO_RE.test(repo)) return [];
  const action = typeof payload.action === "string" ? payload.action : "";
  const base = { repo, source: deliveryId, reason: `webhook:${event}.${action}`.slice(0, 500), actor: "github" };

  if (event === "pull_request") {
    const pr = payload.pull_request;
    if (!isObj(pr)) return [];
    const number = prNumber(pr.number ?? payload.number);
    if (number === null) return [];
    if (action === "labeled" || action === "unlabeled") {
      const name = isObj(payload.label) && typeof payload.label.name === "string" ? payload.label.name : "";
      if (name.toLowerCase() !== "hotfix") return [];
      return [{ ...base, number, hotfix: action === "labeled" ? 1 : 0 }];
    }
    if (!PR_ACTIONS.includes(action)) return [];
    const head = sha40(isObj(pr.head) ? pr.head.sha : null);
    if (!head || typeof pr.draft !== "boolean" || typeof pr.state !== "string") return [];
    const ev = { ...base, number, head, draft: pr.draft ? 1 : 0, closed: pr.state === "closed" ? 1 : 0 };
    if (typeof pr.html_url === "string" && pr.html_url.startsWith("https://github.com/")) ev.url = pr.html_url.slice(0, 512);
    return [ev];
  }

  if (event === "check_suite") {
    const cs = payload.check_suite;
    if (action !== "completed" || !isObj(cs)) return [];
    if (cs.conclusion !== "success" || !isObj(cs.app) || cs.app.slug !== "github-actions") return [];
    const sha = sha40(cs.head_sha);
    if (!sha || !Array.isArray(cs.pull_requests)) return [];
    return cs.pull_requests
      .map((p) => (isObj(p) ? prNumber(p.number) : null))
      .filter((n) => n !== null)
      .map((number) => ({ ...base, number, ci_green_sha: sha }));
  }

  if (event === "issue_comment") {
    if (action !== "created") return [];
    const issue = payload.issue, c = payload.comment;
    if (!isObj(issue) || !isObj(issue.pull_request) || !isObj(c)) return [];
    if (isObj(c.user) && String(c.user.type || "").toLowerCase() === "bot") return [];
    const number = prNumber(issue.number);
    if (number === null) return [];
    const word = holdWordOf(c.body);
    if (!word) return [];
    return [{ ...base, number, held: word === "lift" ? 0 : 1 }];
  }
  return [];
}

export async function recordGithubGate(env, t, event, payload, deliveryId) {
  try {
    let recorded = 0;
    for (const ev of githubGateEvents(event, payload, deliveryId)) {
      if ((await recordGateEvent(env, t, ev)).recorded) recorded += 1;
    }
    return { recorded };
  } catch (e) {
    const error = String((e && e.message) || e).slice(0, 300);
    console.warn("[pr-gate-intake] webhook gate event not recorded", event, error);
    return { recorded: 0, error };
  }
}

// The builder's APPROVE bound to a sha, read off the job's standing rows. Hooked
// on both the verdict and the pr_url put: whichever lands second records it.
export async function recordBuilderApprove(env, t, jobId) {
  try {
    const rows = (await env.DB.prepare(
      "SELECT artifact_kind, artifact_ref, detail FROM job_artifacts WHERE job_id=?1 AND artifact_kind IN ('verdict','pr_url')"
    ).bind(jobId).all()).results || [];
    const v = rows.find((r) => r.artifact_kind === "verdict");
    const u = rows.find((r) => r.artifact_kind === "pr_url");
    if (!v || !u || v.artifact_ref !== "APPROVE") return { recorded: 0 };
    let d = {};
    try { d = JSON.parse(v.detail || "{}") || {}; } catch { d = {}; }
    if (!isObj(d) || d.settled === false) return { recorded: 0 };
    const m = PR_URL_RE.exec(String(u.artifact_ref));
    if (!m || !WAKE_REPO_RE.test(m[1])) return { recorded: 0 };
    const number = prNumber(Number(m[2]));
    if (number === null) return { recorded: 0 };
    const hb = typeof d.headbound === "string" ? /^reapproved@([0-9a-f]{40})$/.exec(d.headbound) : null;
    const sha = hb ? hb[1] : (typeof d.reviewed_sha === "string" && SHA40.test(d.reviewed_sha) ? d.reviewed_sha : null);
    if (!sha) return { recorded: 0 };
    const { recorded } = await recordGateEvent(env, t, {
      repo: m[1], number, source: `approve@${sha}`, reason: `builder-verdict:${String(jobId).slice(0, 40)}`,
      actor: "worker", builder_approved_sha: sha,
    });
    return { recorded: recorded ? 1 : 0 };
  } catch (e) {
    const error = String((e && e.message) || e).slice(0, 300);
    console.warn("[pr-gate-intake] builder approve not recorded", jobId, error);
    return { recorded: 0, error };
  }
}

// A standing row of POST /api/verdicts (lead, human or risk-tier: the one
// STANDING_SOURCES list), already validated and INSERTed. The reconcile sweep
// reads vd_standing, which counts the same sources, so the two writers agree.
export async function recordLeadVerdict(env, t, row) {
  try {
    if (!row || !STANDING_SOURCES.includes(row.source)) return { recorded: 0 };
    const { recorded } = await recordGateEvent(env, t, {
      repo: row.repo, number: row.pr, source: `verdict#${row.id}`, reason: `verdict:${row.source}`,
      actor: "worker", lead_verdict_sha: row.head_sha, lead_verdict_word: row.verdict,
    });
    return { recorded: recorded ? 1 : 0 };
  } catch (e) {
    const error = String((e && e.message) || e).slice(0, 300);
    console.warn("[pr-gate-intake] lead verdict not recorded", row && row.id, error);
    return { recorded: 0, error };
  }
}
