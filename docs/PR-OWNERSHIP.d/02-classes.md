## 2. The four classes

Decided in this order, first match wins.
UNREAD (BH-5124) is a fifth outcome that takes ORPHAN's place when the
conductor's rows cannot be read; it is never acted on.

### EXTERNAL — checked first, and touched only to close a superseded PR
The author is not in the harness author set (`bin/lib/gh-pr-list.sh`,
`HARNESS_PR_AUTHORS` — a PR opened on the GitHub App token is authored by
`app/cromford` and is just as much ours as a PAT-authored one). An external
PR belongs to `bin/review-prs.sh`, which reviews it and posts findings.

This lane **records it and stops**: no comment, no label, and no close, with
one exception. A superseded EXTERNAL PR (§10: its key already merged, its
ticket is done or rejected, or a newer PR for the same key is the one that
stays) is closed with one comment that starts `@<author>`. Its key must use a
ticket prefix this repo's own harness PRs use, and a bot author (dependabot,
renovate) never has one, so a branch like `vitest-4.1.2` or `fix/utf-8-encoding`
is never read as a ticket. At most it also enrolls it into the conductor
(below). It is first in the order rather than last because the cost of getting it
wrong is not symmetric — a sweep that can close a contractor's or a customer's
PR because our own ledger happens to have no row for it is a sweep that will
eventually do exactly that.

An EXTERNAL PR with no owner is **enrolled** into the merge conductor (§10),
behind the `pr_owner.enroll_external` knob (default `1`). At `0` it is recorded
and left alone, as above, and the log says `enroll-recorded-only`. Throwing the
switch also stops the merge of an EXTERNAL PR enrolled earlier, two ways:
the conductor reads the same knob (`mc_enroll_external_load`, once per run,
logged `pr_owner.enroll_external=<v> (<source>)`, a settings outage reads `0`)
and its keyed run no longer injects an outside author's key
(`mc_enrolled_rows`, logged `external enrollment off`); and the next sweep
withdraws that PR's READY row to `WAIT_CI enroll-withdrawn` with reviewed `-`,
so the backstop stops picking it (`enroll-withdrawn` in the log). Switching back
to `1` re-decides a withdrawn row. The knob is about OUTSIDE authors only: an
enrolled ORPHAN of ours is driven whatever it says. Enrolling never comments
on, labels or closes a PR: the conductor's own gates decide whether it merges. Once an EXTERNAL PR is enrolled (it has a merge-conductor row), the age
ladder (§10, #3935) ages it like ours, and its close comment names the author.

### OWNED
Either:
- a **ledger row** (`/api/jobs` or the build queue) for the PR's ticket key in
  `queued` / `claimed` / `running` — something is building it right now; or
- a **merge-conductor row** for `<owner/repo>#<number>` whose state is not
  terminal (`MERGED`, `CLOSED`, `ABANDONED`). The conductor is landing it, and a
  red CI, a rebase in flight and a provenance hold all read the same here — all
  three are the conductor's job. The log says `owner-source=d1|tsv` once per
  run (d1 when the `pr-state-rows` flag is up).

**Where the conductor rows come from** (`po_mc_read`,
`bin/lib/pr-owner/mc-read.sh`, BH-5124), first that answers:
1. the D1 `pr_state` view, when the conductor's own `pr-state-rows` flag is up
   (at most 5 pages of 1000; a failed or bounded read falls through);
2. `state/merge-conductor/pr-state.tsv`, but **only on the conductor's box**
   (`is_hub_box`, `bin/lib/hub-box.sh`) and only while its mtime is within
   `pr_owner.mc_max_age_s` (default 900 s, two conductor ticks).

Anything else is a failed read, and the repo's ownerless PRs are UNREAD (below).
With the view configured (`owner-source=d1`) and neither source answering, the
repo is swept not at all (`conductor rows unreadable (D1 pr_state) — swept
nothing`, BH-3933): no state file, no hook, no write. With the view not
configured, a failed read leaves the repo's PRs UNREAD; on an UNREAD repo
`po_enroll` does not run and the ownerless clock neither advances nor resets.
A stale file's rows are not used even as OWNED evidence. The row file is read
**read-only**. The conductor owns it; nothing here writes to it.

### PARKED
A human said "later, and here is when":
- the `parked` label, or
- a `Parked: <reason> until YYYY-MM-DD` line in the PR body.

An **expired** expiry is not a park. Writing the date is the whole point: the
park ends, and the PR falls through to ORPHAN on the next tick. A `parked` label
with no date, or a `Parked:` line with no date, parks indefinitely — that is a
deliberate operator act and the sweep honours it, but it is worth less than a
date, because nothing will ever ask about it again.

### OWNED by GRACE
A PR that moved less than `PR_OWNER_GRACE_MIN` (default 30) minutes ago is
OWNED, full stop. A PR opened four minutes ago has no conductor row yet because
the conductor has not ticked yet, and "no row yet" is not the same fact as
"nobody owns this" — the conductor runs every 5 minutes, and the build that
opened the PR may still be closing its own ledger row. **This lane is the
backstop, not a competitor**, and the window is what stops it closing a PR out
from under a live lane. Same reasoning, same shape, as
`bin/orphan-reconcile.sh`'s owner class (e).

It also covers the conductor's CI kick. `mc_kick_ci` closes a PR and reopens it
one REST call later to fire a `pull_request` workflow that a base change does
not fire; in the seconds between, the row can read `CLOSED` while the PR is
open. The reopen moves the PR, so grace owns it — the same hazard
`bin/reconcile-prs.sh` handles with `mc_closed_settled`.

### UNREAD
Harness-authored, no ledger owner, no park, not fresh, **and the conductor's
rows could not be read** (above). "No owner" is not a fact the sweep has, so it
does not act: no close, no label, no comment, no hand-back. `dirty_since` is
still remembered. The sweep writes one line per repo per run,
`<repo>: conductor rows unusable — <why>; <n> PR(s) with no ledger owner counted conductor-unread, no orphan action this run`,
and no alert. Until the `pr-state-rows` flag is up, a sweep on any box but the
conductor's classifies these PRs UNREAD every run.

### ORPHAN
Harness-authored, no owner, no park, not fresh, and the conductor's rows were
read. The only class this lane acts on.

