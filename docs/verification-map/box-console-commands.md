# Box console commands contract (dark)

**What it is:** The storage and client half of forwarding a console command to a box without ssh (BH-2653, part 1 of BH-2528). It is a D1 table, `box_console_commands`, and four shell verbs in `bin/lib/jobs/box-console-commands.sh`. This slice shipped no worker routes, no lane and no caller; the sibling slices (#2654-#2657) add them, and the hub caller is described below. This is a different queue from #2518's `box_commands` and shares no table, route or verb name with it.

**Hub caller (BH-2657):** since BH-2657 `bin/poll-commands.sh` is the caller. Its seven box-owned handler blocks call `box_ccmd_forward` for a project another box owns (no ssh), and its `# >>> box-command expiry (BH-2528)` block calls `box_ccmd_expire "${BOX_CONSOLE_COMMANDS_TTL_S:-300}"` once per sub-cycle. Verify: `HARNESS_TEST_SANDBOX=1 bash tests/poll-commands-forward.bh-2528-test.sh` exits 0.

**How a user reaches it:** Not a screen of its own. A console command (triage, a log or artifact fetch, chat, a map update, a proposal action) for a project another box owns is queued here by the hub.

**Key routes/screens:**
- `worker/jobs/schema.sql`: `box_console_commands` (`command_id` PK, `box`, `type`, `project`, `payload`, `status`, `ok`, `result`, `body`, `claimed_at`, `finished_at`, `actor`, `created_at`, `updated_at`) and `idx_box_console_commands_box` on `(box, status, created_at)`.
- Settings seeds (`INSERT OR IGNORE`, so an operator edit survives a re-apply): `lane.box-console-commands.box_console_commands_ttl_s` = `300`, `lane.box-console-commands.box_console_commands_claim_limit` = `10`.
- `bin/lib/jobs/box-console-commands.sh`, sourced after `bin/jobs-client.sh`. It is not in `JC_MODULES`.

**Wire contract the client sends** (the routes are for #2654 to build to):

| Verb | Request | 2xx answer the verb accepts |
|---|---|---|
| `box_ccmd_forward <id> <box> <type> <project> <payload-json>` | `POST /api/box-console-commands` `{command_id, box, type, project, payload}` | any body, printed as-is (`{created:true\|false}`) |
| `box_ccmd_claim <box> <limit>` | `POST /api/box-console-commands/claim` `{box, limit}` | a bare JSON array of the claimed rows |
| `box_ccmd_result <id> <box> <ok> <result> [body-file]` | `POST /api/box-console-commands/<id, URL-encoded>/result` `{box, ok, result, body}` | any body, printed as-is |
| `box_ccmd_expire <ttl_s>` | `POST /api/box-console-commands/expire` `{ttl_s}` | an object whose `expired` and `stale_claimed` are arrays |

- `payload` is a JSON **string** holding the console payload text byte-for-byte. The verb refuses a payload that does not parse as JSON. An empty `project` is `null`.
- `ok` is the number `0` or `1`. `body` is the body file's text, or `null` when no file is given.
- `limit` and `ttl_s` are positive integers. The verbs take them as arguments. The settings rows are for the lane slice to read.
- A body over 64 KB (a 300 KB payload, say) goes to curl as `--data-binary @file`, not on argv.

**rc map:** 0 only on a 2xx with the accepted answer above. 1 on bad input (no request made), unset or empty `JOBS_URL`, unset `HARNESS_SECRET`, an unreachable worker, a 5xx, a 413 or a malformed 2xx. 2 on a 404, 9 on a 409. `JOBS_HTTP` is left as `_jobs_req` set it. A failed call prints nothing.

**Selectors:** n/a (shell and SQL only).

**Preconditions / seed needs:** none for the tests. On a box, the table reaches D1 when `bin/harness-sync.sh` applies `schema.sql` on the next sync after merge.

**Verify it works:** `HARNESS_TEST_SANDBOX=1 bash tests/box-console-commands-client.bh-2528-test.sh` exits 0. It drives the real `bin/jobs-client.sh` and the lib against a stub curl. `(cd worker/jobs && node --test test/box-console-commands-schema.bh-2528.test.js)` applies `schema.sql` twice through `node:sqlite` and checks the columns, the index, the seeds and that a re-apply keeps rows and operator edits. Prod probe after the sync: `SELECT key, value FROM settings WHERE key LIKE 'lane.box-console-commands.%'` returns the two rows.

**Manual-only / not automatable:** the prod D1 apply, which the next `bin/harness-sync.sh` run does.
