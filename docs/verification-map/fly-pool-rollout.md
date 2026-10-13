# Wave-3 pool rollout probe

**What it is:** `bin/fly-pool-rollout.sh <project>` is the one-shot lane that
puts a project on the Fly build pool. It mints an org token if one is missing,
ensures the `builder-<p>` and `pool-<p>` apps, rebuilds the builder image, pushes
the env bundle and a SMOKE job to a REAL pool machine, and flips the routing
flags only after that machine answers `SMOKE_OK`. A project that fails any step
is logged and skipped; its current build lane is left exactly as it was.

**How an operator reaches it:** on the hub only, by hand:
`bin/fly-pool-rollout.sh <project>`. It needs the hub's flyctl session and the
owning box's ssh key, so it cannot be driven from a pool machine or from CI. No
cron lane calls it.

**How to drive it:**

| what | how |
|---|---|
| the whole script, with flyctl/ssh/sleep shimmed and a scratch `$HARNESS` | `bash tests/fly-pool-rollout-probe-test.sh` |
| which token the mint runs on, and what the later flyctl calls see | `bash tests/fly-rollout-mint-env-test.sh` |
| a refused mint: one ALERT with flyctl's own sentence, non-zero pass | `bash tests/fly-rollout-mint-alert-test.sh` |
| the write-time guard on `env/fly.env` | `bash tests/fly-rollout-env-quoting-test.sh` |
| the pool is only enabled on the image the probe ran | `bash tests/fly-rollout-image-pin-test.sh` |
| the OTHER writer of `FLY_API_TOKEN_<P>` into the same file | `bash tests/fly-provision-token-quoting-test.sh` |
| the registry lookup it now preflights on | `bin/fleet-conf.sh --tailnet-ip <project>` — an address and rc 0, or nothing and rc 1 |
| a live pass | `bin/fly-pool-rollout.sh <project>` on the hub, then read `logs/fly-pool-rollout.log` |
| the resulting routing, on the owning box | `bin/free-slots.sh <project>` prints `unlimited (fly-routed: …)` |

All five suites drive the REAL script through the seams it ships for that
purpose — `HARNESS`, `FLYCTL_DIR`, `ROLLOUT_BOOT_WAIT`, `ROLLOUT_POLL_WAIT` —
and assert only on artifacts. `tests/lib/fly-rollout-fixture.sh` is the shared
scratch harness; it is a fixture builder, not a suite.

**The second writer.** `bin/fly-provision.sh` appends the same
`FLY_API_TOKEN_<PROJECT>` variable to the same `env/fly.env`, for the same
readers, when it provisions a new per-project builder. It is not part of this
lane and has no write-time verification of its own, but a token it writes
unquoted breaks this lane on the next `source` — which is why its quoting has a
suite here rather than in a file nobody reads together with this one.

**Files it writes:**

- `logs/fly-pool-rollout.log` — one line per event. The shapes that matter:
  - `[<p>] no tailnet_ip for <p> in fleet.conf …` — the preflight refused before
    the image build. Fix the row, do not re-run into it.
  - `[<p>] a rollout pass for <p> is already running …` — dedupe skip.
  - `[<p>] smoke FAILED (push_ok=<0|1> step=<envbundle|push:…|none> reason='…' result='…')`
  - `[<p>] image pointer restored to <ref> — SMOKE did not pass on <ref> …` —
    the probe failed and the dispatch pointer was put back where it was.
  - `[<p>] SMOKE_OK on pool machine <id>` then
    `[<p>] WAVE3 ENABLED (pool cap …) image <ref>`
  - `rollout pass complete (<n> project(s) skipped)` — the closing line. `n > 0`
    is also the script's exit status: any requested project the pass did not
    enable makes it non-zero.
- `logs/ALERTS.log` — the four classes this lane raises, all shaped
  `[rollout/<p>] …`:

  | ALERT | what happened | what to do |
  |---|---|---|
  | `org token mint FAILED — flyctl: <stderr>` | `flyctl tokens create org` refused. Usually the hub's flyctl session has expired, so the mint fell back to no auth at all. | Read flyctl's sentence. `fly auth login` on the hub, then re-run. Nothing was spent; no image was built. |
  | `env/fly.env REJECTED the appended FLY_API_TOKEN_<P> line …` | The token was minted but does not survive a round trip through `source` (an embedded quote, a `$`, a newline). The file was restored byte-for-byte and the token was NOT saved. | An orphan token named `wave3-<p>` now exists at Fly — revoke it. Re-run; the next mint gets a new value. |
  | `could not back up env/fly.env before appending … — nothing written` | `mktemp`/`cp` in `/dev/shm` failed, so the rollback had nothing to roll back to and the append was refused rather than risk truncating the file. | Check `/dev/shm` (mounted? full?). Same orphan-token note as above. |
  | `image pointer moved during smoke (probed <ref>, pointer now <ref>) — REFUSING …` | `state/fly/<p>.image` changed while the probe was running — almost always the nightly `bin/fly-image-refresh.sh`. The pool was NOT enabled, and the pointer was left to whoever moved it. | Re-run the rollout; it probes the current image. Nothing is broken. |

  `bin/fly-onboard.sh` writes its OWN alert on a failed onboarding, so a failure
  through the wrapper leaves two lines that carry different facts: flyctl's
  sentence here, the wrapper's remediation there. That is deliberate.
- `flags/fly-pool-app-<p>` (the dedicated pool app name), `flags/fly-pool-<p>`
  (the enable switch; EMPTY means autoscale), `flags/builder-fly-<p>` on the hub
  and on the owning box.
- `state/fly/<p>.image`, `state/fly/<p>.json` — the image ref the pool reuses.
- `locks/fly-pool-rollout-<p>.lock` — the per-project dedupe lock (fd 7).
  `bin/fly-lock-guard.sh` already reaps a leaked holder by this name pattern.

**What must never regress:**

- The probe comes FIRST and the flags follow. No flag may be written for a
  project whose machine did not answer `SMOKE_OK`, and no operator flips them by
  hand to skip the probe.
- The preflight runs before the token mint and before the image build. A project
  the registry cannot place costs nothing.
- The dedupe is `flock -n` and a SKIP. It never waits for the other pass.
- The failure line names the step and the reason. `push_ok=0` on its own covers
  four different failures and reads like a machine that never reported back
  (BH-668: six image builds burned on a missing `tailnet_ip`).
- The mint runs on the hub's flyctl SESSION auth, with BOTH `FLY_ACCESS_TOKEN`
  and `FLY_API_TOKEN` unset. flyctl prefers the first and falls back to the
  second, so dropping only one leaves the limited bootstrap token doing a job it
  is not authorized for (BH-666). Every other flyctl call in the script runs
  after `export FLY_ACCESS_TOKEN="${!TV}"`, on the project token, on purpose.
- The pool is enabled only on an image the probe passed on. A pointer that moved
  under the probe is a refusal, not a warning.
- `env/fly.env` is never left unsourceable and never left truncated. The append
  is verified where it is written, not by the next reader.
- A refused mint is never silent and never exit 0.

**The env guard's scope.** The verification is
`env -i bash -c 'set -a; . <file>'` — a clean process, no PATH, no inherited
environment. That is exactly right for a file of plain assignments, which is
what `env/fly.env` is. If anyone ever adds a command substitution to it, every
mint will start failing this guard, and the fix is to take the command
substitution back out rather than to loosen the check.

**Known residual (its own ticket, not this one).** `state/fly/<p>.image` is still
published in step 3, BEFORE the probe in step 4. For a project that is already
enabled, a re-run therefore has a window (the boot wait plus up to ten polls)
where `bin/fly-pool-tick.sh` can dispatch a build onto the unprobed ref. The
step-5 check refuses to ENABLE on unproven bits and the failure paths put the
pointer back, but neither closes that window for an already-enabled project.
Closing it means holding the pointer until `SMOKE_OK`, which changes what step 3
means and what `bin/fly-provision.sh` boots from.

**Manual only:** the live hub pass. The fixture suites prove the decisions and
the artifacts; they cannot prove that a real machine came back green.
