// ci-test-tiers routes — BH-5653 slice C1 (BH-5637.2): catalog/test-tiers.tsv
// as data in the jobs worker. A SET is one whole snapshot of the file plus the
// git blob sha of the committed file it was based on; the newest set wins.
//
// Writer: `bin/ci-test-tiers.sh put` on a box (source "seed" from the committed
// file, or "operator" from an edited copy). Reader: `bin/ci-test-tiers.sh
// fetch` in CI's plan jobs, which uses the set only while its base_blob is the
// checkout's file and `bin/test-tiers.sh check` accepts it (docs/ci-test-tiers.md).
//
// AUTH. Both routes sit in OPEN_ROUTES, so the main bearer check never runs for
// them: each handler checks its OWN bearer. GET accepts CI_DURATIONS_TOKEN (the
// one secret CI holds) or HARNESS_SECRET. PUT accepts HARNESS_SECRET ONLY: the
// tier set decides which suites a batch skips, so CI never gains a write path
// to it. A secret that is unset or empty matches nothing.
//
// IDEMPOTENT AGAINST THE NEWEST SET. digest is the sha256 of base_blob and the
// rows sorted by suite. A PUT whose digest equals the newest set's is a
// duplicate (nothing written). Any other PUT inserts a new set, even when an
// OLDER set has that digest, so re-applying an old set makes it the newest.
//
// The table ships in schema.sql, which bin/harness-sync.sh applies before
// `wrangler deploy`; both handlers are d1Guarded so an unapplied table answers
// 503 "ci_test_tier_sets schema not applied", never a bodiless 500.

import { json, d1Guarded } from "../lib/http.js";

const SUITE_RE = /^tests\/[A-Za-z0-9._/-]+\.sh$/;
const BLOB_RE = /^[0-9a-f]{40}$/;
const ACTOR_RE = /^[A-Za-z0-9._@-]{1,64}$/;
const TIERS = new Set(["batch", "nightly", "guard"]);
const RUNTIME_MAX = 86400;
const ROWS_MAX = 2000;

function bearer(req) {
  const m = /^Bearer\s+(\S+)$/i.exec(req.headers.get("authorization") || "");
  return m ? m[1] : null;
}
const matches = (token, secret) => token !== null && typeof secret === "string" && secret !== "" && token === secret;

const byCodeUnit = (a, b) => (a < b ? -1 : a > b ? 1 : 0);
const textOk = (s) => typeof s === "string" && s !== "" && !/[\t\r\n]/.test(s);

// Every row is checked before anything is written: one bad row refuses the
// whole body. The rules are bin/test-tiers.sh check's, minus "the suite file
// exists" (the worker has no tree; fetch runs check against the checkout).
// Returns { error } or the cleaned { baseBlob, source, actor, rows }.
function validate(body) {
  if (body === null || typeof body !== "object" || Array.isArray(body)) return { error: "body must be a JSON object" };
  const { base_blob: baseBlob, source, actor } = body;
  if (typeof baseBlob !== "string" || !BLOB_RE.test(baseBlob)) return { error: "base_blob must be a 40-hex git blob sha" };
  if (source !== "seed" && source !== "operator") return { error: "source must be seed or operator" };
  if (typeof actor !== "string" || !ACTOR_RE.test(actor)) return { error: "actor must be 1..64 of [A-Za-z0-9._@-]" };
  if (!Array.isArray(body.rows) || body.rows.length === 0) return { error: "rows must be a non-empty array" };
  if (body.rows.length > ROWS_MAX) return { error: `rows over ${ROWS_MAX}` };
  const seen = new Set();
  const rows = [];
  for (let i = 0; i < body.rows.length; i++) {
    const r = body.rows[i];
    if (r === null || typeof r !== "object" || Array.isArray(r)) return { error: `rows[${i}] must be an object` };
    const { suite, tier, runtime_s: runtime, paths, reason } = r;
    if (typeof suite !== "string" || !SUITE_RE.test(suite) || suite.includes("..")) {
      return { error: `rows[${i}].suite must be a tests/<path>.sh suite path` };
    }
    if (!TIERS.has(tier)) return { error: `rows[${i}].tier must be batch, nightly or guard` };
    if (!Number.isInteger(runtime) || runtime < 0 || runtime > RUNTIME_MAX) {
      return { error: `rows[${i}].runtime_s must be a whole number in 0..${RUNTIME_MAX}` };
    }
    if (!textOk(paths)) return { error: `rows[${i}].paths must be a non-empty string with no tab or newline` };
    if (tier === "guard" && paths === "-") return { error: `rows[${i}].paths: a guard needs the paths it guards` };
    if (tier !== "guard" && paths !== "-") return { error: `rows[${i}].paths: paths are for guard rows only` };
    if (!textOk(reason)) return { error: `rows[${i}].reason must be a non-empty string with no tab or newline` };
    if (seen.has(suite)) return { error: `rows[${i}].suite ${suite} is a duplicate` };
    seen.add(suite);
    rows.push({ suite, tier, runtime_s: runtime, paths, reason });
  }
  rows.sort((a, b) => byCodeUnit(a.suite, b.suite));
  return { baseBlob, source, actor, rows };
}

// sha256 hex of `base_blob<LF>` then one `suite<TAB>tier<TAB>runtime<TAB>paths<TAB>reason<LF>`
// line per row, rows sorted by suite.
async function digestOf(baseBlob, rows) {
  const text = `${baseBlob}\n${rows.map((r) => `${r.suite}\t${r.tier}\t${r.runtime_s}\t${r.paths}\t${r.reason}\n`).join("")}`;
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

const NEWEST = "SELECT id, base_blob, digest, rows_json, source, actor, created_at FROM ci_test_tier_sets ORDER BY id DESC LIMIT 1";

export const routes = [
  [
    "GET", "/api/ci/test-tiers",
    async ({ req, env }) => {
      const tok = bearer(req);
      if (!matches(tok, env.CI_DURATIONS_TOKEN) && !matches(tok, env.HARNESS_SECRET)) return json(401, { error: "unauthorized" });
      return d1Guarded("ci_test_tier_sets", async () => {
        const s = await env.DB.prepare(NEWEST).first();
        if (!s) return json(200, { set: null });
        const { rows_json: rowsJson, ...rest } = s;
        return json(200, { set: { ...rest, id: Number(s.id), rows: JSON.parse(rowsJson) } });
      });
    },
  ],
  [
    "PUT", "/api/ci/test-tiers",
    async ({ req, env, t }) => {
      if (!matches(bearer(req), env.HARNESS_SECRET)) return json(401, { error: "unauthorized" });
      // Open routes get no parsed body: read it here, and refuse a bad one.
      let body;
      try {
        body = await req.json();
      } catch {
        return json(400, { error: "body is not JSON" });
      }
      const v = validate(body);
      if (v.error) return json(400, { error: v.error });
      const digest = await digestOf(v.baseBlob, v.rows);
      const db = env.DB;
      return d1Guarded("ci_test_tier_sets", async () => {
        const newest = await db.prepare(NEWEST).first();
        if (newest && newest.digest === digest) return json(200, { id: Number(newest.id), duplicate: true });
        const id = await db.prepare(
          "INSERT INTO ci_test_tier_sets (base_blob, digest, rows_json, row_count, source, actor, created_at)"
          + " VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7) RETURNING id",
        ).bind(v.baseBlob, digest, JSON.stringify(v.rows), v.rows.length, v.source, v.actor, t).first("id");
        return json(201, { id: Number(id) });
      });
    },
  ],
];
