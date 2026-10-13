// telegram-topics routes — the relay's topic map.
//
// Moved out of the one flat `if (path === … && req.method === …)` chain in
// src/index.js by BH-1195. Every handler body below is the chain's body
// VERBATIM — same SQL, same validation, same status codes, same response keys —
// so this file changed where the code lives and nothing about what it answers.
// src/index.js holds the ordered table that decides which of these runs.
// Additions since: BH-2521 (BH-2678) added `rows` to the GET answer, and
// BH-2992.2 batches a `telegram_topic` config_changes row with the PUT's upsert
// when the thread_id changes (no reason required; a missing one is NULL).

import { json } from "../lib/http.js";
import {
  ensureTable, strictInt, str,
} from "../lib/core.js";
import { CONFIG_KINDS, configChangeStmts } from "../lib/config-changes.js";

export const routes = [
  [
    "PUT", "/api/telegram-topics",
    async ({ env, t, body }) => {
      const project = str(body.project, 128);
      const threadId = strictInt(body.thread_id);
      const actor = str(body.actor, 128) || null;
      // Lowercase only: project names are the keys of one map, and project-5
      // next to project-5 is two topics for one project.
      if (!project || !/^[a-z0-9_.-]{1,64}$/.test(project)) {
        return json(400, { error: "project must match /^[a-z0-9_.-]{1,64}$/" });
      }
      if (threadId === null || threadId <= 0) return json(400, { error: "thread_id must be a positive integer" });
      await ensureTable(env, "config_changes");
      const was = await env.DB.prepare("SELECT thread_id FROM telegram_topics WHERE project=?1").bind(project).first();
      await env.DB.batch([
        env.DB.prepare(
          `INSERT INTO telegram_topics (project, thread_id, actor, updated_at)
           VALUES (?1,?2,?3,?4)
           ON CONFLICT(project) DO UPDATE SET thread_id=?2, actor=?3, updated_at=?4`
        ).bind(project, threadId, actor, t),
        ...configChangeStmts(env, CONFIG_KINDS.TELEGRAM_TOPIC, project, was, { thread_id: threadId },
          ["thread_id"], actor, body.reason, t),
      ]);
      return json(200, { topic: { project, thread_id: threadId } });
    },
  ],

  [
    "GET", "/api/telegram-topics",
    async ({ env, t }) => {
      const rows = await env.DB.prepare(
        "SELECT project, thread_id, actor, updated_at FROM telegram_topics ORDER BY project"
      ).all();
      // project -> thread id, the shape state/telegram-topics.json already has
      // on disk: callers do .topics[project] and post to that thread.
      const topics = {};
      for (const r of (rows.results || [])) topics[r.project] = r.thread_id;
      // The rows themselves, for the /hub CHAT BINDINGS table. Additive: the
      // shell callers read .topics only.
      const list = (rows.results || []).map((r) => ({
        project: r.project, thread_id: r.thread_id, actor: r.actor ?? null, updated_at: r.updated_at,
      }));
      return json(200, { topics, rows: list, as_of: t });
    },
  ],
];
