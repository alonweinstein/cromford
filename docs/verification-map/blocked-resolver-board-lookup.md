# Blocked-resolver board lookup

**What it is:** When a product-board ticket list carries `number` but no `key`, the blocked-resolver can still resolve the ticket id for a fresh rebuild, and the stale-owed sweep derives the harness key as `<board keyPrefix>-<number>` rather than `#number`. A board that answers with an error instead of a ticket list (401 after a token rotation, 403, 5xx) is NOT an answer: it stays on the free transient retry and never abandons the park.

**How a user reaches it:** Not a user-facing screen. The lane runs on the hub every ten minutes (`cron/hub.cron` blocked-resolver tick) and the stale-owed sweep runs hourly.

**Key routes/screens:**
- `bin/blocked-resolver.sh` — the `br_ticket_id` board fallback and the `rebuild-fresh` board-miss cap that pages after repeated misses.
- `bin/stale-owed-tickets.sh` — the stale-ticket key derivation when `.key` is absent.
- `logs/blocked-resolver.log` — resolver decisions per tick.
- `logs/ALERTS.log` — the single abandon alert after the miss cap.
- `state/blocked-resolver/<project>/<cap-key>.json` — the resolver row showing `board_misses` and `outcome: ABANDONED`.

**Selectors:** n/a (shell/JSON surfaces only).

**Preconditions / seed needs:** A product-board project with `board_prefix` set in `fleet.conf` (the board API URL PATH, e.g. `/api/accounting/requests-board` — not a ticket-key prefix) and a working internal API token. The board must answer 2xx with a payload whose tickets carry `number` without `key`; the key prefix comes from `keyPrefix` on the `/boards` response.

**Verify it works:** `HARNESS_TEST_SANDBOX=1 bash tests/blocked-resolver.bh-1007-test.sh` exits 0 with no FAIL lines. On a live box, a blocked park with ticket key `TK-1838` resolves to the ticket id when the board row has `"number":1838` and no `key`; after three identical misses the state file reads `outcome: ABANDONED` and `logs/ALERTS.log` contains one board-miss alert. Misses two and three arrive over the rebuild-retry rung — once rung 3 has closed the PR the conductor row goes `CLOSED` and `br_from_rebuilds` is the only source that still sees the park, so the state file's later attempts carry the `enqueue retry` label. With the internal token revoked, three ticks leave `board_misses` at 0 and no `ABANDONED`.

**Manual-only / not automatable:** n/a — the suite exercises the real scripts against stubbed board and GitHub APIs.
