# Routing panel

**What it is:** the ROUTING section of a project's page. It shows the
project's builder routing row (builder, pool app, halted, last update) and
whether the `routing_rows` setting is on, which is what makes that row drive
the boxes' `flags/` files. It has a HALT toggle that flips only `halted`, and
the row's change log from `routing_changes`.

**How a user reaches it:** open the console → FLEET → click a project → `/p/<project>`
→ the ROUTING section at the top of the right column.

**Key routes/screens:**
- `/p/<project>`, ROUTING section: `kv` lines BUILDER, POOL APP, HALTED (a
  `HALTED` tag when halted, `no` otherwise), UPDATED, ROWS DRIVE ROUTING
  (`on` / `off` / `unknown`).
- The HALT toggle: `button[aria-label="HALT"]`, `aria-pressed` is the row's
  halted state. It is disabled with one sentence under it when there is no
  row, when `routing_rows` is off, when `routing_rows` could not be read, or
  when the row could not be read.
- Clicking it opens the in-app dialog (`role="dialog"`, `aria-label="HALT"` or
  `"UNHALT"`) with an optional `input[aria-label="reason for this routing change"]`.
- The change log: a table with AT, ACTOR, REASON, BUILDER, POOL APP, HALTED,
  every header sorts, newest AT first by default. Changed fields read
  `before → after`, a row's first write reads `(new) → x`. At most the newest
  50 rows; "newest 50 shown; older changes exist" when the worker says more.
- Reads: `GET /api/coord/routing/<p>` (404 = no row), `GET
  /api/coord/settings/routing_rows`, `GET
  /api/coord/routing-changes?project=<p>&limit=50`. Write: `PUT
  /api/coord/routing`, actor stamped `console` by the proxy, which also
  forwards the row's `updated_at` as `expected_updated_at` (BH-2488). When the
  row moved between that read and the write the worker answers 409, nothing is
  written, the section says "HALT refused — routing changed underneath you, try
  again" and re-reads the row. It never sends a second PUT on its own.

**Preconditions:** signed in to the console. A project with a routing row
(`bin/routing-seed-rows.sh --apply` creates them). With `routing_rows` off,
which is the seeded default, the toggle is disabled on purpose.

**Verify it works:** on `/p/<project>` the section shows the row or "no
routing row", and the change log or "no routing changes recorded for <p>".
Sort the log by AT and by ACTOR. Click HALT (when enabled), check the dialog
says "Halt new pool spawns for <p>? Builds already running keep going. Each
box picks this up at its next routing sync. A harness deploy clears it unless
a pool-halt .keep file holds the halt.", then press Escape or CANCEL: devtools shows no PUT. At 375px the body
does not scroll sideways; the log scrolls inside its own wrapper.

**Manual-only / not automatable:** confirming a HALT on production stops real
pool spawns for that project until an UNHALT or a harness deploy clears it. QA
drives cancel only against production.
