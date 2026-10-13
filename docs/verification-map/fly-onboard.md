# Fly pool onboarding for one project

**What it is:** `bin/fly-onboard.sh <project> [--cap N]` — a hub-only,
re-runnable wrapper over `bin/fly-pool-rollout.sh` for exactly one project, plus
the `# >>> fly-onboard-drain` block in `bin/fly-pool-tick.sh` that runs it for
every project queued in `fly/onboard-queue.conf`. Shipped for BH-662, after
cromford was routed by hand with the raw rollout and harness-console was
left local through six passes with nothing anywhere saying why.

It writes **no routing flag of its own**. `flags/fly-pool-<p>`,
`flags/builder-fly-<p>` and `flags/fly-pool-app-<p>` are written only by
`bin/fly-pool-rollout.sh`, only after `SMOKE_OK` on a real pool machine, so
"stamped routed without a green probe" is impossible by construction rather than
by care.

**How an operator reaches it:**

| Channel | How |
|---|---|
| hub shell | `/root/harness/bin/fly-onboard.sh <project>` — the whole operation |
| the repo (no ssh anywhere) | `bin/load-project.sh <owner/repo> --fly`, or a line in `fly/onboard-queue.conf` merged by hand. `bin/fleet-propagate.sh` (\*/5) syncs it, `bin/fly-pool-tick.sh` (\*/10) drains it |
| console `chat` → project `orchestrator` | a session on the hub, from which the hub-shell line applies. Claims are not box-scoped (`bin/poll-commands.sh:194-201`), so this is a request, not a guarantee |

Anywhere else it refuses: rc **3**, naming the box and the two channels above,
**before any flyctl call**. See docs/OPERATOR-SETUP.md, "Reaching the hub
without ssh".

**Exit codes:** 0 `OK`/`ALREADY`, 1 `FAILED`, 2 usage or not-a-fleet-project,
3 refused (not the hub, or `bin/lib/hub-box.sh` unreadable — this guard fails
CLOSED, unlike the build guards, because a wrong "yes" here mints org tokens).

**How to drive it:**

| what | how |
|---|---|
| the hub guard, the verdict, `--cap`, the fail-closed path | `bash tests/fly-onboard-guard-test.sh` |
| already-routed, half-routed, lookalike flags, re-run | `bash tests/fly-onboard-idempotent-test.sh` |
| one project per run, nothing of a sibling's touched | `bash tests/fly-onboard-isolation-test.sh` |
| SMOKE failure, no machine id, the ALERTS line, retry | `bash tests/fly-onboard-failure-test.sh` |
| `--fly` queues + stages; without it the loader is unchanged | `bash tests/load-project-fly-flag-test.sh` |
| the hub drain: launch, ledger, attempt cap, retry window | `bash tests/fly-onboard-drain-test.sh` |
| per-project retry policy from `retry_policies` | `bash tests/fly-onboard-policy.bh-1058-test.sh` |
| the neighbour that drives the same tick | `bash tests/pool-autoscale-test.sh` |

All seven run the REAL scripts against a scratch `$HARNESS` with a fake `flyctl`
that records its argv (`tests/lib/fly-onboard-fixture.sh`), so "made zero flyctl
calls" is an assertion about a file. The rollout's three test seams —
`HARNESS`, `FLYCTL_DIR`, `ROLLOUT_BOOT_WAIT`/`ROLLOUT_POLL_WAIT` — exist for
that and are set nowhere in production.

**Files it owns on a live box:**

- `logs/fly-pool-rollout.log` — `[fly-onboard/<p>] …` lines (start, refusals,
  the warning) and the one `FLY_ONBOARD <p> OK|ALREADY|FAILED: …` verdict per
  run, naming both flag paths and `bin/free-slots.sh <p>`'s answer.
- `logs/fly-onboard.log` — stdout of every run the drain launched.
- `logs/ALERTS.log` — one `[fly-onboard] <p> onboarding FAILED at "<step>" …`
  per failed run; one `[fly-onboard] <p>: N onboarding attempts failed …` when
  the drain gives up.
- `logs/fly-pool.log` — one `[pool/<p>] fly-onboard queued line -> launching …
  (attempt N of M)` per drain launch.
- `locks/fly-onboard-<p>.lock` — `flock -n` dedupe, one owner per project,
  never a wait.
- `state/fly-onboard/<p>.attempts`, `.last` — the drain's ledger, written
  BEFORE the launch.
- `flags/alerted-fly-onboard-gaveup-<p>` — the give-up dedupe marker. Remove it
  with `.attempts` to re-arm retries.

**Knobs:** `FLY_ONBOARD_MAX_ATTEMPTS` (3), `FLY_ONBOARD_RETRY_MIN` (360
minutes), both in `env/global.env`. `--cap N` writes through the rollout's
existing `POOL_CAP` path; the cap ladder itself (`flags/fly-pool-<p>` number →
`fly/pool-caps.conf` → `POOL_CAP_MAX` → unlimited) is untouched.

**Per-project retry policy (BH-1058).** When the Fly machine registry contract
is on (`machines_rows_on` returns 0 from `bin/jobs-client.sh`), the drain looks
up `retry_policies` for the lane `fly-onboard/<project>/hub`. A returned row's
`max_attempts` and `backoff_seconds` override the env knobs for that project
only; the ledger still lives in `state/fly-onboard/<p>.attempts`/`.last`. A
missing row, a worker outage, a non-digit (negative, decimal, text) or zero
value, or a contract that is off all fall back to the env knobs — never "retry
forever" and never "never retry". The contract is read at most once per tick and
only when some project reaches the lookup, because a project that is already
routed or has already given up is skipped before it. **A raised `max_attempts`
does not re-arm a project that already gave up**: the give-up flag short-circuits
ahead of the lookup, so `rm flags/alerted-fly-onboard-gaveup-<p>` (with
`state/fly-onboard/<p>.attempts`) first, then the new row applies. There is no
per-tick policy line: when a row applied, the launch line and the give-up line carry
`(policy fly-onboard/<p>/hub max_attempts=M backoff=Ss)`. Set a row with
`bin/jobs-client.sh retry-policy-set fly-onboard/<project>/hub <max-attempts> <backoff-seconds>`.

**What must never regress:**

- **Off the hub = zero flyctl.** The guard runs before `command -v flyctl`,
  before `env/fly.env`, before anything. A refusal after a `tokens create org`
  is not a refusal.
- **`ALREADY` = zero flyctl, not zero `machine run`.** The rollout is idempotent
  for apps and images but always launches a real `performance-4x` probe, so a
  re-run on a routed project would buy one every time the never-pruned queue
  line is read — 720 reads a day.
- **`ALREADY` needs BOTH flags, matched exactly.** `fly-pool-app-<p>` alone is
  not routing; one of the two is not routing; `alpha-2`'s flags are not
  `alpha`'s.
- **`FAILED` writes no flag and exits non-zero.** `bin/fly-pool-rollout.sh` has
  `set -uo pipefail` without `-e` and every failure is `say …; continue`, so it
  exits 0 on a failed token mint, image build and smoke alike — the verdict is
  read from the flag files on disk, never from its rc.
- **One project per run.** The rollout loops over `"$@"` and defaults to three
  projects when given none; passing one positional is the isolation mechanism.
- **The drain writes the ledger BEFORE it launches**, and never waits: a crash
  after spawning cannot re-spend every two minutes, and a second launch is a
  no-op through `fly-onboard.sh`'s own `flock -n`.
