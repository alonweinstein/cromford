// projects routes — the project registry the console's Projects form edits
// (BH-4082, slice C0 of BH-3979.8).
//
// One row per project, the same columns as fleet.conf. PUT is the only writer
// and batches a config_changes row (kind 'project') with every change, the way
// routes/retry-policies.js does. There is no DELETE: retiring a project is the
// materializer slice's, together with fleet.conf's `# @retired` directive.
// Nothing in bin/ reads this table yet; fleet.conf is still what boxes read.
//
// Every value is validated here because a later slice writes these rows into
// fleet.conf, a positional file split on whitespace: a space, a newline or a
// stray character in any column but the note would corrupt every box's copy.

import { json } from "../lib/http.js";
import { ensureTable } from "../lib/core.js";
import { CONFIG_KINDS, configChangeStmts } from "../lib/config-changes.js";

const AUDITED = ["repo", "prod_url", "board_api_prefix", "cron_offset", "box", "tailnet_ip", "note"];
const SLUG_RE = /^[a-z0-9][a-z0-9-]{0,63}$/;
const REPO_RE = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;
const IPV4_RE = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/;
const NOTE_MAX = 512;

// A string or number as trimmed text; anything else (null, a boolean, an
// object) is undefined, which every field below reads as "not given".
function text(v) {
  if (typeof v === "string") return v.trim();
  if (typeof v === "number" && Number.isFinite(v)) return String(v);
  return undefined;
}

// The checked row, or {error}. `-` is fleet.conf's "none" and is stored NULL.
function projectRow(body) {
  const b = body && typeof body === "object" && !Array.isArray(body) ? body : {};
  // A newline or other control character anywhere is refused before any trim:
  // trimming it away would hide what the sender actually typed.
  for (const k of ["project", "repo", "prod_url", "board_api_prefix", "cron_offset", "box", "tailnet_ip"]) {
    if (typeof b[k] === "string" && /[\x00-\x1f\x7f]/.test(b[k])) return { error: `${k} must be one line` };
  }
  const project = (text(b.project) || "").toLowerCase();
  if (!SLUG_RE.test(project)) return { error: "project must be 1-64 lowercase letters, digits or dashes" };
  const repo = text(b.repo) || "";
  if (!REPO_RE.test(repo)) return { error: "repo must be an owner/name GitHub slug" };

  const none = (v) => v === undefined || v === "" || v === "-";
  const prodUrl = text(b.prod_url);
  if (!none(prodUrl) && !/^https:\/\/\S+$/.test(prodUrl)) return { error: "prod_url must start with https:// and contain no spaces" };
  const prefix = text(b.board_api_prefix);
  if (!none(prefix) && !/^\/\S*$/.test(prefix)) return { error: "board_api_prefix must start with / and contain no spaces" };

  // Refused, never clamped (D11): a blank is not 0 and 10 is not 9.
  const off = text(b.cron_offset);
  if (off === undefined || !/^\d+$/.test(off) || Number(off) > 9) return { error: "cron_offset must be a whole number from 0 to 9" };

  const box = text(b.box);
  if (box !== undefined && box !== "" && !SLUG_RE.test(box)) return { error: "box must be lowercase letters, digits or dashes" };
  const ip = text(b.tailnet_ip);
  if (ip !== undefined && ip !== "") {
    const m = IPV4_RE.exec(ip);
    if (!m || m.slice(1).some((o) => Number(o) > 255)) return { error: "tailnet_ip must be a dotted IPv4 address" };
  }
  const note = text(b.note);
  if (note !== undefined && note.length > NOTE_MAX) return { error: `note must be at most ${NOTE_MAX} characters` };

  return {
    row: {
      project, repo,
      prod_url: none(prodUrl) ? null : prodUrl,
      board_api_prefix: none(prefix) ? null : prefix,
      cron_offset: Number(off),
      box: box || null,
      tailnet_ip: ip || null,
      note: note || null,
    },
  };
}

export const routes = [
  [
    "GET", "/api/projects",
    async ({ env, t }) => {
      await ensureTable(env, "projects");
      const rows = await env.DB.prepare("SELECT * FROM projects ORDER BY project ASC").all();
      return json(200, { projects: rows.results || [], as_of: t });
    },
  ],

  [
    "PUT", "/api/projects",
    async ({ env, t, body }) => {
      const checked = projectRow(body);
      if (checked.error) return json(400, { error: checked.error });
      if (typeof body.reason !== "string" || !body.reason.trim()) return json(400, { error: "reason required" });
      const r = checked.row;
      await ensureTable(env, "projects");
      await ensureTable(env, "config_changes");
      const was = await env.DB.prepare("SELECT * FROM projects WHERE project=?1").bind(r.project).first();
      await env.DB.batch([
        env.DB.prepare(
          `INSERT INTO projects (project, repo, prod_url, board_api_prefix, cron_offset, box, tailnet_ip, note, created_at, updated_at)
           VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?9)
           ON CONFLICT(project) DO UPDATE SET repo=?2, prod_url=?3, board_api_prefix=?4, cron_offset=?5,
             box=?6, tailnet_ip=?7, note=?8, updated_at=?9`
        ).bind(r.project, r.repo, r.prod_url, r.board_api_prefix, r.cron_offset, r.box, r.tailnet_ip, r.note, t),
        ...configChangeStmts(env, CONFIG_KINDS.PROJECT, r.project, was, r, AUDITED, body.actor, body.reason, t),
      ]);
      const row = await env.DB.prepare("SELECT * FROM projects WHERE project=?1").bind(r.project).first();
      return json(200, { project: row });
    },
  ],
];
