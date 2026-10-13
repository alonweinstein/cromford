# Restore-lab panel

**What it is:** the RESTORE LAB section of the HUB screen. It lists the last
restore-lab runs (a restore of a box's backup into a scratch dir on the hub,
then a check) and lets an operator request one for a box.

**How a user reaches it:** open the console → HUB tab → `/hub` → the RESTORE
LAB section.

**Key routes/screens:**
- `/hub`, RESTORE LAB section: a box picker, the "Restore latest into scratch"
  button, then the history table (box, snapshot, status, requested by,
  requested, finished; every header sorts, newest first by default).
- The box cell is a button. It expands that run's full row (id, verdict_detail,
  sha256, snapshot_ts, claimed_by, claimed_at and the rest) in a detail block
  under the table.
- "showing the last 20 runs" shows only when the worker answers `truncated:true`.
- Reads `GET /api/coord/hub/restore-lab` and writes `POST /api/coord/hub/restore-lab`
  `{box, snapshot:"latest", confirm:true}`. The coord proxy forwards that one
  POST; `hub/restore-lab/claim` and `hub/restore-lab/:id/result` stay 405 from
  a browser.

**Selectors:**
- `role=button[name="Restore latest into scratch"]`
- `role=dialog[name="RESTORE LAB"]` (the in-app confirm; buttons CANCEL / RESTORE)
- `role=combobox[name="box"]`
- `.restore-lab__detail` (the expanded run)

**Preconditions / seed needs:** the history renders rows only once the
restore-lab worker routes (#1944) are merged and deployed. Until then the
worker answers 501 and the section shows "could not load — not_implemented"
with RETRY, never "No restore runs yet". The picker lists the `boxes` the HUB
screen passes; while that is `[]` (until #1945) the button is disabled and the
section says "no boxes known yet".

**Verify it works:** on `/hub` the section renders one of four states:
loading, load error (with RETRY), "No restore runs yet", or the table. Click a
box cell and its detail block opens. Click the button, check the dialog text is
"Restores <box>'s latest backup into a scratch dir on the hub and verifies it.
Nothing on the live hub is touched.", then press Escape or CANCEL: devtools
shows no POST. At 375px the body does not scroll sideways; the table scrolls
inside its wrapper and a sha256 wraps.

**Manual-only / not automatable:** confirming queues a real restore on the hub.
QA drives cancel only against production.
