// cost-caps routes — BH-2563 (BH-2511.0) fixed the shapes; BH-2564 (BH-2511 W2)
// fills them in. The three routes behind the Costs page's caps editor:
//   PUT  /api/cost-caps              {key, value, reason, actor}  one cap, audited
//   GET  /api/cost-cap-changes[?key][&limit]                      the audit trail
//   POST /api/cost-caps/seed         {rows:[{key, value}]}        the conf files, as seed rows
//
// A cap is a `settings` row (conf.cost-caps.* / conf.lane-caps.*). These routes
// are a second path to the same datum as PUT /api/settings, so they share its
// d1Guarded wrapper and its reserved seed actor (D15).

import { d1Guarded, json } from "../lib/http.js";
import {
  PRUNE_SEED_SQL, REGISTRY_SEED_ACTOR, SEED_REGISTRY_SQL, SETTING_KEY_RE, ensureTable,
} from "../lib/core.js";
import { CAP_KEY_PREFIX_RE, capChangeStmt, capFleetKey, validateCapValue } from "../lib/cost-caps.js";
import { CONFIG_KINDS, configChangeStmts } from "../lib/config-changes.js";
import { invalidateSettings } from "../lib/settings-cache.js";

const MAX_CHANGES = 500;
const MAX_SEED_ROWS = 200;

// The settings.js upsert, verbatim, so both PUTs write the row the same way.
const UPSERT_SQL =
  `INSERT INTO settings (key, value, note, actor, updated_at)
   VALUES (?1,?2,?3,?4,?5)
   ON CONFLICT(key) DO UPDATE SET value=?2, note=COALESCE(?3, note),
     actor=?4, updated_at=?5`;

export const routes = [
  // Every refusal answers before anything is read or written. A value equal to
  // the stored one is `unchanged: true` with no write and no audit row, so the
  // trail only ever holds real changes. A change is the upsert and its two
  // audit rows (cost_cap_changes, and a `cost_cap` config_changes row since
  // BH-2992.2) in ONE batch.
  [
    "PUT", "/api/cost-caps",
    async ({ env, t, body }) => {
      return d1Guarded("settings", async () => {
      const key = String(body.key ?? "").trim();
      const cap = capFleetKey(key);
      if (!cap) return json(400, { error: "key must be a fleet cost-caps/lane-caps key" });
      if (typeof body.value !== "string") return json(400, { error: "value must be a string" });
      const value = body.value.trim();
      const bad = validateCapValue(cap, value);
      if (bad) return json(400, { error: bad });
      const reason = typeof body.reason === "string" ? body.reason.trim().slice(0, 512) : "";
      if (!reason) return json(400, { error: "reason required" });
      const actor = body.actor ? String(body.actor).slice(0, 128) : "api";
      if (actor === REGISTRY_SEED_ACTOR) {
        return json(400, { error: `actor '${REGISTRY_SEED_ACTOR}' is reserved for the seed` });
      }
      await ensureTable(env, "cost_cap_changes");
      await ensureTable(env, "config_changes");
      const was = await env.DB.prepare("SELECT * FROM settings WHERE key=?1").bind(key).first();
      if (was && String(was.value) === value) return json(200, { setting: was, unchanged: true });
      await env.DB.batch([
        env.DB.prepare(UPSERT_SQL).bind(key, value, reason, actor, t),
        capChangeStmt(env, key, was ? String(was.value) : null, value, actor, reason, t),
        ...configChangeStmts(env, CONFIG_KINDS.COST_CAP, key, was ? { value: String(was.value) } : null,
          { value }, ["value"], actor, reason, t),
      ]);
      invalidateSettings(env);   // BH-5781
      const row = await env.DB.prepare("SELECT * FROM settings WHERE key=?1").bind(key).first();
      return json(200, { setting: row, unchanged: false });
      });
    },
  ],

  // Newest first; `truncated` says when the limit bit. Box-suffixed cap keys
  // are a valid filter, because the generic PUT audits them too.
  [
    "GET", "/api/cost-cap-changes",
    async ({ env, url, t }) => {
      return d1Guarded("cost_cap_changes", async () => {
      await ensureTable(env, "cost_cap_changes");
      const key = url.searchParams.get("key");
      if (key !== null && !(SETTING_KEY_RE.test(key) && CAP_KEY_PREFIX_RE.test(key))) {
        return json(400, { error: "key must be a conf.cost-caps.* or conf.lane-caps.* key" });
      }
      const limit = Math.min(Math.max(Number(url.searchParams.get("limit")) || 100, 1), MAX_CHANGES);
      const rows = await env.DB.prepare(
        "SELECT * FROM cost_cap_changes WHERE (?2 IS NULL OR key=?2) ORDER BY id DESC LIMIT ?1"
      ).bind(limit + 1, key).all();
      const list = rows.results || [];
      return json(200, { changes: list.slice(0, limit), truncated: list.length > limit, as_of: t });
      });
    },
  ],

  // The conf files as rows under REGISTRY_SEED_ACTOR, which a box's settings
  // cache keeps in its `seeded` map. Since BH-4155 bin/lib/cost-budget.sh and
  // bin/lib/lane-caps.sh read those rows above the catalog file and below an
  // operator row. The whole request is
  // validated first, then the upserts and the prunes go in ONE batch. The
  // guards are in the SQL: an operator's row is never moved or deleted. A seed
  // is not an operator decision, so it writes no audit row.
  [
    "POST", "/api/cost-caps/seed",
    async ({ env, t, body }) => {
      return d1Guarded("settings", async () => {
      const raw = body.rows;
      if (!Array.isArray(raw) || raw.length === 0 || raw.length > MAX_SEED_ROWS) {
        return json(400, { error: `rows must be a non-empty array of at most ${MAX_SEED_ROWS} {key, value}` });
      }
      const rows = [];
      const seen = new Set();
      for (let i = 0; i < raw.length; i++) {
        const r = raw[i];
        if (!r || typeof r.key !== "string" || typeof r.value !== "string") {
          return json(400, { error: `rows[${i}] must be {key, value} strings` });
        }
        const key = r.key.trim();
        const value = r.value.trim();
        const cap = capFleetKey(key);
        if (!cap) return json(400, { error: `rows[${i}]: key must be a fleet cost-caps/lane-caps key` });
        const bad = validateCapValue(cap, value);
        if (bad) return json(400, { error: `rows[${i}] ${key}: ${bad}` });
        if (seen.has(key)) return json(400, { error: `rows[${i}]: duplicate key ${key}` });
        seen.add(key);
        rows.push({ key, value });
      }
      const owned = await env.DB.prepare(
        "SELECT key FROM settings WHERE actor=?1 AND (key LIKE 'conf.cost-caps.%' OR key LIKE 'conf.lane-caps.%')"
      ).bind(REGISTRY_SEED_ACTOR).all();
      const orphans = (owned.results || []).map((r) => r.key)
        .filter((k) => CAP_KEY_PREFIX_RE.test(k) && !seen.has(k));
      const res = await env.DB.batch([
        ...rows.map((r) => env.DB.prepare(SEED_REGISTRY_SQL).bind(r.key, r.value, null, REGISTRY_SEED_ACTOR, t)),
        ...orphans.map((k) => env.DB.prepare(PRUNE_SEED_SQL).bind(k, REGISTRY_SEED_ACTOR)),
      ]);
      invalidateSettings(env);   // BH-5781
      const changedKeys = rows.filter((_, j) => Number(res?.[j]?.meta?.changes || 0) > 0).map((r) => r.key);
      return json(200, { rows: rows.length, changed: changedKeys.length, changed_keys: changedKeys,
        pruned: orphans.length, pruned_keys: orphans, actor: REGISTRY_SEED_ACTOR, as_of: t });
      });
    },
  ],
];
