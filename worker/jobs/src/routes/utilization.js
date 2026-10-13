// utilization routes — BH-4008 (BH-3988 tracer): one snapshot per (project,
// hour) of how much of its build capacity each project is using, and why.
//
// Writer: bin/utilization-push.sh (hub, hourly at :07) through utilization_put
// in bin/lib/jobs/utilization.sh. Each PUT also prunes that project's rows older
// than retention_days, so the table stays bounded without a sweep.
//
// GET with no params answers the newest row per project. The history form
// (BH-4012), `?project=<p>&since=<iso>`, answers that project's rows with
// hour >= since, ordered by hour ascending, capped at HISTORY_MAX with
// `truncated` saying whether rows past the cap exist. Either param alone, an
// empty project or an unparseable since is 400. Its reader is utilization_rows,
// called by the went-quiet lane bin/utilization-quiet.sh.
//
// The table ships in schema.sql, which bin/harness-sync.sh applies before
// `wrangler deploy`; both handlers are d1Guarded so an unapplied table answers
// 503 "utilization_snapshots schema not applied", never a bodiless 500.

import { json, d1Guarded } from "../lib/http.js";
import { str } from "../lib/core.js";

const VERDICTS = ["starved", "paused", "blocked", "saturated", "busy", "unknown"];
const HOUR_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:00:00Z$/;
const PAYLOAD_MAX_BYTES = 8192;
// The retention knob is UTIL_RETENTION_DAYS in catalog/lanes.d/utilization-push.json
// (7..90, default 35); these are its fallback and its bounds.
const RETENTION_DEFAULT_DAYS = 35;
const RETENTION_MIN_DAYS = 7;
const RETENTION_MAX_DAYS = 90;
const DAY_MS = 86400000;
const HISTORY_MAX = 500;

function rowOut(r) {
  const out = { project: r.project, hour: r.hour, verdict: r.verdict, payload: null, box: r.box, as_of: r.as_of };
  // A stored value that does not parse is flagged, never dropped: hiding the
  // row would make a project look like it never reported.
  try { out.payload = JSON.parse(r.payload); } catch { out.payload_error = "unparseable"; }
  return out;
}

// The hour pattern for the cutoff: rows whose hour sorts before it are pruned.
function cutoffHour(t, days) {
  return new Date(Date.parse(t) - days * DAY_MS).toISOString().replace(/:\d\d:\d\d\.\d{3}Z$/, ":00:00Z");
}

export const routes = [
  [
    "PUT", "/api/utilization",
    async ({ env, t, body }) => {
      const project = (str(body.project, 128) || "").trim();
      if (!project) return json(400, { error: "project required" });
      const hour = body.hour;
      if (typeof hour !== "string" || !HOUR_RE.test(hour)) {
        return json(400, { error: "hour must be YYYY-MM-DDTHH:00:00Z" });
      }
      const verdict = body.verdict;
      if (!VERDICTS.includes(verdict)) return json(400, { error: `verdict must be one of: ${VERDICTS.join(", ")}` });
      const payload = body.payload;
      if (payload === null || typeof payload !== "object" || Array.isArray(payload)) {
        return json(400, { error: "payload must be a JSON object" });
      }
      const s = JSON.stringify(payload);
      if (new TextEncoder().encode(s).length > PAYLOAD_MAX_BYTES) {
        return json(400, { error: `payload over ${PAYLOAD_MAX_BYTES} bytes serialised` });
      }
      let days = RETENTION_DEFAULT_DAYS;
      if (body.retention_days !== undefined) {
        const r = body.retention_days;
        if (typeof r !== "number" || !Number.isFinite(r)) return json(400, { error: "retention_days must be a number" });
        days = Math.min(RETENTION_MAX_DAYS, Math.max(RETENTION_MIN_DAYS, Math.floor(r)));
      }
      const box = str(body.box, 128);
      return d1Guarded("utilization_snapshots", async () => {
        const [, pruned] = await env.DB.batch([
          env.DB.prepare(
            "INSERT INTO utilization_snapshots (project, hour, verdict, payload, box, as_of) VALUES (?1, ?2, ?3, ?4, ?5, ?6) " +
            "ON CONFLICT(project, hour) DO UPDATE SET verdict=?3, payload=?4, box=?5, as_of=?6"
          ).bind(project, hour, verdict, s, box, t),
          env.DB.prepare("DELETE FROM utilization_snapshots WHERE project=?1 AND hour < ?2")
            .bind(project, cutoffHour(t, days)),
        ]);
        return json(200, {
          ok: true,
          row: { project, hour, verdict, payload, box, as_of: t },
          // null, never 0, if the driver did not report a count.
          pruned: pruned?.meta?.changes ?? null,
        });
      });
    },
  ],

  [
    "GET", "/api/utilization",
    async ({ env, url, t }) => {
      const qs = url.searchParams;
      if (qs.has("project") || qs.has("since")) {
        const project = (str(qs.get("project"), 128) || "").trim();
        const sinceRaw = qs.get("since") || "";
        if (!project || !sinceRaw) return json(400, { error: "project and since are both required for the history form" });
        const ms = Date.parse(sinceRaw);
        if (!Number.isFinite(ms)) return json(400, { error: "since must be an ISO timestamp" });
        // Stored hours are YYYY-MM-DDTHH:00:00Z, so a since in the same shape
        // (no ms) compares exactly as text.
        const since = new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");
        return d1Guarded("utilization_snapshots", async () => {
          const res = await env.DB.prepare(
            "SELECT project, hour, verdict, payload, box, as_of FROM utilization_snapshots " +
            "WHERE project=?1 AND hour >= ?2 ORDER BY hour ASC LIMIT ?3"
          ).bind(project, since, HISTORY_MAX + 1).all();
          const results = res.results || [];
          return json(200, {
            rows: results.slice(0, HISTORY_MAX).map(rowOut),
            truncated: results.length > HISTORY_MAX,
            as_of: t,
          });
        });
      }
      return d1Guarded("utilization_snapshots", async () => {
        const res = await env.DB.prepare(
          "SELECT u.project, u.hour, u.verdict, u.payload, u.box, u.as_of FROM utilization_snapshots u " +
          "JOIN (SELECT project, MAX(hour) AS h FROM utilization_snapshots GROUP BY project) m " +
          "ON m.project=u.project AND m.h=u.hour ORDER BY u.project"
        ).all();
        return json(200, { rows: (res.results || []).map(rowOut), as_of: t });
      });
    },
  ],
];
