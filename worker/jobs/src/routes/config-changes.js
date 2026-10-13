// GET /api/config-changes[?kind=][&name=][&limit=] — BH-2375 (BH-2330.0).
// The read over config_changes, the one audit store every console control
// writes to (src/lib/config-changes.js). Read-only: each write and its audit
// row stay on the route that owns the datum. A bad kind or name is a 400,
// never an unfiltered read.

import { d1Guarded, json } from "../lib/http.js";
import { ensureTable } from "../lib/core.js";
import { listConfigChanges } from "../lib/config-changes.js";

export const routes = [
  [
    "GET", "/api/config-changes",
    async ({ env, url, t }) => {
      return d1Guarded("config_changes", async () => {
        await ensureTable(env, "config_changes");
        const q = url.searchParams;
        const out = await listConfigChanges(env, { kind: q.get("kind"), name: q.get("name"), limit: q.get("limit") }, t);
        return json(out.error ? 400 : 200, out);
      });
    },
  ],
];
