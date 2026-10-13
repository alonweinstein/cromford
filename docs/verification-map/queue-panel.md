# QUEUES panel

**What it is:** the QUEUES section of a project's page: the project's build
queue, deploy queue and merge trains, with an audited action on a row. BH-3150
shipped the contract. BH-3151 filled the BUILD QUEUE table and its RELEASE /
DROP. BH-3152 made the DEPLOY QUEUE table and its RELEASE live. BH-3153
filled the read-only MERGE TRAINS table. BH-3154 added HOLD / UNHOLD on a
deploy-queue row.

The DEPLOY QUEUE table lists the project's `queued`, `claimed` and `held`
`deploy_queue` rows (SHA, STATUS, CLAIMED BY, BUILD DIR, ENQUEUED, ACTION),
oldest first, under a note saying whether the `deploy_queue_rows` knob is on,
off, not set, or unreadable. A claimed row that has not departed offers
RELEASE: an in-app confirm with a required reason, then the row goes back to
`queued` with its claimant cleared and one `RELEASED` stage event
(`job_id = deploy-queue:<project>/<sha>`) records who and why, so the next
train claims it again.

**How a user reaches it:** open the console → FLEET → click a project →
`/p/<project>` → the QUEUES section at the top of the right column, directly
above ROUTING.

**Key routes/screens:**
- `/p/<project>`, QUEUES section: a header with the note "build queue, deploy
  queue and merge trains for this project", then the BUILD QUEUE table, the
  DEPLOY QUEUE table (`DeployQueuePanel`) and the MERGE TRAINS table
  (`MergeTrainsPanel`), each polled every 30 s.
- BUILD QUEUE: one sortable table (default ENQUEUED, oldest first) of the
  project's `ready`, `queued` and `claimed` build_queue rows. Columns KEY,
  STATUS, TARGET, ATTEMPT, CLAIMED BY, MACHINE, ENQUEUED, CLAIMED, ACTION. KEY
  links to `/history?tab=builds&project=<p>`. A `claimed` row offers RELEASE,
  a `ready` or `queued` row offers DROP. Each opens an in-app dialog whose
  confirm stays disabled until a reason is typed. After the answer a banner
  says what the worker decided (DISMISS clears it) and the table reloads.
  Empty: "nothing queued". A failed read: the error with RETRY. A status that
  hit its 500-row read: "showing the first 500 per status; more rows exist".
- MERGE TRAINS (BH-3153): one `SortableTable` with BRANCH, OUTCOME, MEMBERS,
  MEMBER COUNT, TRAIN PR and UPDATED, newest updated first. TRAIN PR and each
  member number link to `/pr/<project>/<n>`; a train with no PR yet shows `—`
  as text, and so does a null member count. States: a skeleton before the
  first answer, "no trains yet" on an empty answer, an ErrorBox with RETRY on a
  failed read or a body without `merge_trains` (also when a refresh fails with
  old rows held), and "newest 50 shown; older trains exist" when 50 rows come
  back.
- Reads: `GET /api/coord/queue?project=<p>&status=<ready|queued|claimed>&limit=500`
  (the build queue, three reads); `GET /api/coord/deploy-queue?project=<p>&status=queued&limit=500`,
  the same with `status=claimed` and with `status=held`, and `GET /api/coord/settings/deploy_queue_rows`
  (the deploy queue); `GET /api/coord/merge-trains?project=<p>&limit=50`
  (the merge trains; the worker clamps any limit to 200).
- Writes: `POST /api/coord/queue/action` `{project, key, action, reason}` and
  `POST /api/coord/deploy-queue/action` `{project, sha, action, reason}`. The
  proxy stamps the actor, drops every other field, and answers 400 on a blank
  reason before any worker call. `PATCH queue`, `POST queue/claim`,
  `POST deploy-queue/claim` and `POST deploy-queue/depart` are 405 from a browser.
- Worker `POST /api/queue/action` (`worker/jobs/src/routes/queue-actions.js`):
  `release` moves `claimed` to `queued`, clears claimed_by, claimed_at and
  machine, keeps attempt, and sets reason `RELEASED by operator`. `drop` moves
  `ready` or `queued` to `failed` with finished_at and the FIXED reason
  `DROPPED by operator (queue-action)`. The operator's text goes only into the
  audit event. Each landed action writes one `stage_events` row with job_id
  `queue:<project>/<key>`, stage `queue`, verdict `RELEASED` or `DROPPED`, the
  actor, and detail `{reason, from, to}`. Refusals are 409 `refused:true`:
  RELEASE of anything not claimed, DROP of a claimed row ("ABANDON the job
  instead"), DROP of any other terminal row, and a row that moved between the
  read and the write ("row moved, reload"). A second DROP of a dropped row
  answers 200 `decision:"already"` and writes nothing. A blank reason, missing
  actor, unknown action or bad project/key is a 400. A missing row is a 404.
- Worker `POST /api/deploy-queue/action`
  (`worker/jobs/src/routes/deploy-queue-actions.js`): `action:"release"`
  answers 200 `{decision:"released"}` on a claimed, undeparted row; 409
  `refused:true` on any other status, on a departed row, or when the row moved
  between the read and the write; 404 when no row exists; 400 on an unknown
  action (the names are case-sensitive: `HOLD` is unknown) or a blank reason
  or actor, before any read. `action:"hold"` is 200 `{decision:"held"}` on a
  `queued` row and 409 on any other status, or when the `deploy_queue_rows`
  settings row is not exactly `1|on|true|yes` (a missing row included):
  `hold refused: deploy_queue_rows is not on, trains read the file dir`.
  `action:"unhold"` is 200 `{decision:"unheld"}` on a `held` row, 409
  otherwise, and is never knob-gated.

**Preconditions:** signed in to the console. Rows in the project's build queue
deploy queue (`deploy_queue_rows` on, so the deploy lane writes rows) and merge
trains for the tables to show anything.

**Verify it works:** on `/p/<project>` the QUEUES header sits above ROUTING and
the BUILD QUEUE table lists the project's live rows. Click each header twice
and the arrow flips. DROP a `queued` row with a reason: the banner says
"Dropped <KEY>." and the row leaves the table. The row now reads `failed` in
`GET /api/coord/queue?project=<p>&key=<KEY>`. Under DEPLOY QUEUE the knob note
shows. With no queued, claimed or held rows it says "nothing queued"; with
rows, ENQUEUED sorts ascending and a header click flips the arrow, RELEASE
shows only on a claimed row, UNHOLD only on a held row, and HOLD only on a
queued row while the knob is on. Click RELEASE: the modal opens, RELEASE in it stays
disabled until a reason is typed, Escape cancels. Confirm: the banner reads
"Released <sha8>: back to queued." and the row shows `queued` after the
reload. HOLD a queued row the same way: the banner reads "Held <sha8>: the
train will not depart while it is held." and the row shows `held` with UNHOLD;
UNHOLD it: "Unheld <sha8>: back to queued.". A failed read shows "could not load" with RETRY, never "nothing
queued". The MERGE TRAINS table renders (or "no trains yet"); clicking a
TRAIN PR cell or a member number opens `/pr/<project>/<n>`. At 375px the body does not scroll sideways; each table scrolls in its
own container.

**What usually lies:**
- a DROPPED row is `failed` in build_queue with reason `DROPPED by operator
  (queue-action)`. That is an operator's decision, not a build failure. The
  audit event carries who and why.
- a build-queue RELEASE does not stop anything. If the build was alive it keeps
  running, and the released row can be claimed again, so a second build can start.
- a deploy RELEASE with deploy_queue_rows off changes a row no train reads: the
  trains still read `state/deploy-queue/` files. The note and the confirm say so.
- the deploy queue's "nothing queued" means no `queued`, `claimed` or `held`
  row; `done` and `failed` rows are not fetched.
- a HOLD taken while the knob was on keeps pausing that project's train if the
  knob is later turned off, and one ALERTS line says so. That holds only on a
  box whose train saw the knob on at least once
  (`state/deploy-hold-armed/<project>`). A box that never did makes no held
  read with the knob off.
- no HOLD button on a queued row means the knob is off, not set, or unreadable
  here, not that the row cannot be held.
- MEMBER COUNT is the count the train was recorded with; MEMBERS shows the
  first three numbers and "+N more".

**Manual-only / not automatable:** the 375px check and clicking through a real
RELEASE / DROP need a browser against a live worker. A real deploy RELEASE
writes a `deploy_queue` row and a `stage_events` row, so drive it on a claimed
row whose train is known to be dead. A real HOLD stops that project's deploy
train until someone UNHOLDs it, so drive it only on a project whose deploys
can wait. The routes and screens are driven by
`tests/build-queue-panel-console.bh-2510-test.sh` and
`tests/deploy-queue-panel-console.bh-2510-test.sh`.
