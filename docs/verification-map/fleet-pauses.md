# Fleet pauses (console view and controls, BH-1672.4, BH-2509)

**What it is:** a pause is a row in the jobs worker's `pauses` table (scope
`fleet` or a project, what `triage|reviews|merges|builds`, a reason, an actor,
an expiry). The contract is the header of `bin/lib/pause.sh`. Mission Control
shows the live ones and lets an operator set and end them.

**How a user reaches it:**
- Fleet (`/`), the PAUSES section just above PROJECTS, and the FLAGS column of
  the PROJECTS table. The `PAUSE FLEET…` button sits right-aligned just above
  the PAUSES section, and it renders even when no pause is live.
- A project page (`/p/<project>`), then the PAUSE button in the header (or
  RESUME while the board's `paused-<project>` flag is on). The pause lines sit right under
  the header row.

**Key routes/screens:**
- `/`: the PAUSES table (SCOPE, WHAT, REASON, ACTOR, AGE, EXPIRES, END). Every
  header except END sorts, and the default is EXPIRES ascending. A project
  scope links to `/p/<project>`, and fleet scope is plain text.
- `/` PAUSES table: the ACTOR cell shows a `console` actor as
  `console (no verified identity)`, and hovering an AGE cell shows the row's
  `created_at`.
- `/` FLAGS cell: a red `PAUSED(<what>)` tag for each live row covering that
  project. Fleet rows tag every project. The title reads
  `<reason> · by <actor> · <age> ago (<created_at>) · <scope>`. The old amber
  `PAUSED` is the board's `paused-<project>` flag (a `harness_flags` row since
  BH-4153, reported by the box's `progress-push`), and it still shows beside the red tags. Its
  title is that project's live triage row in the same format, or, with no such
  row, `paused by flag file: no pause row on record, reason and actor unknown`.
- `/` PAUSE FLEET…: an in-app modal with WHAT (select, default merges), REASON
  and TTL (SECONDS, placeholder `1800 = 30 min`). Both REASON and TTL are
  required: the dialog's PAUSE FLEET button stays disabled with an inline hint
  until both are valid, and a TTL that is not a whole number above 0 is refused,
  never rounded. Confirm sends `pause_set {scope:"fleet", what, reason, ttl_s}`
  and the banner says `PAUSE FLEET queued as command #N`.
- `/` END: the dialog asks for a REASON and stays blocked until one is typed.
- `/p/<project>` PAUSE: an in-app modal with WHAT (select, default triage),
  REASON (required: the dialog's PAUSE button stays disabled, with an inline
  "A reason is required" line, until one is typed) and TTL (SECONDS, blank =
  the worker's `pause_default_ttl_s`).
- `/p/<project>` RESUME: an in-app modal with a required REASON, blocked until
  one is typed. It sends `resume_board {project, reason}`.
- `/p/<project>` pause lines: one line per live row covering the board (fleet
  rows included), a red `PAUSED(<what>)` tag plus
  `<reason> · by <actor> · <age> ago (<created_at>) · <scope>`. With the flag
  file set and no triage row for this project, one amber `PAUSED` line reads
  `paused by flag file: no pause row on record, reason and actor unknown`.
  Nothing renders when the board has neither.

**Selectors:**
- the section whose title is `PAUSES`, its table, `th[aria-sort]`
- `role=dialog[name="END PAUSE"]`, `role=dialog[name="PAUSE"]`,
  `role=dialog[name="PAUSE FLEET"]`, `role=dialog[name="RESUME"]`
- the `PAUSE FLEET…` button (`button.btn--warn` above the PAUSES section)
- `ul.pause-detail` (`aria-label="pauses on this board"`) on `/p/<project>`
- `.tag--bad` (the red tag; there is no data-testid)

**Reads and writes:**
- read: `GET /api/coord/pauses?active=1`, polled every 30 s. The generic coord
  proxy forwards it. Rows past `expires_at`, or with one that does not parse,
  are dropped in the browser.
- read on `/p/<project>`: the same `GET /api/coord/pauses?active=1`, every
  30 s. A failed read shows no row lines; the flag-file line still shows.
- the Pages function in front of `/api/dash/action`
  (`console-ui/functions/api/[[path]].js`) answers 400 and forwards nothing
  for `pause_board`, `resume_board` or `pause_set` without a non-blank string
  `reason` (`reason required`), and for a `pause_set` with scope exactly
  `fleet` without a whole-number `ttl_s` above 0
  (`ttl_s required for a fleet pause`). `pause_end` needs no reason there.
  Telegram and the MCP tool do not go through it.
- writes are console commands through `/api/dash/action`, executed by
  `bin/poll-commands.sh` on the hub. `pause_set`/`pause_end` and the
  pass-through of reason, `ttl_s` and scope need the cromford-console
  action endpoint change (see the PR body); a fleet-scope command is routed
  there to project `hub`. The worker 400s a blank reason, so a command with
  none records "paused from console, no reason given":
  - `pause_board {reason?, ttl_s?}`: the `paused-<p>` flag first (a
    `harness_flags` row since BH-4153; a flags/ file only on a box with no
    worker configured), then
    `PUT /api/pauses {scope:<p>, what:"triage"}`
  - `resume_board`: the `paused-<p>` flag off, then `POST /api/pauses/<id>/end` for this
    project's live triage row only
  - `pause_set {what, reason?, ttl_s?, scope?}`: `PUT /api/pauses`, scope
    `fleet` only when the payload says exactly that
  - `pause_end {id, scope?}`: `POST /api/pauses/<id>/end`
  - END on a project triage row sends `resume_board`; every other row sends
    `pause_end`.

**Preconditions / seed needs:** the worker `/api/pauses` routes deployed and at
least one live row. Until the sibling that implements them lands, the read
fails and the page shows no PAUSES section and no red tag. That is by design,
not a defect. `pause_board`/`resume_board` then still act on the flag, and the
command RESULT says the row was not recorded or ended.

**Verify it works:**
- With a live row, the PAUSES section lists it and the FLAGS cell carries the
  red tag.
- END, type a reason, then confirm, answers "END PAUSE queued as command #N",
  and the row is gone on the next poll after the poller ran.
- PAUSE FLEET with merges, a reason and 1800 answers
  "PAUSE FLEET queued as command #N". After the poller ran, the PAUSES table
  has a `FLEET (all projects)` row and every project's FLAGS cell has a red
  `PAUSED(merges)`. `tests/fleet-pause.bh-2509-test.sh` drives that command
  through the real poller block and the real merge sweep on two projects, then
  END, and proves both PRs merge only after END.
- The command's RESULT on the commands feed is `pause <id> ended`, or
  `resumed` for a triage row.

**Manual-only / not automatable:** PAUSE and END change what the fleet does,
so drive them only on a project where a pause is wanted. A bad TTL is refused
in the browser with "PAUSE refused — …" and sends nothing, and that path is
safe to drive. So are the PAUSE FLEET dialog with a blank reason or TTL (the
button stays disabled) and a blank-reason POST to `/api/dash/action`, which
answers 400.
