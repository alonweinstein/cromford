// decisions routes — the two append-only note ledgers: decisions and findings.
//
// Moved out of the one flat `if (path === … && req.method === …)` chain in
// src/index.js by BH-1195. Every handler body below is the chain's body
// VERBATIM — same SQL, same validation, same status codes, same response keys —
// so this file changed where the code lives and nothing about what it answers.
// src/index.js holds the ordered table that decides which of these runs.

import { json } from "../lib/http.js";
import {
  str, appendLines, listLines,
} from "../lib/core.js";

export const routes = [
  [
    "POST", "/api/decisions",
    async ({ env, t, body }) => {
      const res = await appendLines(env, "decisions", body, t,
        ["stamp", "project", "gate", "scope", "ticket", "line", "created_at"],
        (project, r, stamp, line, t) => [stamp, project, str(r.gate, 64), str(r.scope, 64), str(r.ticket, 128), line, t]);
      return json(res.status, res.body);
    },
  ],

  [
    "GET", "/api/decisions",
    async ({ env, url, t }) => {
      return listLines(env, "decisions", url, t);
    },
  ],

  [
    "POST", "/api/findings",
    async ({ env, t, body }) => {
      const res = await appendLines(env, "findings", body, t,
        ["stamp", "project", "ticket", "lens", "line", "created_at"],
        (project, r, stamp, line, t) => [stamp, project, str(r.ticket, 128), str(r.lens, 64), line, t]);
      return json(res.status, res.body);
    },
  ],

  [
    "GET", "/api/findings",
    async ({ env, url, t }) => {
      return listLines(env, "findings", url, t);
    },
  ],
];
