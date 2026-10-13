# Hub recovery

**What it is:** the console screen and worker routes for recovering the hub:
who holds the hub lease, each box's backup stamps, promoting a standby to hub,
and the restore lab (restore a box's backup somewhere safe and check it).
BH-1942 set the contract; BH-1945 built the screen's lease, role, backups and
promote parts on it. `GET /api/hub/recovery` and `POST /api/hub/promote` are
live since BH-1943 (see [hub-lease.md](hub-lease.md)); the four restore-lab
routes still answer 501.

**How a user reaches it:** open the console → HUB tab (top nav on desktop, the
bottom nav on a phone; it sits just left of SETTINGS) → `/hub`.

**Key routes/screens:**
- `/hub` — the HUB screen (`console-ui/src/screens/Hub.js`, rules in
  `console-ui/src/lib/hub.js`). It loads `GET /api/coord/hub/recovery` once on
  open and on RELOAD (no polling). With data: a LEASE section (holder, epoch,
  time left, an `EXPIRED` pill when the lease is not live, "as of HH:MM:SSZ"
  from the fetch), a ROLE section (active, expired holder, the standby list or
  "Standby: none recorded (#401)"), and a BACKUPS table (BOX linking to
  `/machines`, STATE pill from the same `backupBadge` the Fleet tiles use, AGE,
  LAST REPORTED; every header sorts on what it shows, rows with no age or report sink). A load failure is a
  red banner with RELOAD, never shown as the empty state; a 501 from an older
  worker reads "could not load — The hub recovery API is not deployed yet (501)."
- PROMOTE (header button) opens the in-app modal: TARGET select (every
  reported box but the holder), REASON, and "Type the box name to confirm".
  PROMOTE in the modal stays disabled until the typed name is the chosen box
  exactly and a reason is given. It sends `{target, expected_epoch, actor:
  "console", reason, confirm:true}` with the epoch shown when the modal opened.
  The coord proxy allows `POST hub/promote` since BH-2105, so the request
  reaches the live BH-1943 route. A 409 `stale_epoch` reads "The lease moved
  since you loaded this page (now epoch N held by X). Reload and check before
  promoting." A 405 from a proxy without the allowlist entry reads "The console
  proxy does not allow promote yet (405). Nothing was changed." Disabled, with a
  tooltip, when there is no lease or no other box.
- Worker (bearer-gated). Live since BH-1943: `GET /api/hub/recovery` and
  `POST /api/hub/promote` (section "Hub recovery routes (BH-1943)" in
  [hub-lease.md](hub-lease.md)). Still `501 {"error":"not_implemented","ticket":"BH-1909"}`:
  `POST /api/hub/restore-lab`, `GET /api/hub/restore-lab`,
  `POST /api/hub/restore-lab/claim`, `POST /api/hub/restore-lab/:id/result`
  (`:id` numeric). The request and response shapes are in the header comments
  of `worker/jobs/src/routes/hub-recovery.js` and `restore-lab.js`.

**Selectors:**
- `role=heading[name="HUB"]` — the page heading
- `role=link[name="HUB"]` — the nav tab
- `role=button[name="RELOAD"]`, `role=button[name="PROMOTE"]` — header buttons
- `role=alert` — the load-error banner
- `table.tbl th[aria-sort] button` — the backups table's sort headers
- `role=dialog[name="PROMOTE A HUB"]` — the promote modal

**Preconditions / seed needs:** real data needs #1943 (promote + recovery
read) deployed; until then drive the screen with `/api/coord/hub/recovery`
intercepted and answered with the contract shape. #1944 (restore-lab routes)
and #1946 (restore-lab panel) are still to come. The console's coord proxy
forwards the GETs but not the two POSTs: BH-1945 left `hub/promote` off its
write allowlist on purpose (it is a separate, security-reviewed change), so the
promote path is inert in production until that follow-up lands.

**Preconditions / seed needs:** none for the stub. The siblings replace it:
#1943 (promote + recovery read), #1944 (restore-lab routes), #1945 (HUB screen),
#1946 (restore-lab panel). The console's coord proxy forwards the GETs and
both POSTs: `hub/promote` (BH-2105) and `hub/restore-lab` (BH-1946) are in its
write allowlist.

**Verify it works:** `/hub` shows the HUB tab active with the lease and role
sections and the backups table (with the recovery answer mocked or live): each
header sorts, and a BOX cell navigates to `/machines`. A failed load is the red
banner with RELOAD, not an empty table. At 375px there is no horizontal body
scroll; the table scrolls inside its own wrapper. Probe a stub:
`curl -s -H "Authorization: Bearer $HARNESS_SECRET" "$JOBS_URL/api/hub/restore-lab"`
answers 501 with the body above.

**Manual-only / not automatable:** promote moves the live hub lease and must
never be driven against production by QA: mock `POST /api/coord/hub/promote`
(e.g. to 409 `stale_epoch`) and check the copy; `GET /api/hub/recovery` is the
read-only check. The focus check is by hand: type the box name one character
at a time and confirm focus stays on that input after PROMOTE enables (D39);
Escape cancels.
