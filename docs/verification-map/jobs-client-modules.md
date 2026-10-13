# The jobs-client module seam (the client sources `bin/lib/jobs/`)

**What it is:** `bin/jobs-client.sh` — the fail-open client every lane on every
box uses to talk to the harness-jobs coordination DB — is now a SHIM. The
bootstrap (harness root, env file, `HARNESS_SECRET`) stays in the file; all 132
verbs live in nine per-domain modules under `bin/lib/jobs/`, named on one
literal `JC_MODULES=` line and sourced in that order (BH-1194). Nothing moved
between callers and nothing changed shape: every function kept its name, its
body byte for byte, and its module is now the only place it is defined.

The nine: `req` (transport, identity, timeouts, the one transport retry, the
fail-open contract), `queue` (pre-claim build queue, pre-plans, merge queue,
wakes), `flags` (pause flags; DB row is the truth, `flags/` file is its cache),
`settings` (review gate + operator settings), `lanes` (lane liveness ticks),
`cost` (metrics ledger, vendor spend, PR costs, cost rows, outcomes, flakes),
`jobs` (the job row: claims, lane lifecycle, phases, heartbeats, rules, retry
policy, artifacts, transcripts, verdicts, contracts, caps, catalog, and the hub
ledgers of record), `machines` (the Fly machine registry, account leases, the
shared GitHub rate budget), `alerts` (the fleet's incident rows: note, state,
resolve, the lane and flush claims, and the list and family readouts —
BH-1068).

**How a user reaches it:** there is no screen and no cron line of its own — the
seam runs on every single source of the client, which is most cron lines on
every box (`bin/run-triage.sh`, `bin/merge-conductor.sh`, `bin/fly-dispatch.sh`,
`bin/blocked-resolver.sh`, `bin/harness-sync.sh`, `fly/builder-runner.sh`, …)
plus every direct `bin/jobs-client.sh <verb>` call. Look for
`# >>> jobs modules` in `bin/jobs-client.sh`.

**Key routes/screens:**
- `bin/jobs-client.sh`, the `# >>> jobs modules` … `# <<< jobs modules` block —
  the literal list, the `BASH_SOURCE`-relative module dir, and the refusal
- `bin/lib/jobs/{req,queue,flags,settings,lanes,cost,jobs,machines,alerts}.sh`
- the CLI dispatch block at the bottom of the shim — unchanged, and every verb
  in it is checked against what sourcing actually defines

**Selectors:** none (no UI). The seam is addressed by its markers:
`awk '/^# >>> jobs modules/{f=1;next} /^# <<< jobs modules/{exit} f' bin/jobs-client.sh`,
and the module list by `grep '^JC_MODULES=' bin/jobs-client.sh`.

**Preconditions / seed needs:** a tree with `bin/lib/jobs/*.sh` beside
`bin/jobs-client.sh`. Modules resolve off `BASH_SOURCE`, not `$HARNESS`, because
~100 fixture suites copy the client standalone into a scratch harness; those
fixtures copy the modules too (`mkdir -p <bin>/lib/jobs && cp "$DIR"/bin/lib/jobs/*.sh …`),
which the suite below ratchets. On a real box `bin/` ships as a tree —
`bin/harness-sync.sh` (rsync) and `bin/fly-sync-harness.sh` (tar) carry the new
directory with no change, exactly as they carry `bin/lib/mc/` and `bin/lib/rb/`.

**Verify it works:** `HARNESS_TEST_SANDBOX=1 bash tests/jobs-client-modules.bh-1194-test.sh`
— 1,449 assertions: the literal list; each module readable and `bash -n` clean;
the shim defining no function of its own; each of the 132 functions defined
exactly once, in its mapped module and in no other; the union of what the
modules define being exactly the map; every mapped function and every CLI verb
handler present after really sourcing the shim; and the refusal, driven on a
real copy with one module deleted (nonzero rc, stderr naming the missing path
and the fixture rule, and the caller's next command never running).

The byte-for-byte claim is not taken on trust either: every slice in every
module is a verbatim copy of the pre-split file's lines, and the 153 suites that
source or copy the client were run before and after the split with the same
results.

On a live box the only visible artifact is the refusal:
`grep 'missing module' /root/harness/logs/ALERTS.log`. An empty result is the
normal state — it means no lane has met a half-synced `bin/`.

**Manual-only / not automatable:** the real half-synced box. Nothing here may
interrupt a live `bin/harness-sync.sh` mid-flight to produce one, so the
condition is only ever driven in the scratch tree above.
