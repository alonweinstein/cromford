# Resolver mechanical rungs (`bin/lib/br/opt/mechanical.sh`)

**What it is:** the first optional module of `bin/blocked-resolver.sh`, plugged
into the seam BH-1468 shipped. It answers two parks with a git operation instead
of a paid model call:

- **Carry** — a `head-not-reapproved` park means main moved under a PR whose
  APPROVE was bound to the sha a reviewer read. When the branch's own added and
  removed lines are identical (declared generated files excluded, because those
  are a function of the tree), the ledger verdict is rebound to the live head and
  no re-review is bought.
- **Conflict classify** — a `conflict-unresolvable` park whose ONLY conflicting
  paths the repo declares generated or union-mergeable is rebased purely onto the
  base and force-pushed to its own branch. When a real source file conflicts,
  the sorted path set and a stable 12-hex key are written on the record for the
  cross-ticket cluster round (#1457's R14) and today's ladder runs unchanged.

`bin/lib/br/opt/README.md` is the normative hook table; this page is how an
operator verifies the two rungs on a box.

**How a user reaches it:** there is **no UI route**. Three observable surfaces:

- `grep 'EVENT carried\|EVENT mechanical\|EVENT conflict-clustered' /root/harness/logs/blocked-resolver.log`
  — one line per rung transition.
- `tail -1 /root/harness/logs/blocked-resolver.log` — the `tick:` line's
  `carried=` and `mechanical=` fields, which this module is what finally moves
  off 0.
- `jq '.attempts[-1], .conflict_cluster, .conflict_cluster_key' /root/harness/state/blocked-resolver/<project>/<cap-key>.json`
  — the `carry` / `mechanical-regen` attempt, and the cluster a source conflict
  wrote.

**The primary lane** is `cron/hub.cron`, `4,14,24,34,44,54 * * * *`
(`bin/blocked-resolver.sh`). The hooks are called inside `br_one`, after the
already-merged guard and before the ladder resolves a rung.

**Key behaviours to drive:**

- **A carry rebinds, it does not merge.** Nothing here runs `gh pr merge` and
  nothing pushes to a base branch. On GitHub the PR's head is UNCHANGED and the
  ledger verdict now names it; the conductor row moves to `WAIT_REVIEW` with
  `APPROVE`.
- **Send first, write after.** `job_verdict_rebind`'s rc is READ: rc 1 (no row
  or an outage) and rc 2 (a row that makes no reviewed-sha claim to move) are
  both "not rebound", and then nothing is recorded, nothing transitions, nothing
  is counted, and today's ladder runs.
- **A regen-rebase pushes exactly once**, from inside `mrt_rebase_pure`. Its
  rc 2 (the rebased patch is not the same patch) and rc 3 (the repo's generated
  files do not settle) push nothing and fall through to the ladder.
- **`unknown` is never `clean`.** A git that is missing, a `merge-tree` that
  exits 2, a conflicting path list that will not parse: each answers `unknown`
  and the module declines. An empty generated-files table allows NOTHING.
- **Observe mode** logs one `WOULD carry` or `WOULD regen-rebase` line, pushes
  nothing, writes no state and counts nothing.
- **Kill switch.** `BR_OPT_OFF=mechanical` leaves the file on disk unsourced and
  both rungs disappear; the lane is byte-for-byte what it was before.

**Selectors:** not applicable — no rendered screen. The observable artifacts are
the `tick:` line, the `EVENT` lines, the record json, and the PR's head sha.

**Preconditions:** the hub box (the lane is hub-scoped and gated on the hub
lease); `bin/lib/mc/train.sh` present under `$HARNESS/bin/lib/mc/` (it arrives
with any `bin/harness-sync.sh`); a local clone at `/root/repos/<project>` and a
git credential that can read the repo. Any of them missing is a decline, not an
error.

**Tests that pin it:** `tests/blocked-resolver-carry.bh-1470-test.sh` and
`tests/blocked-resolver-conflict-class.bh-1470-test.sh` drive the real lane
against a scratch `$HARNESS` and a real bare git origin;
`tests/blocked-resolver-opt-hooks.bh-1468-test.sh` owns the seam itself.
