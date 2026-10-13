# Merge-sweep budget (`SWEEP_MERGE_BUDGET`)

**What it is:** how many already-approved tier-2 PRs one `bin/merge-sweep.sh`
tick is allowed to merge. The cap is `SWEEP_MERGE_BUDGET` (default 5,
fleet-wide across every repo the hub sweeps). The ORDER the budget is spent in
is the throughput walk ([merge-sweep-throughput.md](merge-sweep-throughput.md),
BH-710): round-robin across the projects `bin/fleet-conf.sh` knows, newest
record first inside one, so five slots land on up to five different repos before
any repo gets a second one. Only a verified `MERGED` spends budget; a skip, a
park, an enqueue or a failed attempt costs nothing.

**How an operator reaches it:** the lane is cron, not a screen.

- `cron/hub.cron` — `*/10 * * * * /root/harness/bin/merge-sweep.sh`
- One tick by hand: `SWEEP_MERGE_BUDGET=20 /root/harness/bin/merge-sweep.sh`
- To make a different cap stick: set `SWEEP_MERGE_BUDGET=<n>` in
  `/root/harness/env/global.env` on the hub (the sweep sources that file with
  `set -a`, so it and the process env are the same knob — set in both, the file
  is what the tick resolves to). Hub-only — no Vercel and no CI environment
  carries it.

**Key files:**
- `bin/merge-sweep.sh` — the `# --- Merge budget (BH-778)` config block (the
  knob, its validation and `BUDGET_SRC`), the budget line at the top of the
  walk, and the `merge budget spent this tick` break inside `sweep_order()`'s
  loop
- `/root/harness/logs/merge-sweep.log` — where both lines land
- `/root/harness/state/merge-sweep-done.txt` — the ledger fallback; a PR in here
  is never re-swept

**Verify it works:** two lines in `logs/merge-sweep.log`.

- Once per tick that evaluated at least one record:
  `[merge-sweep] budget 5 this tick (SWEEP_MERGE_BUDGET unset), spent round-robin across projects, newest record first`
- Only when the walk stopped early:
  `[merge-sweep] merge budget spent this tick — budget 5 (SWEEP_MERGE_BUDGET unset) EXHAUSTED after 5 merge(s): 2 record(s) not walked, the next */10 tick starts again at the newest`

A tick with nothing eligible writes neither line — that silence is the honest
"nothing to do", and it is the state the EXHAUSTED line exists to be
distinguishable from. An unparseable value logs
`SWEEP_MERGE_BUDGET='abc' is not a non-negative integer — using the default 5`
and sweeps on at 5; `SWEEP_MERGE_BUDGET=0` attempts nothing and says so (it is
not the kill switch — that is `flags/automerge-disabled`, which exits before the
walk and logs nothing).

**Drive it:** `HARNESS_TEST_SANDBOX=1 bash tests/merge-sweep-budget-test.sh`.
The suite copies the real script into a scratch `$HARNESS` with three projects
of uneven backlog (a x4, b x2, c x1), stubs `gh` and `curl`, and asserts the
ORDER of the merge calls and the contents of `logs/merge-sweep.log` — never the
source text of the loop. The three log lines quoted above are printed by the
suite itself (`evidence:` lines), so this entry can be diffed against a real run.

**Manual-only / not automatable:** the hub tick itself. The fixture proves the
budget, the order and both log lines; that a real `SWEEP_MERGE_BUDGET=20` tick
lands 20 real merges can only be seen on the hub, against live GitHub state.
