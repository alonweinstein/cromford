# Mission Control: stale ticket/PR pages — diagnosis + handoff (2026-08-24)

## What the data actually says
Verified against the live console D1 tonight:
- Zero build rows sit in a non-terminal stage older than 1h (probed via a
  temporary /api/builds/stale endpoint, since rolled back).
- /api/builds/unmerged returns exactly 2 rows, both genuinely unmerged on
  GitHub (project-3 #229 rework-in-progress; one external project-10 PR).
- The 10-min bin/reconcile-prs.sh cron keeps the merged flag accurate for
  every row that has a pr_url.

So the builds LEDGER is correct. The wrong "reviewing / building / merged: no"
on Mission Control's ticket and PR pages is introduced in the dash/snapshot
layer (local harness-console source, DASH_API.md contract — not deployed-worker
code the hub can see).

## The reproducer
project-2 TK-166: MC renders build #2426 (stage reviewing, lane building,
merged no, age 2d). That row is a SUPERSEDED attempt — the fly builder killed
at 23:52Z Aug 21 (false-liveness incident, alert-triage 2026-08-22 00:18Z).
The successor build opened PR #364, which merged Aug 22 and is terminal in D1.
MC is selecting the dead sibling, not the latest row for the ticket.

## Suggested fix in the dash layer
Wherever the snapshot/dash query picks builds per ticket (or per PR), key by
latest activity, not first match:
  SELECT * FROM builds WHERE ticket_key = ?
  ORDER BY (pr_url != '') DESC, updated_at DESC LIMIT 1
i.e. prefer the row that actually carries the PR, newest first. Same for
PR-keyed pages: join on pr_url, and treat rows with empty pr_url as
superseded attempts, never the headline.

## Optional server-side sweep (fold into local source if wanted)
Two endpoints, ~25 lines, matching existing style (vmAuthed, now()):

    app.get("/api/builds/stale", async (c) => {
      if (!vmAuthed(c)) return c.text("unauthorized", 401);
      const cutoff = now() - (Number(c.req.query("hours")) || 24) * 3600;
      const { results } = await c.env.DB.prepare(
        `SELECT bkey, project, ticket_key, stage, pr_url, updated_at FROM builds
         WHERE merged = 0 AND updated_at < ?
           AND stage NOT IN ('pr_merged','done','plan_blocked','superseded','stale','failed')`
      ).bind(cutoff).all();
      return c.json({ builds: results });
    });
    app.post("/api/builds/close", async (c) => {
      if (!vmAuthed(c)) return c.text("unauthorized", 401);
      const { closed } = await c.req.json().catch(() => ({ closed: [] }));
      let n = 0;
      for (const it of (closed || []).slice(0, 100)) {
        const stage = ["superseded","stale","pr_merged"].includes(it.stage) ? it.stage : "stale";
        await c.env.DB.prepare(`UPDATE builds SET stage=?, merged=?, updated_at=? WHERE bkey=?`)
          .bind(stage, stage === "pr_merged" ? 1 : 0, now(), it.bkey).run();
        n++;
      }
      return c.json({ ok: true, updated: n });
    });

## Deploy-collision guard (learned the hard way tonight)
The hub deployed a patched worker from its Aug-17 mirror at 02:50Z while local
wrangler deploys were landing (00:59-02:34Z) — clobbered for ~10 min, rolled
back to version bea49865 via the CF versions API. Standing rule for the hub:
NEVER PUT worker content from the mirror without checking the versions list
first; the content/v2 endpoint returns the newest UPLOAD, not what is deployed.
