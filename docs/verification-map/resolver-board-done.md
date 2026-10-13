# Blocked-resolver board-done gate

**What it is:** Before either rebuild rung (`br_rebuild_fresh`, `br_rebuild_retry`) closes a PR or enqueues a fresh build, the blocked-resolver reads the ticket's live status on its product board. A status in the closed set (`done closed cancelled canceled archived rejected resolved completed wontfix`, the same set as `CLOSED_STATUSES` in `bin/triage-state.py`, matched exactly after trim and lowercase) drops the rebuild and writes one terminal record. An open status (or no status field) rebuilds as before. A board that cannot be read (no prod base, no internal token, no board id, a non-2xx, a body that is not a ticket list) holds the park: no rebuild, no PR close, no rung spent, re-read next tick. A board that answers without listing the ticket stays on the BH-1007 board-miss ladder. GitHub-issues projects (`board_prefix` `-`) make no board read.

**How a user reaches it:** Not a user-facing screen. The lane runs on the hub every ten minutes (`cron/hub.cron` blocked-resolver tick).

**Key routes/screens:**
- `bin/blocked-resolver.sh` — `br_board_status` (the board read) and `br_board_done_gate` (the decision), called right after `br_hold_gate` in both rebuild rungs.
- `logs/blocked-resolver.log` — `[resolver] <KEY> is <status> on the board — rebuild dropped, PR <url> left as it is` (once per ticket), `board state for <KEY> unreadable (<why>) — no rebuild, no rung spent, retried next tick` (once per tick), and `EVENT resolver_done_on_board`.
- `state/blocked-resolver/<project>/<cap-key>.json` — `outcome: RESOLVED_DONE`, `done_status`, and the `done-on-board` / `hold-board-unreadable` / `done-lifted` attempts.
- `state/blocked-resolver/<project>/<cap-key>.board-unreadable` — the one-attempt-per-episode marker, removed when the board answers.

**Selectors:** n/a (shell/JSON surfaces only).

**Preconditions / seed needs:** A product-board project with `board_prefix` and `prod` set in `fleet.conf` and a working internal API token, and a parked PR whose ladder reaches a rebuild rung.

**Verify it works:** `HARNESS_TEST_SANDBOX=1 bash tests/blocked-resolver-done-ticket.bh-4438-test.sh` exits 0 with no FAIL lines. On a live hub, a parked PR whose ticket reads `done` on the board gets no queue row and no supersede close; its state file reads `outcome: RESOLVED_DONE` with one `done-on-board` attempt, and the log has one `rebuild dropped` line however many ticks pass. A ticket reopened on the board clears the outcome on the next rebuild rung (one `done-lifted` attempt) and rebuilds.

**Manual-only / not automatable:** n/a — the suite drives the real script against stubbed board, GitHub and jobs clients.
