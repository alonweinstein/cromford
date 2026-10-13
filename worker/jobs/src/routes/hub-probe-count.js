// hub-probe counter routes — BH-3448 (BH-3434.1). The shapes are the BH-3447
// contract, which the bin/lib/jobs/hub-probe.sh verbs already send and read:
//
//   GET /api/hub-probe/count-today?probe=      -> {count}
//       rows of that probe whose claimed_at is today (UTC). A deferred row has
//       its claimed_at cleared, so it does not count.
//   GET /api/hub-probe/count?table=&template=  -> {count}
//       the d1-count probe's one read. The SQL comes ONLY from D1_COUNT_SQL: a
//       table or template that is not an own key of the frozen map is a 400
//       before anything is prepared, so no request text ever reaches SQL. The
//       only bind is the last-24h cutoff, which the worker computes from its
//       own clock. The map's keys are pinned to HP_D1_TABLES / HP_D1_TEMPLATES
//       in bin/lib/hub-probes/common.sh by test/hub-probe-count.bh-3434.test.js.
//
// A missing table is a 503 through d1Guarded, never a count of 0.
import { d1Guarded, json } from "../lib/http.js";
import { PROBE_RE } from "./hub-probe.js";

// table -> the column last-24h is measured on.
const D1_COUNT_TS = [
  ["jobs", "created_at"],
  ["ledgers", "created_at"],
  ["split_watchdog_actions", "first_at"],
  ["hub_probe_requests", "requested_at"],
];

const frozenMap = (entries) => Object.freeze(Object.assign(Object.create(null), Object.fromEntries(entries)));

export const D1_COUNT_SQL = frozenMap(D1_COUNT_TS.map(([table, col]) => [table, frozenMap([
  ["all", `SELECT COUNT(*) AS n FROM ${table}`],
  ["last-24h", `SELECT COUNT(*) AS n FROM ${table} WHERE ${col} >= ?1`],
])]));

// nowIso's format (no millis), so the string comparison in SQL is ordered.
const isoNoMs = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");

export const routes = [
  [
    "GET", "/api/hub-probe/count-today",
    async ({ env, url, t }) => d1Guarded("hub_probe_requests", async () => {
      const probe = url.searchParams.get("probe");
      if (typeof probe !== "string" || !PROBE_RE.test(probe)) {
        return json(400, { error: "probe must match [a-z][a-z0-9-]{0,31}" });
      }
      const n = await env.DB.prepare(
        "SELECT COUNT(*) AS n FROM hub_probe_requests WHERE probe=?1 AND claimed_at >= ?2"
      ).bind(probe, `${t.slice(0, 10)}T00:00:00Z`).first("n");
      if (typeof n !== "number") return json(503, { error: "hub_probe_requests count not readable" });
      return json(200, { count: n });
    }),
  ],

  [
    "GET", "/api/hub-probe/count",
    async ({ env, url, t }) => {
      const q = url.searchParams;
      const table = q.get("table") ?? "";
      const template = q.get("template") ?? "";
      if (!Object.hasOwn(D1_COUNT_SQL, table)) return json(400, { error: "table is not in the d1-count allowlist" });
      const byTemplate = D1_COUNT_SQL[table];
      if (!Object.hasOwn(byTemplate, template)) return json(400, { error: "template is not in the d1-count allowlist" });
      const sql = byTemplate[template];
      return d1Guarded(table, async () => {
        const stmt = env.DB.prepare(sql);
        const bound = template === "last-24h" ? stmt.bind(isoNoMs(Date.parse(t) - 86400000)) : stmt;
        const n = await bound.first("n");
        if (typeof n !== "number") return json(503, { error: `${table} count not readable` });
        return json(200, { count: n });
      });
    },
  ],
];
