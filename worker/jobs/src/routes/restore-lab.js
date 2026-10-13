// restore-lab routes — BH-1944 (BH-1909.2) on the BH-1942 contract.
//
// The console asks for a dry-run restore of one box's off-box backup, the hub's
// bin/restore-lab.sh claims it, restores it into a /tmp scratch dir and posts
// the verdict. The one store is restore_lab_runs (schema.sql); every write here
// is a compare-and-swap judged by meta.changes, never by a read before it.
//
// POST /api/hub/restore-lab   body {box, snapshot='latest', actor, confirm}
//   - confirm is not the literal true → 400 {error:"confirm_required"} and ONE
//     restore_lab_refused audit row (actor "unknown" when none is given, so an
//     unconfirmed attempt is still on the record). No run row.
//   - box not [A-Za-z0-9._-]{1,64} → 400; snapshot not 'latest' or
//     YYYYMMDDTHHMMSSZ → 400; box without a box_status row → 409
//     {error:"unknown_box"}. None of these three is audited.
//   - otherwise INSERT OR IGNORE the run and its restore_lab_request audit row
//     in ONE batch → 201 {id, status, run, deduped:false}. An open run for the
//     same (box, snapshot) — the restore_lab_runs_open partial unique index —
//     is not an error: 200 {id, status, run, deduped:true} with that run's id.
//
// GET /api/hub/restore-lab
//   → 200 {runs:[…last 20, newest first…], truncated:boolean, as_of}
//   This is where restore-lab history lives; GET /api/hub/recovery does not carry it.
//
// POST /api/hub/restore-lab/claim   body {claimer}
//   → 200 {run} for the oldest `requested` run, or a `claimed` one whose
//   claimed_at is older than the settings row restore_lab_claim_ttl_s (fallback
//   1800 s); 200 {run:null} when there is none or the CAS lost the race.
//
// POST /api/hub/restore-lab/:id/result   (:id = \d+)
//   body {claimer, ok, detail, sha256, snapshot_ts}
//   - ok must be the JSON literal true or false. ok:true needs sha256
//     (64 lowercase hex) AND snapshot_ts (YYYYMMDDTHHMMSSZ): a success nothing
//     verified cannot be recorded. detail is a string ≤500 chars or null.
//   → 200 {ok:true, run}, or 409 {error:"not_claimed_by_you"} unless the row is
//     `claimed` BY this claimer (a wrong claimer, a finished run, an unknown id).
//
// `claim` is listed before the :id regexp; \d+ cannot match it either way.

import { json, d1Guarded } from "../lib/http.js";
import { laneName, strictInt, isoPlusSeconds } from "../lib/core.js";
import { confirmed, auditStmt, knownBox } from "../lib/hub-recovery.js";

const STAMP_RE = /^\d{8}T\d{6}Z$/;
const SHA_RE = /^[0-9a-f]{64}$/;
const HISTORY_LIMIT = 20;
// Fallback for the operator's settings row. THE ROW WINS whenever it parses as
// a positive int; this is what a D1 without the row uses. bin/restore-lab.sh
// keeps its restore timeout (RESTORE_LAB_TIMEOUT_S, 1500) below it.
const CLAIM_TTL_S = 1800;

async function claimTtl(env) {
  const v = await env.DB.prepare("SELECT value FROM settings WHERE key='restore_lab_claim_ttl_s'").first("value");
  const n = strictInt(v);
  return n !== null && n > 0 ? n : CLAIM_TTL_S;
}

const runById = (env, id) => env.DB.prepare("SELECT * FROM restore_lab_runs WHERE id=?1").bind(id).first();

// A present value must match; absent (undefined/null) is only allowed where the
// caller says so.
const optional = (v, re) => v === undefined || v === null || (typeof v === "string" && re.test(v));

export const routes = [
  ["POST", "/api/hub/restore-lab", ({ env, t, body }) => d1Guarded("restore_lab_runs", async () => {
    const actor = laneName(body.actor) || "unknown";
    const rawBox = typeof body.box === "string" ? body.box.slice(0, 64) : null;
    if (!confirmed(body)) {
      await env.DB.batch([auditStmt(env, { action: "restore_lab_refused", target: rawBox, actor, outcome: "refused:confirm" }, t)]);
      return json(400, { error: "confirm_required" });
    }
    const box = typeof body.box === "string" ? laneName(body.box) : "";
    if (!box) return json(400, { error: "box is required and must match [A-Za-z0-9._-]{1,64}" });
    const snapshot = body.snapshot ?? "latest";
    if (typeof snapshot !== "string" || (snapshot !== "latest" && !STAMP_RE.test(snapshot))) {
      return json(400, { error: "snapshot must be 'latest' or YYYYMMDDTHHMMSSZ" });
    }
    if (!(await knownBox(env, box))) return json(409, { error: "unknown_box" });
    const res = await env.DB.batch([
      env.DB.prepare(
        "INSERT OR IGNORE INTO restore_lab_runs (box,snapshot,status,requested_by,requested_at) VALUES (?1,?2,'requested',?3,?4)",
      ).bind(box, snapshot, actor, t),
      auditStmt(env, { action: "restore_lab_request", target: box, actor, outcome: "ok" }, t),
    ]);
    const deduped = Number(res[0]?.meta?.changes || 0) === 0;
    const run = await env.DB.prepare(
      "SELECT * FROM restore_lab_runs WHERE box=?1 AND snapshot=?2 AND status IN ('requested','claimed') ORDER BY id DESC LIMIT 1",
    ).bind(box, snapshot).first();
    if (!run) return json(503, { error: "restore_lab_runs unavailable", detail: "the open run was not readable after its insert" });
    return json(deduped ? 200 : 201, { id: run.id, status: run.status, run, deduped });
  })],

  ["GET", "/api/hub/restore-lab", ({ env, t }) => d1Guarded("restore_lab_runs", async () => {
    const rows = (await env.DB.prepare("SELECT * FROM restore_lab_runs ORDER BY id DESC LIMIT ?1")
      .bind(HISTORY_LIMIT + 1).all()).results || [];
    return json(200, { runs: rows.slice(0, HISTORY_LIMIT), truncated: rows.length > HISTORY_LIMIT, as_of: t });
  })],

  ["POST", "/api/hub/restore-lab/claim", ({ env, t, body }) => d1Guarded("restore_lab_runs", async () => {
    const claimer = typeof body.claimer === "string" ? laneName(body.claimer) : "";
    if (!claimer) return json(400, { error: "claimer is required and must match [A-Za-z0-9._-]{1,64}" });
    const cutoff = isoPlusSeconds(t, -(await claimTtl(env)));
    const cand = await env.DB.prepare(
      "SELECT id FROM restore_lab_runs WHERE status='requested' OR (status='claimed' AND claimed_at < ?1) ORDER BY id LIMIT 1",
    ).bind(cutoff).first("id");
    if (cand === null) return json(200, { run: null });
    const r = await env.DB.prepare(
      "UPDATE restore_lab_runs SET status='claimed', claimed_by=?1, claimed_at=?2 WHERE id=?3 AND (status='requested' OR (status='claimed' AND claimed_at < ?4))",
    ).bind(claimer, t, cand, cutoff).run();
    if (Number(r?.meta?.changes || 0) === 0) return json(200, { run: null });
    return json(200, { run: await runById(env, cand) });
  })],

  ["POST", /^\/api\/hub\/restore-lab\/(\d+)\/result$/, ({ env, t, body, m }) => d1Guarded("restore_lab_runs", async () => {
    const id = Number(m[1]);
    const claimer = typeof body.claimer === "string" ? laneName(body.claimer) : "";
    if (!claimer) return json(400, { error: "claimer is required and must match [A-Za-z0-9._-]{1,64}" });
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
      "UPDATE restore_lab_runs SET status=?1, finished_at=?2, verdict_detail=?3, sha256=?4, snapshot_ts=?5 WHERE id=?6 AND status='claimed' AND claimed_by=?7",
    ).bind(body.ok ? "ok" : "fail", t, detail, body.sha256 ?? null, body.snapshot_ts ?? null, id, claimer).run();
    if (Number(r?.meta?.changes || 0) === 0) return json(409, { error: "not_claimed_by_you" });
    return json(200, { ok: true, run: await runById(env, id) });
  })],
];
