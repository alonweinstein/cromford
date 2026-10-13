# Blind PR lists (N consecutive failures = one page)

**What it is:** every lane that lists PRs reports a failed list through
`gh_repo_list_failed` in `bin/lib/gh-repo-token.sh`. On the TRANSIENT branch —
the repo is visible and the API bucket has room, so the list failed for weather —
that call bumps a per-(lane, repo) consecutive-blind counter, and at N
consecutive failures (default 3) it writes ONE `logs/ALERTS.log` line plus one
`fleet_alert` beat naming how long the lane has been blind on that repo and what
that blocks. Further blind ticks are silent. The first successful list writes one
`list recovered for <slug> after N blind ticks (Nm)` line into the lane's own log
and clears the counter and the dedupe flag.

**The two failures that are NOT counted:** a repo no credential can see, and an
exhausted API bucket. Each already writes its own single, specific ALERTS line
(`repo <slug> is INVISIBLE to the default gh token …`, `GitHub API
rate-limited: …`) and returns before the bump. Counting them too would page a
second time for one outage, in the vaguer words "rate-limited or unreachable" —
which is the noise this counter exists to remove.

**How an operator reaches it:** no UI. `logs/ALERTS.log` carries the page,
`logs/<lane>.log` carries the per-tick transient line and the recovery line, and
`ls state/blind-list/` shows a file only while some lane is mid-streak. The
directory is created lazily by the first failed list, so on a box that has never
had a blind tick it does not exist at all — `ls` answers "No such file or
directory" and that is the healthy state, not a fault.

**Primary lanes / scripts:**
- `bin/lib/gh-repo-token.sh` — the counter, the knobs, the alert, `gh_repo_list_ok`.
- `bin/merge-conductor.sh` — calls `gh_repo_list_ok merge-conductor "$SLUG"` after a
  successful open list; it is the lane whose blindness stops PRs being enqueued.
- `bin/pipeline-health.sh`, `bin/pr-owner-sweep.sh`, `bin/jobs-watchdog.sh` — call
  `gh_repo_list_failed` and so get the counter, with no reset call of their own.
  The inactivity window is what keeps their counters honest, and because a new
  streak also drops the dedupe flag they can page again after a real gap rather
  than once per (lane, repo) for the life of the box.

**State and flags:**
- counter: `$H/state/blind-list/<lane>-<owner_repo>`, one line, `count first_blind_epoch last_blind_epoch`.
- dedupe flag: `$H/flags/alerted-blindlist-<lane>-<owner_repo>`. Touched BEFORE
  the ALERTS write, so a crash between them costs a page rather than duplicating
  one. Cleared on recovery and at the start of a new streak, NOT per day: a lane
  blind across midnight pages once, and a lane that recovers and goes blind again
  pages again.
- beat akey: `blindlist:<lane>:<owner/repo>`.

**Knobs** (settings row → env var → code constant, the same order
`gh_budget_min_remaining` uses; no seed row ships, because per
[settings-knobs.md](settings-knobs.md) "no row" is a real answer that sends a
consumer to its fallback):
- `blind_ticks_alert` / `BLIND_TICKS_ALERT` — consecutive blind ticks before the
  page, default 3. A non-numeric or <1 value writes one line into the lane's log
  and uses 3.
- `blind_ticks_window_secs` / `BLIND_TICKS_WINDOW_SECS` — how far apart two
  failures can be and still count as consecutive, default 7200. A failure past
  the window restarts the streak at 1 and drops the dedupe flag.

**How to drive it:**
- `HARNESS_TEST_SANDBOX=1 bash tests/blind-ticks-alert.bh-847-test.sh` — first
  tick logs only the existing transient line, the 3rd pages exactly once with the
  "since HH:MMZ" and "no PR on <slug> can be enqueued" wording, the 4th is
  silent, recovery writes one line and clears state, `BLIND_TICKS_ALERT=2` / junk
  values, a `setting_get` stub beating the env var, per-lane and per-repo
  separation, the stale-window restart, a corrupt counter file, three invisible
  and three exhausted ticks each paging exactly once with NO counter file, a
  stale counter plus a stale flag paging again, the conductor's reset call pinned
  by a guard that fails on absence, and a mutation check that deletes the counter
  write.
- `HARNESS_TEST_SANDBOX=1 bash tests/gh-repo-token-test.sh` — the invisible-repo
  and exhausted-budget alert paths, unchanged by the counter.

**Preconditions / seed needs:** none beyond the fixture `gh` shim. On a live box
the counter appears by itself the first time a list fails.

**Verify it works:** `tests/blind-ticks-alert.bh-847-test.sh` reports
`47 passed, 0 failed`; on the hub, `ls /root/harness/state/blind-list/` is absent
or empty while every lane is listing normally (absent on the hub at 2026-09-18
18:05Z, which is the pre-merge baseline).

**Manual-only / not automatable:** watching a real rate-limited hour on the hub
(the fixtures simulate it).
