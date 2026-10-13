// account-leases routes — per-account capacity, enforced inside one statement.
//
// Moved out of the one flat `if (path === … && req.method === …)` chain in
// src/index.js by BH-1195. Every handler body below is the chain's body
// VERBATIM — same SQL, same validation, same status codes, same response keys —
// so this file changed where the code lives and nothing about what it answers.
// src/index.js holds the ordered table that decides which of these runs.
// The two BH-2516 token-health entries at the end postdate that move.

import { json } from "../lib/http.js";
import {
  strictInt, str, ensureTable, laneName, isoPlusSeconds, leaseWon,
  ACCOUNT_LEASE_CAP, ACCOUNT_LEASE_CAP_MAX, ACCOUNT_LEASE_UNCAPPED,
  ACCOUNT_LEASE_CLAIM_SQL, accountLeaseTtl, accountLeaseLive,
} from "../lib/core.js";

// The code fallback for the settings row lib.token-health.token_health_warn_h
// (seeded 24 in schema.sql), used when the row is missing or unusable.
const TOKEN_HEALTH_WARN_H_KEY = "lib.token-health.token_health_warn_h";
const TOKEN_HEALTH_WARN_H_DEFAULT = 24;
const TOKEN_HEALTH_LEASES_CAP = 200;
const TOKEN_HEALTH_TOKENS_CAP = 500;

// One statement, so two boxes reporting the same credential never race a
// read-modify-write. Binds: ?1 kind ?2 subject ?3 box ?4 expires_at
// ?5 last_ok_at ?6 now ?7 last_ok ?8 fail_count ?9 last_error. An ok resets the
// failure count and takes the given expires_at (null included); a fail counts
// up and keeps the previous expires_at unless it brings a new one.
const TOKEN_HEALTH_UPSERT_SQL = `INSERT INTO token_health
  (kind,subject,box,expires_at,last_ok_at,last_attempt_at,last_ok,fail_count,last_error,updated_at)
  VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?6)
  ON CONFLICT(kind,subject) DO UPDATE SET
    box=excluded.box, last_attempt_at=excluded.last_attempt_at, updated_at=excluded.updated_at,
    last_ok=excluded.last_ok,
    fail_count = CASE WHEN excluded.last_ok=1 THEN 0 ELSE token_health.fail_count+1 END,
    last_ok_at = CASE WHEN excluded.last_ok=1 THEN excluded.last_ok_at ELSE token_health.last_ok_at END,
    expires_at = CASE WHEN excluded.last_ok=1 THEN excluded.expires_at
                      ELSE COALESCE(excluded.expires_at, token_health.expires_at) END,
    last_error = CASE WHEN excluded.last_ok=1 THEN token_health.last_error ELSE excluded.last_error END`;

export const routes = [
  // ── SHARED FACTS: ACCOUNT LEASES (BH-1043) ─────────────────────────────
  // The cap on a claude account is a FLEET fact. It used to be a per-box
  // directory listing, so two boxes each counted 0 of 4 used and each filled
  // the account to 4. Claim is the compare-and-swap above; the routes here
  // are three lines of validation around it.
  [
    "POST", "/api/account-leases/claim",
    async ({ env, t, body }) => {
      const account = laneName(body.account);
      const machine = laneName(body.machine_id);
      if (!account || !machine) {
        return json(400, { error: "account and machine_id are required and must match [A-Za-z0-9._-]{1,64}" });
      }
      const capRaw = strictInt(body.cap);
      const cap = capRaw === null ? ACCOUNT_LEASE_CAP : Math.min(Math.max(capRaw, 0), ACCOUNT_LEASE_CAP_MAX);
      const exp = isoPlusSeconds(t, accountLeaseTtl(body.ttl_s));
      await ensureTable(env, "account_leases");
      // Expired rows are swept before the count, so a machine that vanished
      // without a release frees its account on the first claim after the TTL
      // rather than waiting for a sweep nobody wrote.
      await env.DB.prepare("DELETE FROM account_leases WHERE expires_at <= ?1").bind(t).run();
      const won = await env.DB.prepare(ACCOUNT_LEASE_CLAIM_SQL).bind(
        account, machine, str(body.box, 64), str(body.project, 128), str(body.ticket_key, 64),
        exp, t, cap === 0 ? ACCOUNT_LEASE_UNCAPPED : cap
      ).run();
      const live = await accountLeaseLive(env, account, t);
      if (leaseWon(won)) {
        return json(200, { claimed: true, account, machine_id: machine, live, cap, expires_at: exp, as_of: t });
      }
      // 409 is "the account is full", never "the worker is unwell": the client
      // maps it to the next candidate and maps everything else to "take this
      // one", and collapsing the two would put the whole pool back on one token.
      return json(409, { claimed: false, reason: "cap", account, machine_id: machine, live, cap, as_of: t });
    },
  ],

  [
    "POST", "/api/account-leases/release",
    async ({ env, t, body }) => {
      const machine = laneName(body.machine_id);
      if (!machine) return json(400, { error: "machine_id is required and must match [A-Za-z0-9._-]{1,64}" });
      const account = laneName(body.account);
      await ensureTable(env, "account_leases");
      const r = account
        ? await env.DB.prepare("DELETE FROM account_leases WHERE account=?1 AND machine_id=?2").bind(account, machine).run()
        : await env.DB.prepare("DELETE FROM account_leases WHERE machine_id=?1").bind(machine).run();
      return json(200, { released: Number((r && r.meta && r.meta.changes) || 0), machine_id: machine, as_of: t });
    },
  ],

  // With `account`, the live rows for one account; without it, the whole
  // fleet's counts in one call — the shape a picker that ranks every account
  // needs so a pick is one request and not one per candidate.
  [
    "GET", "/api/account-leases",
    async ({ env, url, t }) => {
      await ensureTable(env, "account_leases");
      const account = laneName(url.searchParams.get("account"));
      if (account) {
        const rows = await env.DB.prepare(
          "SELECT * FROM account_leases WHERE account=?1 AND expires_at>?2 ORDER BY machine_id ASC LIMIT 200"
        ).bind(account, t).all();
        const list = rows.results || [];
        return json(200, { account, live: list.length, rows: list, as_of: t });
      }
      const rows = await env.DB.prepare(
        "SELECT account, COUNT(*) AS n FROM account_leases WHERE expires_at>?1 GROUP BY account ORDER BY account ASC"
      ).bind(t).all();
      const counts = {};
      let live = 0;
      for (const r of rows.results || []) { counts[r.account] = Number(r.n); live += Number(r.n); }
      return json(200, { counts, live, as_of: t });
    },
  ],

  // ── TOKEN HEALTH (BH-2516.0 contract BH-2644, routes BH-2645) ──────────
  /**
   * The producer write. Body:
   *   {kind: 'oauth'|'gh_app', subject: string, box: string, ok: boolean,
   *    expires_at?: ISO string, error?: string}
   * Anything outside that shape is a 400 and writes nothing: kind is matched
   * exactly, ok must be a JSON boolean, expires_at must parse as a date. Every
   * timestamp the row carries besides expires_at is the server clock.
   * Answers {ok: true, row} with the row as stored.
   */
  [
    "POST", "/api/account-leases/token-health",
    async ({ env, t, body }) => {
      if (body.kind !== "oauth" && body.kind !== "gh_app") {
        return json(400, { error: "kind must be 'oauth' or 'gh_app'" });
      }
      const subject = laneName(body.subject);
      if (!subject) return json(400, { error: "subject is required and must match [A-Za-z0-9._-]{1,64}" });
      if (typeof body.ok !== "boolean") return json(400, { error: "ok must be true or false" });
      let expires = null;
      if (body.expires_at !== undefined && body.expires_at !== null) {
        const ms = typeof body.expires_at === "string" ? Date.parse(body.expires_at) : NaN;
        if (!Number.isFinite(ms)) return json(400, { error: "expires_at must be absent or an ISO date string" });
        // The clock's own shape, so the read's comparisons see one format.
        expires = new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");
      }
      await ensureTable(env, "token_health");
      await env.DB.prepare(TOKEN_HEALTH_UPSERT_SQL).bind(
        body.kind, subject, str(body.box, 64), expires,
        body.ok ? t : null, t, body.ok ? 1 : 0, body.ok ? 0 : 1,
        body.ok ? null : str(body.error, 200)
      ).run();
      const row = await env.DB.prepare("SELECT * FROM token_health WHERE kind=?1 AND subject=?2")
        .bind(body.kind, subject).first();
      return json(200, { ok: true, row });
    },
  ],

  /**
   * The panel read. `accounts` is one row per credential: every token_health
   * row, plus every account with a live lease and no oauth row of its own:
   *   {kind, subject, box, live_leases,
   *    leases: [{machine_id, box, project, ticket_key, expires_at}],
   *    expires_at,
   *    expires_in_s  (null when unknown),
   *    expiring      (true when expires_in_s < warn_h*3600, expired included;
   *                   false when unknown),
   *    last_ok_at, last_attempt_at, last_ok, fail_count, last_error,
   *    reported      (false for a lease-only account)}
   * warn_h is the settings row lib.token-health.token_health_warn_h, or 24 with
   * warn_h_source 'default' when the row is missing, non-numeric or <= 0.
   * `leases` is capped at 200 in total and token rows at 500, each with its own
   * `truncated` flag; live_leases is the uncapped count.
   */
  [
    "GET", "/api/account-leases/health",
    async ({ env, t }) => {
      await ensureTable(env, "account_leases");
      await ensureTable(env, "token_health");
      const warnRow = await env.DB.prepare("SELECT value FROM settings WHERE key=?1")
        .bind(TOKEN_HEALTH_WARN_H_KEY).first();
      // Number("") is 0, which the <= 0 test sends to the default with the rest.
      const n = warnRow ? Number(String(warnRow.value).trim()) : NaN;
      const fromSettings = Number.isFinite(n) && n > 0;
      const warnH = fromSettings ? n : TOKEN_HEALTH_WARN_H_DEFAULT;

      const counts = await env.DB.prepare(
        "SELECT account, COUNT(*) AS n FROM account_leases WHERE expires_at>?1 GROUP BY account"
      ).bind(t).all();
      const leaseRows = (await env.DB.prepare(
        "SELECT account,machine_id,box,project,ticket_key,expires_at FROM account_leases WHERE expires_at>?1 ORDER BY account,machine_id LIMIT ?2"
      ).bind(t, TOKEN_HEALTH_LEASES_CAP + 1).all()).results || [];
      const tokenRows = (await env.DB.prepare(
        "SELECT * FROM token_health ORDER BY kind,subject LIMIT ?1"
      ).bind(TOKEN_HEALTH_TOKENS_CAP + 1).all()).results || [];
      const truncated = {
        leases: leaseRows.length > TOKEN_HEALTH_LEASES_CAP,
        tokens: tokenRows.length > TOKEN_HEALTH_TOKENS_CAP,
      };

      const byAccount = new Map();
      for (const r of (counts.results || [])) byAccount.set(r.account, { n: Number(r.n), leases: [] });
      for (const l of leaseRows.slice(0, TOKEN_HEALTH_LEASES_CAP)) {
        const a = byAccount.get(l.account);
        if (a) a.leases.push({ machine_id: l.machine_id, box: l.box, project: l.project, ticket_key: l.ticket_key, expires_at: l.expires_at });
      }

      const now = Date.parse(t);
      const accounts = [];
      const seen = new Set();
      for (const r of tokenRows.slice(0, TOKEN_HEALTH_TOKENS_CAP)) {
        // oauth subject = the account in account_leases (schema.sql).
        const lease = r.kind === "oauth" ? byAccount.get(r.subject) : undefined;
        if (lease) seen.add(r.subject);
        const inS = r.expires_at ? Math.floor((Date.parse(r.expires_at) - now) / 1000) : null;
        accounts.push({
          kind: r.kind, subject: r.subject, box: r.box,
          live_leases: lease ? lease.n : 0, leases: lease ? lease.leases : [],
          expires_at: r.expires_at, expires_in_s: inS,
          expiring: inS !== null && inS < warnH * 3600,
          last_ok_at: r.last_ok_at, last_attempt_at: r.last_attempt_at, last_ok: r.last_ok,
          fail_count: r.fail_count, last_error: r.last_error, reported: true,
        });
      }
      for (const [account, lease] of byAccount) {
        if (seen.has(account)) continue;
        accounts.push({
          kind: "oauth", subject: account, box: null, live_leases: lease.n, leases: lease.leases,
          expires_at: null, expires_in_s: null, expiring: false,
          last_ok_at: null, last_attempt_at: null, last_ok: null,
          fail_count: 0, last_error: null, reported: false,
        });
      }
      accounts.sort((a, b) => (a.kind < b.kind ? -1 : a.kind > b.kind ? 1 : a.subject < b.subject ? -1 : a.subject > b.subject ? 1 : 0));
      return json(200, {
        accounts, warn_h: warnH, warn_h_source: fromSettings ? "settings" : "default", as_of: t, truncated,
      });
    },
  ],
];
