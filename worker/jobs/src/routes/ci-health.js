// ci-health routes — BH-2633 (BH-2517.2): the newest CI minutes and runner-pool
// snapshot per repo, one row per (repo, metric).
//
// Writers: bin/ci-minutes-watch.sh (metric "minutes", one PUT per repo each
// tick) and bin/testhost-tick.sh cmd_ci_runners (metric "runners"), both through
// ci_health_put in bin/lib/jobs/cost.sh. Both pushes are best-effort: the lanes'
// own state files and pages come first.
//
// The table ships in schema.sql (BH-2631), which bin/harness-sync.sh applies
// before `wrangler deploy`; both handlers are d1Guarded so an unapplied table
// answers 503 "ci_health schema not applied", never a bodiless 500.

import { json, d1Guarded } from "../lib/http.js";
import { str } from "../lib/core.js";

const METRICS = ["minutes", "runners"];
const PAYLOAD_MAX_BYTES = 8192;
const LIST_CAP = 500;

function rowOut(r) {
  const out = { repo: r.repo, metric: r.metric, payload: null, box: r.box, as_of: r.as_of };
  // A stored value that does not parse is flagged, never dropped: only this
  // route's PUT writes the table, so it should not happen, and hiding the row
  // would make a repo look like it never reported.
  try { out.payload = JSON.parse(r.payload); } catch { out.payload_error = "unparseable"; }
  return out;
}

export const routes = [
  [
    "PUT", "/api/ci-health",
    async ({ env, t, body }) => {
      const repo = str(body.repo, 256);
      if (!repo) return json(400, { error: "repo required" });
      const metric = body.metric;
      if (!METRICS.includes(metric)) return json(400, { error: `metric must be one of: ${METRICS.join(", ")}` });
      const payload = body.payload;
      if (payload === null || typeof payload !== "object" || Array.isArray(payload)) {
        return json(400, { error: "payload must be a JSON object" });
      }
      const s = JSON.stringify(payload);
      if (new TextEncoder().encode(s).length > PAYLOAD_MAX_BYTES) {
        return json(400, { error: `payload over ${PAYLOAD_MAX_BYTES} bytes serialised` });
      }
      const box = str(body.box, 128);
      return d1Guarded("ci_health", async () => {
        await env.DB.prepare(
          "INSERT INTO ci_health (repo, metric, payload, box, as_of) VALUES (?1, ?2, ?3, ?4, ?5) " +
          "ON CONFLICT(repo, metric) DO UPDATE SET payload=?3, box=?4, as_of=?5"
        ).bind(repo, metric, s, box, t).run();
        return json(200, { ok: true, row: { repo, metric, payload, box, as_of: t } });
      });
    },
  ],

  [
    "GET", "/api/ci-health",
    async ({ env, url, t }) => {
      const repo = str(url.searchParams.get("repo"), 256);
      return d1Guarded("ci_health", async () => {
        // One past the cap, so `truncated` says the list really was cut.
        const res = repo
          ? await env.DB.prepare(
            "SELECT repo, metric, payload, box, as_of FROM ci_health WHERE repo=?1 ORDER BY metric LIMIT ?2"
          ).bind(repo, LIST_CAP + 1).all()
          : await env.DB.prepare(
            "SELECT repo, metric, payload, box, as_of FROM ci_health ORDER BY repo, metric LIMIT ?1"
          ).bind(LIST_CAP + 1).all();
        const rows = res.results || [];
        return json(200, { rows: rows.slice(0, LIST_CAP).map(rowOut), as_of: t, truncated: rows.length > LIST_CAP });
      });
    },
  ],
];
