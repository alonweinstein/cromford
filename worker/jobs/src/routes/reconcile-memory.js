// reconcile-prs memory routes (BH-1607 contract, BH-1610 bodies).
//
// Read and write the lane's per-kind watermarks (reconcile_memory, schema.sql),
// the D1 copy of state/reconcile-prs/{open,terminal,gone}. A new owner box
// hydrates its files from the GET; the owner flushes each tick's changes with
// one PUT (bin/lib/reconcile-read.sh, rcr_memory_hydrate / rcr_memory_flush).
//
// The caps are the wire contract, not operator knobs: a GET answers at most
// MAX_ROWS rows and says `truncated` when there were more (measured with one
// extra row, never guessed), and a PUT carries at most MAX_ENTRIES changes.

import { d1Guarded, json } from "../lib/http.js";

const KINDS = new Set(["terminal", "open", "gone"]);
const MAX_ROWS = 5000;
const MAX_ENTRIES = 500;
const MAX_VALUE = 4096;
const NOW = "strftime('%Y-%m-%dT%H:%M:%SZ','now')";

// A name becomes a file name on the box (state/reconcile-prs/<kind>/<name>),
// so it is the lane's own charset, at most 128 chars (owner_repo_num can pass
// laneName's 64), and never `.`/`..`.
function memName(v) {
  const s = typeof v === "string" ? v.trim() : "";
  return /^[A-Za-z0-9._-]{1,128}$/.test(s) && !/^\.+$/.test(s) ? s : "";
}

// Every entry is checked before any statement is built, so a 400 writes nothing.
function parse(body) {
  const b = body || {};
  for (const k of ["upserts", "deletes"]) {
    if (b[k] !== undefined && !Array.isArray(b[k])) return { error: `${k} must be an array` };
  }
  const upserts = b.upserts || [];
  const deletes = b.deletes || [];
  if (upserts.length + deletes.length > MAX_ENTRIES) return { error: `at most ${MAX_ENTRIES} entries per call` };
  const ups = []; const dels = [];
  for (const [i, e] of deletes.entries()) {
    const kind = e && e.kind; const name = memName(e && e.name);
    if (!KINDS.has(kind)) return { error: `deletes[${i}].kind must be terminal|open|gone` };
    if (!name) return { error: `deletes[${i}].name must be [A-Za-z0-9._-]{1,128}, not dots only` };
    dels.push({ kind, name });
  }
  for (const [i, e] of upserts.entries()) {
    const kind = e && e.kind; const name = memName(e && e.name); const value = e && e.value;
    if (!KINDS.has(kind)) return { error: `upserts[${i}].kind must be terminal|open|gone` };
    if (!name) return { error: `upserts[${i}].name must be [A-Za-z0-9._-]{1,128}, not dots only` };
    if (typeof value !== "string" || !value || value.length > MAX_VALUE) {
      return { error: `upserts[${i}].value must be a non-empty string of at most ${MAX_VALUE} chars` };
    }
    ups.push({ kind, name, value });
  }
  return { ups, dels };
}

export const routes = [
  [
    "GET", "/api/reconcile-prs/memory",
    async ({ env, t }) => d1Guarded("reconcile_memory", async () => {
      const r = await env.DB.prepare(
        "SELECT kind, name, value, updated_at FROM reconcile_memory ORDER BY kind, name LIMIT ?",
      ).bind(MAX_ROWS + 1).all();
      const rows = (r && r.results) || [];
      return json(200, { rows: rows.slice(0, MAX_ROWS), truncated: rows.length > MAX_ROWS, as_of: t });
    }),
  ],
  [
    "PUT", "/api/reconcile-prs/memory",
    async ({ env, body }) => d1Guarded("reconcile_memory", async () => {
      const p = parse(body);
      if (p.error) return json(400, { error: p.error });
      if (!p.ups.length && !p.dels.length) return json(200, { ok: true, upserts: 0, deletes: 0 });
      const del = "DELETE FROM reconcile_memory WHERE kind=? AND name=?";
      const up = `INSERT INTO reconcile_memory (kind, name, value, updated_at) VALUES (?, ?, ?, ${NOW}) ` +
        "ON CONFLICT(kind, name) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at";
      // An open watermark only ever moves forward (ISO-8601 Z stamps sort as strings).
      const upOpen = `${up} WHERE excluded.value > reconcile_memory.value`;
      // ONE batch: D1 runs it as a single transaction, so all of it lands or none does.
      await env.DB.batch([
        ...p.dels.map((d) => env.DB.prepare(del).bind(d.kind, d.name)),
        ...p.ups.map((u) => env.DB.prepare(u.kind === "open" ? upOpen : up).bind(u.kind, u.name, u.value)),
      ]);
      return json(200, { ok: true, upserts: p.ups.length, deletes: p.dels.length });
    }),
  ],
];
