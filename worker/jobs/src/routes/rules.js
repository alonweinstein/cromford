// rules routes — concurrency rules, checked inside the claim.
//
// Moved out of the one flat `if (path === … && req.method === …)` chain in
// src/index.js by BH-1195. Every handler body below is the chain's body
// VERBATIM — same SQL, same validation, same status codes, same response keys —
// so this file changed where the code lives and nothing about what it answers.
// src/index.js holds the ordered table that decides which of these runs.
// Since BH-2618, PUT /api/rules also batches a config_changes audit row with
// its upsert (src/lib/config-changes.js), and since BH-2992.2 DELETE /api/rules
// batches a delete row with its DELETE when a rule was there to delete.

import { json } from "../lib/http.js";
import {
  RULE_SCOPES, ensureTable,
} from "../lib/core.js";
import { CONFIG_KINDS, configChangeStmts } from "../lib/config-changes.js";

export const routes = [
  // ── Concurrency rules (phase 6) ────────────────────────────────────────
  // Readable and editable, because a rule nobody can see is a rule nobody can
  // trust. GET lists; PUT upserts one row. There is deliberately no DELETE:
  // additive-only is the standing law here, and "unlimited" is expressible as
  // a very large max_concurrent without removing the row that documents why.
  [
    "GET", "/api/rules",
    async ({ env, t }) => {
      const rows = await env.DB.prepare(
        "SELECT * FROM concurrency_rules ORDER BY scope ASC, selector ASC, kind ASC"
      ).all();
      return json(200, { rules: rows.results || [], scopes: RULE_SCOPES, as_of: t });
    },
  ],

  [
    "PUT", "/api/rules",
    async ({ env, t, body }) => {
      const scope = String(body.scope || "").trim();
      if (!RULE_SCOPES.includes(scope)) return json(400, { error: `scope must be one of ${RULE_SCOPES.join(", ")}` });
      const selector = String(body.selector || "*").trim().slice(0, 256) || "*";
      const kind = String(body.kind || "*").trim().slice(0, 64) || "*";
      const max = Number(body.max_concurrent);
      // A negative or non-numeric cap would silently read as "block everything"
      // through the >= comparison. Refusing is the honest answer.
      if (!Number.isInteger(max) || max < 0) return json(400, { error: "max_concurrent must be an integer >= 0" });
      const note = body.note ? String(body.note).slice(0, 512) : null;
      // BH-2513: the audit row rides the same batch as the upsert. A selector
      // may hold "/", so the name is a label and after_json carries the key.
      await ensureTable(env, "config_changes");
      const was = await env.DB.prepare(
        "SELECT * FROM concurrency_rules WHERE scope=?1 AND selector=?2 AND kind=?3"
      ).bind(scope, selector, kind).first();
      const after = { scope, selector, kind, max_concurrent: max, note: note ?? was?.note ?? null };
      await env.DB.batch([
        env.DB.prepare(
          `INSERT INTO concurrency_rules (scope, selector, kind, max_concurrent, note, updated_at)
           VALUES (?1,?2,?3,?4,?5,?6)
           ON CONFLICT(scope, selector, kind) DO UPDATE SET max_concurrent=?4, note=COALESCE(?5, note), updated_at=?6`
        ).bind(scope, selector, kind, max, note, t),
        ...configChangeStmts(env, CONFIG_KINDS.RULE, `${scope}/${selector}/${kind}`, was, after,
          ["scope", "selector", "kind", "max_concurrent", "note"], body.actor, body.reason, t),
      ]);
      const row = await env.DB.prepare(
        "SELECT * FROM concurrency_rules WHERE scope=?1 AND selector=?2 AND kind=?3"
      ).bind(scope, selector, kind).first();
      return json(200, { rule: row });
    },
  ],

  // No row is the only spelling of "unlimited" (checkRules: no row for the
  // scope means the claim proceeds), and PUT cannot write "no row" — 0 is a
  // freeze, which is what a cap of zero honestly means. So unlimited needs
  // its own verb (the operator 2026-09-14: build, conductor, review, merge all
  // parallel, no caps). 200 either way: deleting a rule that is not there
  // leaves the fleet in exactly the state that was asked for.
  [
    "DELETE", "/api/rules",
    async ({ env, t, body }) => {
      const scope = String(body.scope || "").trim();
      if (!RULE_SCOPES.includes(scope)) return json(400, { error: `scope must be one of ${RULE_SCOPES.join(", ")}` });
      const selector = String(body.selector || "*").trim().slice(0, 256) || "*";
      const kind = String(body.kind || "*").trim().slice(0, 64) || "*";
      await ensureTable(env, "config_changes");
      const was = await env.DB.prepare(
        "SELECT * FROM concurrency_rules WHERE scope=?1 AND selector=?2 AND kind=?3"
      ).bind(scope, selector, kind).first();
      const res = await env.DB.batch([
        env.DB.prepare(
          "DELETE FROM concurrency_rules WHERE scope=?1 AND selector=?2 AND kind=?3"
        ).bind(scope, selector, kind),
        ...configChangeStmts(env, CONFIG_KINDS.RULE, `${scope}/${selector}/${kind}`, was, null,
          ["scope", "selector", "kind", "max_concurrent", "note"], body.actor, body.reason, t),
      ]);
      const r = res[0];
      const n = (r && r.meta && Number(r.meta.changes)) || 0;
      return json(200, { deleted: n, scope, selector, kind });
    },
  ],
];
