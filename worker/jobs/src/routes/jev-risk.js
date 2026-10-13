// jev-risk routes — BH-5024 (BH-4973.3): the spend ledger in front of every
// Jev (TypeSafe jev-latest) second opinion on a PR's risk tier.
//
// bin/jev-risk.sh claims (repo, pr, head_sha, question_version) BEFORE it calls
// the vendor and settles it after: ok, empty or failed. ok and empty are
// terminal, so a head already answered is never bought again; failed is retried
// up to jev_risk.max_attempts. A claim older than twice jev_risk.timeout_s is a
// caller that died mid-call, and may be reclaimed (it counts as an attempt).
// Table: jev_risk_calls (schema.sql, BH-5024 block, and the self-create copy
// in CREATED_TABLES).
//
// Jev decides nothing in this wave: the answer is a log line and this row.
// Every supplied field is validated and a junk one is a 400 naming the field,
// never clamped (D11). A settle replayed onto its own status is 200 and writes
// nothing; a different status onto a settled row is 409 (D16).
import { d1Guarded, json } from "../lib/http.js";
import { ensureTable } from "../lib/core.js";
import { REPO_RE, prOf, shaOf } from "./verdicts.js";

const TIERS = ["low", "medium", "high"];
const SETTLE = ["ok", "empty", "failed"];
const TERMINAL = ["ok", "empty"];
const QV_RE = /^v[0-9]{1,4}$/;
const CALLER_RE = /^[a-z][a-z0-9:._-]{0,63}$/;
const MODEL_RE = /^[A-Za-z0-9._:-]{1,64}$/;
const RAW_MAX = 8000;
const LIST_DEFAULT = 50;
const LIST_MAX = 200;

const guarded = (fn) => (ctx) =>
  d1Guarded("jev_risk_calls", async () => {
    await ensureTable(ctx.env, "jev_risk_calls");
    return fn(ctx);
  });

// A positive-integer settings row, else the documented fallback. An unreadable
// settings table is the fallback too: the cap and the timeout are guards, and
// their seeded values are the fallbacks.
async function knob(env, key, fallback) {
  try {
    const r = await env.DB.prepare("SELECT value FROM settings WHERE key=?1").bind(key).first();
    const v = r && typeof r.value === "string" ? r.value.trim() : "";
    return /^[1-9][0-9]{0,5}$/.test(v) ? Number(v) : fallback;
  } catch {
    return fallback;
  }
}

// The key, validated and normalised once (the sha lowercased, D17).
function keyOf(b) {
  const repo = typeof b.repo === "string" ? b.repo.trim() : "";
  if (!REPO_RE.test(repo)) return { err: "repo must be owner/name" };
  const pr = prOf(b.pr);
  if (pr === null) return { err: "pr must be a positive integer" };
  const head_sha = shaOf(b.head_sha);
  if (!head_sha) return { err: "head_sha must be a full 40-hex commit sha" };
  if (typeof b.question_version !== "string" || !QV_RE.test(b.question_version)) {
    return { err: "question_version must be v<digits>" };
  }
  return { repo, pr, head_sha, qv: b.question_version };
}

const readRow = (env, k) =>
  env.DB.prepare(
    "SELECT * FROM jev_risk_calls WHERE repo=?1 AND pr=?2 AND head_sha=?3 AND question_version=?4"
  ).bind(k.repo, k.pr, k.head_sha, k.qv).first();

export const routes = [
  // ── POST /api/jev-risk/claim ────────────────────────────────────────────
  // ONE conditional upsert. Absent -> claimed, attempts 1, 201. failed, or a
  // stale claimed, under max_attempts -> attempts+1, claimed, 200. Anything
  // else writes nothing: 409 terminal | in_flight | attempt_cap, with the row.
  [
    "POST", "/api/jev-risk/claim",
    guarded(async ({ env, t, body }) => {
      const b = body && typeof body === "object" ? body : {};
      const k = keyOf(b);
      if (k.err) return json(400, { error: k.err });
      if (!TIERS.includes(b.rule_tier)) return json(400, { error: `rule_tier must be one of ${TIERS.join(", ")}` });
      if (typeof b.caller !== "string" || !CALLER_RE.test(b.caller)) {
        return json(400, { error: "caller must be shadow:<box> or pilot ([a-z0-9:._-], <= 64 chars)" });
      }
      const model = b.model === undefined || b.model === null ? null : b.model;
      if (model !== null && (typeof model !== "string" || !MODEL_RE.test(model))) {
        return json(400, { error: "model must be [A-Za-z0-9._:-], <= 64 chars" });
      }
      const max = await knob(env, "jev_risk.max_attempts", 2);
      const timeoutS = await knob(env, "jev_risk.timeout_s", 30);
      const stale = new Date(Date.parse(t) - 2 * timeoutS * 1000).toISOString();
      const r = await env.DB.prepare(
        `INSERT INTO jev_risk_calls (repo, pr, head_sha, question_version, status, attempts, rule_tier, model, caller,
                                     claimed_at, created_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, 'claimed', 1, ?5, ?6, ?7, ?8, ?8, ?8)
         ON CONFLICT(repo, pr, head_sha, question_version) DO UPDATE SET
                status = 'claimed', attempts = jev_risk_calls.attempts + 1, rule_tier = excluded.rule_tier,
                model = excluded.model, caller = excluded.caller, error = NULL,
                claimed_at = excluded.claimed_at, updated_at = excluded.updated_at
          WHERE jev_risk_calls.attempts < ?9
            AND (jev_risk_calls.status = 'failed'
                 OR (jev_risk_calls.status = 'claimed' AND jev_risk_calls.claimed_at < ?10))`
      ).bind(k.repo, k.pr, k.head_sha, k.qv, b.rule_tier, model, b.caller, t, max, stale).run();
      const row = await readRow(env, k);
      if (!row) return json(503, { error: "jev_risk_calls unavailable", detail: "the claim left no row" });
      if (Number((r.meta && r.meta.changes) || 0) === 1) {
        return json(row.attempts === 1 ? 201 : 200, { ok: true, row });
      }
      if (TERMINAL.includes(row.status)) return json(409, { error: "terminal", status: row.status, row });
      if (row.status === "claimed" && !(row.claimed_at < stale)) {
        return json(409, { error: "in_flight", status: row.status, row });
      }
      return json(409, { error: "attempt_cap", status: row.status, row });
    }),
  ],

  // ── POST /api/jev-risk/settle ───────────────────────────────────────────
  // From claimed only, and only by the claim it names: `attempts` is the
  // claimant's attempt number and the update is fenced on it. A caller whose
  // claim went stale and was reclaimed gets 409 superseded, so its late settle
  // cannot overwrite (and so discard) the paid answer of the claim that
  // replaced it. ok carries jev_tier and 0 <= jev_prob <= 1; empty and failed
  // carry neither. raw is cut at 8000 chars.
  [
    "POST", "/api/jev-risk/settle",
    guarded(async ({ env, t, body }) => {
      const b = body && typeof body === "object" ? body : {};
      const k = keyOf(b);
      if (k.err) return json(400, { error: k.err });
      if (!SETTLE.includes(b.status)) return json(400, { error: `status must be one of ${SETTLE.join(", ")}` });
      if (!Number.isInteger(b.attempts) || b.attempts < 1) {
        return json(400, { error: "attempts must be the claim's attempt number, a positive integer" });
      }
      const hasTier = b.jev_tier !== undefined && b.jev_tier !== null;
      const hasProb = b.jev_prob !== undefined && b.jev_prob !== null;
      if (b.status === "ok") {
        if (!TIERS.includes(b.jev_tier)) return json(400, { error: `ok needs jev_tier, one of ${TIERS.join(", ")}` });
        if (typeof b.jev_prob !== "number" || !Number.isFinite(b.jev_prob) || b.jev_prob < 0 || b.jev_prob > 1) {
          return json(400, { error: "ok needs jev_prob, a number in [0, 1]" });
        }
      } else if (hasTier || hasProb) {
        return json(400, { error: `${b.status} carries no jev_tier or jev_prob` });
      }
      if (b.error !== undefined && b.error !== null && typeof b.error !== "string") return json(400, { error: "error must be a string" });
      if (b.raw !== undefined && b.raw !== null && typeof b.raw !== "string") return json(400, { error: "raw must be a string" });
      const error = typeof b.error === "string" && b.error !== "" ? b.error.slice(0, 500) : null;
      const raw = typeof b.raw === "string" ? b.raw.slice(0, RAW_MAX) : null;
      const ok = b.status === "ok";
      const r = await env.DB.prepare(
        `UPDATE jev_risk_calls SET status = ?5, jev_tier = ?6, jev_prob = ?7, error = ?8, raw = COALESCE(?9, raw),
                updated_at = ?10
          WHERE repo = ?1 AND pr = ?2 AND head_sha = ?3 AND question_version = ?4 AND status = 'claimed'
            AND attempts = ?11`
      ).bind(k.repo, k.pr, k.head_sha, k.qv, b.status, ok ? b.jev_tier : null, ok ? b.jev_prob : null,
        error, raw, t, b.attempts).run();
      const row = await readRow(env, k);
      if (!row) return json(404, { error: "no claim for this head" });
      if (Number((r.meta && r.meta.changes) || 0) === 1) return json(200, { ok: true, row });
      if (row.status === "claimed") {
        return json(409, { error: "superseded", detail: `claim attempt ${b.attempts} was replaced by attempt ${row.attempts}`, status: row.status, row });
      }
      if (row.status === b.status) return json(200, { ok: true, replay: true, row });
      return json(409, { error: `this head is ${row.status}, not claimed`, status: row.status, row });
    }),
  ],

  // ── GET /api/jev-risk?repo=&pr=&limit= ──────────────────────────────────
  // Newest first. The limit is refused outside 1..200, never clamped, and
  // `truncated` is measured by reading one row past it.
  [
    "GET", "/api/jev-risk",
    guarded(async ({ env, url, t }) => {
      const repo = (url.searchParams.get("repo") || "").trim();
      if (repo && !REPO_RE.test(repo)) return json(400, { error: "repo must be owner/name" });
      const rawPr = url.searchParams.get("pr");
      const pr = rawPr === null || rawPr === "" ? null : prOf(rawPr);
      if (rawPr && pr === null) return json(400, { error: "pr must be a positive integer" });
      const rawLimit = url.searchParams.get("limit");
      let limit = LIST_DEFAULT;
      if (rawLimit !== null) {
        limit = /^\d+$/.test(rawLimit) ? Number(rawLimit) : NaN;
        if (!(limit >= 1 && limit <= LIST_MAX)) return json(400, { error: `limit must be an integer 1..${LIST_MAX}` });
      }
      const rows = (await env.DB.prepare(
        "SELECT * FROM jev_risk_calls WHERE (?1 IS NULL OR repo = ?1) AND (?2 IS NULL OR pr = ?2)" +
        " ORDER BY id DESC LIMIT ?3"
      ).bind(repo || null, pr, limit + 1).all()).results || [];
      return json(200, { rows: rows.slice(0, limit), truncated: rows.length > limit, as_of: t });
    }),
  ],
];
