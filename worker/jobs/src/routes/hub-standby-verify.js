// hub-standby-verify routes — BH-2639 (BH-2519.1) on the BH-2519 contract.
//
// The console asks a standby box to prove it can restore its hub's latest
// snapshot; the standby's own lane claims the run, does a dry-run scratch
// restore and posts the verdict. Shaped like restore-lab.js over its own store,
// standby_verify_runs (schema.sql); every write is a compare-and-swap judged by
// meta.changes.
//
// THE CLAIMER IS THE BOX. standby_verify_runs has no claimed_by column: a run
// belongs to the standby named in its `box`, so claim and result both bind
// `box = claimer` in the SQL itself. Another box can neither take a run nor
// post its verdict.
//
// POST /api/hub/standby/verify   body {box, actor, confirm}
//   - confirm is not the literal true → 400 {error:"confirm_required"} and ONE
//     standby_verify_refused audit row (actor "unknown" when none is given).
//     No run row.
//   - box not [A-Za-z0-9._-]{1,64} → 400; box without a standby_status row (it
//     never sent a heartbeat) → 409 {error:"unknown_standby"}. Neither is audited.
//   - otherwise INSERT OR IGNORE the run (of_hub copied from the standby row)
//     and its standby_verify_request audit row in ONE batch → 201 {id, status,
//     run, deduped:false}. An open run for the same box — the
//     standby_verify_runs_open partial unique index — answers 200 {id, status,
//     run, deduped:true} with that run's id.
//
// GET /api/hub/standby/verify
//   → 200 {runs:[…last 20, newest first…], truncated:boolean, as_of}
//
// POST /api/hub/standby/verify/claim   body {claimer}
//   → 200 {run} for the claimer's own oldest `requested` run, or a `claimed`
//   one whose claimed_at is older than the settings row
//   standby_verify_claim_ttl_s (fallback 1800 s); 200 {run:null} when there is
//   none or the CAS lost the race.
//
// POST /api/hub/standby/verify/:id/result   (:id = \d+)
//   body {claimer, ok, detail, sha256, snapshot_ts}
//   - ok must be the JSON literal true or false. ok:true needs sha256
//     (64 lowercase hex) AND snapshot_ts (YYYYMMDDTHHMMSSZ). detail is a
//     string ≤500 chars or null.
//   → 200 {ok:true, run}, or 409 {error:"not_claimed_by_you"} unless the row is
//     `claimed` and its box is this claimer (another box, a finished run, an
//     unknown id).
//
// `claim` is listed before the :id regexp; \d+ cannot match it either way.

import { json, d1Guarded } from "../lib/http.js";
import { laneName, strictInt, isoPlusSeconds } from "../lib/core.js";
import { confirmed, auditStmt } from "../lib/hub-recovery.js";

const STAMP_RE = /^\d{8}T\d{6}Z$/;
const SHA_RE = /^[0-9a-f]{64}$/;
const HISTORY_LIMIT = 20;
// Fallback for the operator's settings row. THE ROW WINS whenever it parses as
// a positive int; this is what a D1 without the row uses.
const CLAIM_TTL_S = 1800;

async function claimTtl(env) {
  const v = await env.DB.prepare("SELECT value FROM settings WHERE key='standby_verify_claim_ttl_s'").first("value");
  const n = strictInt(v);
  return n !== null && n > 0 ? n : CLAIM_TTL_S;
}

const runById = (env, id) => env.DB.prepare("SELECT * FROM standby_verify_runs WHERE id=?1").bind(id).first();
const claimerOf = (body) => (typeof body.claimer === "string" ? laneName(body.claimer) : "");
const CLAIMER_ERR = { error: "claimer is required and must match [A-Za-z0-9._-]{1,64}" };

// A present value must match; absent (undefined/null) is allowed.
const optional = (v, re) => v === undefined || v === null || (typeof v === "string" && re.test(v));

export const routes = [
  ["POST", "/api/hub/standby/verify", ({ env, t, body }) => d1Guarded("standby_verify_runs", async () => {
    const actor = laneName(body.actor) || "unknown";
    const rawBox = typeof body.box === "string" ? body.box.slice(0, 64) : null;
    if (!confirmed(body)) {
      await env.DB.batch([auditStmt(env, { action: "standby_verify_refused", target: rawBox, actor, outcome: "refused:confirm" }, t)]);
      return json(400, { error: "confirm_required" });
    }
    const box = typeof body.box === "string" ? laneName(body.box) : "";
    if (!box) return json(400, { error: "box is required and must match [A-Za-z0-9._-]{1,64}" });
    const ofHub = await env.DB.prepare("SELECT of_hub FROM standby_status WHERE box=?1").bind(box).first("of_hub");
    if (ofHub === null) return json(409, { error: "unknown_standby" });
    const res = await env.DB.batch([
      env.DB.prepare(
        "INSERT OR IGNORE INTO standby_verify_runs (box,of_hub,status,requested_by,requested_at) VALUES (?1,?2,'requested',?3,?4)",
      ).bind(box, ofHub, actor, t),
      auditStmt(env, { action: "standby_verify_request", target: box, actor, outcome: "ok" }, t),
    ]);
    const deduped = Number(res[0]?.meta?.changes || 0) === 0;
    const run = await env.DB.prepare(
      "SELECT * FROM standby_verify_runs WHERE box=?1 AND status IN ('requested','claimed') ORDER BY id DESC LIMIT 1",
    ).bind(box).first();
    if (!run) return json(503, { error: "standby_verify_runs unavailable", detail: "the open run was not readable after its insert" });
    return json(deduped ? 200 : 201, { id: run.id, status: run.status, run, deduped });
  })],

  ["GET", "/api/hub/standby/verify", ({ env, t }) => d1Guarded("standby_verify_runs", async () => {
    const rows = (await env.DB.prepare("SELECT * FROM standby_verify_runs ORDER BY id DESC LIMIT ?1")
      .bind(HISTORY_LIMIT + 1).all()).results || [];
    return json(200, { runs: rows.slice(0, HISTORY_LIMIT), truncated: rows.length > HISTORY_LIMIT, as_of: t });
  })],

  ["POST", "/api/hub/standby/verify/claim", ({ env, t, body }) => d1Guarded("standby_verify_runs", async () => {
    const claimer = claimerOf(body);
    if (!claimer) return json(400, CLAIMER_ERR);
    const cutoff = isoPlusSeconds(t, -(await claimTtl(env)));
    const cand = await env.DB.prepare(
      "SELECT id FROM standby_verify_runs WHERE box=?2 AND (status='requested' OR (status='claimed' AND claimed_at < ?1)) ORDER BY id LIMIT 1",
    ).bind(cutoff, claimer).first("id");
    if (cand === null) return json(200, { run: null });
    const r = await env.DB.prepare(
      "UPDATE standby_verify_runs SET status='claimed', claimed_at=?2 WHERE id=?3 AND box=?1 AND (status='requested' OR (status='claimed' AND claimed_at < ?4))",
    ).bind(claimer, t, cand, cutoff).run();
    if (Number(r?.meta?.changes || 0) === 0) return json(200, { run: null });
    return json(200, { run: await runById(env, cand) });
  })],

  ["POST", /^\/api\/hub\/standby\/verify\/(\d+)\/result$/, ({ env, t, body, m }) => d1Guarded("standby_verify_runs", async () => {
    const id = Number(m[1]);
    const claimer = claimerOf(body);
    if (!claimer) return json(400, CLAIMER_ERR);
    if (body.ok !== true && body.ok !== false) return json(400, { error: "ok must be true or false" });
    if (body.ok === true && !(typeof body.sha256 === "string" && SHA_RE.test(body.sha256)
      && typeof body.snapshot_ts === "string" && STAMP_RE.test(body.snapshot_ts))) {
      return json(400, { error: "ok:true needs sha256 (64 hex) and snapshot_ts (YYYYMMDDTHHMMSSZ)" });
    }
    if (!optional(body.sha256, SHA_RE)) return json(400, { error: "sha256 must be 64 lowercase hex" });
    if (!optional(body.snapshot_ts, STAMP_RE)) return json(400, { error: "snapshot_ts must be YYYYMMDDTHHMMSSZ" });
    const detail = body.detail ?? null;
    if (detail !== null && !(typeof detail === "string" && detail.length <= 500)) {
      return json(400, { error: "detail must be a string of at most 500 characters" });
    }
    const r = await env.DB.prepare(
      "UPDATE standby_verify_runs SET status=?1, finished_at=?2, verdict_detail=?3, sha256=?4, snapshot_ts=?5 WHERE id=?6 AND status='claimed' AND box=?7",
    ).bind(body.ok ? "ok" : "fail", t, detail, body.sha256 ?? null, body.snapshot_ts ?? null, id, claimer).run();
    if (Number(r?.meta?.changes || 0) === 0) return json(409, { error: "not_claimed_by_you" });
    return json(200, { ok: true, run: await runById(env, id) });
  })],
];
