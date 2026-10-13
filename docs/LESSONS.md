# Operational lessons (fleet-wide doctrine)

## 2026-08-29 — A minted ticket is not a session (QA drives were QA'ing the sign-in page)

Privileged QA accounts are BANNED in Clerk at rest by our own design (project-3
`qa-administrator` since 2026-08-16, project-1 `qa-owner`/`qa-admin` the same). Clerk
answers `POST /v1/sign_in_tokens` for a banned user with **200 and a real ticket**;
the refusal happens later, in the browser, when the session is refused and the app
redirects to `/sign-in`. So a drive minted a ticket, "signed in", bounced,
screenshotted the sign-in page, and reported coverage. The smoke check that was
supposed to catch it printed `FAIL:` and then **exited 0**, so every caller reading
`$?` saw a working sign-in.

1. A CREDENTIAL THAT ISSUES IS NOT A CREDENTIAL THAT WORKS. The mint's status code
   proves the API accepted the request, nothing about the session. Verify the END
   STATE the consumer depends on — the landed URL — not the handshake on the way.
   Same shape as "verifiers must use the real door" (2026-07-28) one layer in.
2. A DIAGNOSTIC MUST PUT ITS VERDICT IN ITS EXIT CODE. `FAIL:` on stdout with
   `exit 0` is not a failing check, it is a comment. `bin/qa-signin-check.mjs` and
   `bin/qa-drive.mjs` now exit non-zero, and a landing on `/sign-in` is a hard FAIL
   everywhere — never a skip, never a pass with a caveat.
3. A PRIVILEGE LIFTED BY AUTOMATION IS RESTORED BY THE SAME PROCESS, IN A TRAP.
   `bin/qa-unbanned.sh` unbans, runs the drive, and re-bans from an EXIT trap — on
   success, on failure, on a kill. It restores the state it OBSERVED rather than
   banning unconditionally, and a restore it cannot complete becomes an ALERTS line,
   a Telegram beat and the script's exit code. A drive that passed while leaving a
   privileged account live in production is not a pass.
4. THE REST STATE IS THE DESIGN. The fix is not "stop banning QA accounts". It is
   "make the drive aware of the ban", which is why nothing here touches the accounts
   outside the wrapper's window.

## 2026-07-28 — Fail-closed 404 ≠ missing code (TK-44 incident)
An anonymous probe of project-2's /api/internal/version returned 404, which was read as
"ticket closed but code never shipped." The route existed (PR #212) — token-gated with a
deliberate fail-closed 404. A replacement public route was shipped over it, breaking the
paired verify script and failing every project-2 production build for ~70 minutes (serving was
unaffected). Doctrine now in every watcher prompt:
1. A prod 404 never proves absence — check `git log --all -- <path>` and the auth design first.
2. Creating a file where one already exists is a redesign — update the paired artifacts
   (verify scripts, tests, callers) in the same commit.
3. Version endpoints are the antidote: verify serving shas, not HTTP status guesses.

## Week retro — 2026-07-28 → 08-02 (the scaling week)

1. VERIFIERS MUST USE THE REAL DOOR. Three incidents, one shape: a checker probing
   a different path/credential than the system uses (anonymous 404 ≠ missing route;
   tokenless 401 blinded the deploy train into reverting healthy work; reconcile
   watched the GitHub deployments API which hook-deploys never touch). Rule: a
   verification probe must use the same endpoint AND the same auth as the consumer
   it protects, or it is noise with authority.

2. COST GATES CREATE SILENCE; EVERY NEW WORK SOURCE NEEDS A WAKE CONDITION. The
   no-change gate starved the 1h-untriaged check, then starved Fly builder results
   for 7h. Budget caps and API 400s inside best-effort catch blocks starved whole
   boards silently. Rule: each skip-path enumerates its wake reasons explicitly;
   each silent-refusal surface gets an end-to-end canary (auth probe, untriaged
   sweep) that ALERTS, because absence-of-output reads as health.

3. BUILT-IN-REPO IS NOT LIVE-IN-PROD. Route (TK-44), DDL (TK-18), seed content
   (SOP vault empty 3 days), permission rows (sop:read unreachable for every
   role). Delivery = verified in production through real eyes (QA browser
   account), and data/config ships through the same gated lane as code.

4. CREDENTIALS ARE DISCOVERED BY BEHAVIOR, NOT BY ENV LISTING. Porting builds to
   Fly missed every file-based credential (codex auth.json, gh keyring, git
   helper) because the env bundle was designed from env vars. Enumerate what
   BREAKS on a clean machine.

5. AUTOMATION NEEDS FENCES AND OUTCOME CHECKS. Stale log lines fired monitors;
   launch races wrote decoy results; sftp silently refused overwrites; pkill
   matched itself; ssh -n nulled a payload; a && chain deployed a file its own
   syntax check had just rejected. Rule: time/line fences on watchers, explicit
   outcome verification after every push/copy, bracket patterns in pkill, and
   deploy gates that HARD-STOP the pipeline line.

6. MODEL CAPACITY IS THE THROUGHPUT CEILING, NOT HARDWARE. 2-core boxes build
   fine; every stall was account weather (session caps, org spend caps, 429s).
   Parallel lanes multiply burn against one account (~3-4 heavy sessions max).
   Plan capacity per account; buy bundles; watch the auth canary.

7. LEASES BEAT LOCKS, AND COORDINATION BEATS COLLISION-RECOVERY. A week of
   cross-harness conflicts (unknowingly rebasing another team's PRs) ended with
   one small lease service. TTL-leases self-heal crashed holders; plain locks
   orphan. Same pattern serves internal multi-actor (watcher+builder).

8. EXHAUST OWN LANES BEFORE DELEGATING. Internal-token owner APIs + QA browser
   + provider APIs resolved "needs a human" items end-to-end (roles, vault,
   resizes, PAT ferrying). Name the blocker or keep digging.

9. PROVE INNOCENCE ON MAIN. Before blaming a PR for failures, reproduce them on
   clean main (TK-113: 5 byte-identical pre-existing failures). Before trusting
   a backfill, snapshot-diff. Partial verification is stated as partial.

## 2026-08-13 — wave-3 first light + project-3 incident day
- **A gating function that "stands down" by returning success half-runs its caller.** fly_env's pool-flag branch returned 0 without exporting APP/token; the dispatcher then claimed jobs it could never push and misread runner idle-exits as died-mid-build. Stand-down belongs at the decision layer (skip the project), never inside a helper, and the flag-ON path needs a test.
- **A smoke that bypasses the production job path proves boot, not function.** SMOKE ran the claude CLI directly, skipping run-build.sh — four green smokes over a lane where no real build could succeed (run-build.sh didn't exist on volume-less machines). First real job is always still a test; say so until it lands.
- **Routing-flag rollouts enumerate fleet.conf, never a hand-typed box list.** The rollout script's box map was missing project-3; hub and box each thought they owned project-3 builds (split-brain, duplicate builds).
- **Same-tenant locks do not prevent intra-fleet duplication.** Cross-harness locks answer 201 to your own re-acquire. Before launching/enqueueing any build, check the owning box's in-flight builds and build-key locks.
- **Box rebuilds need resource parity.** The rebuilt project-3 box came back with an 8GB disk (fleet standard 16GB+) and hit ENOSPC mid-build within days. Bootstrap checklist: disk/RAM/vCPU match fleet.conf-era sizing before the box takes work.
- **Two Vercel projects building one repo = every PR permanently UNSTABLE.** The phantom project's check fails on main itself; nobody can tell signal from noise. Disconnect duplicates from the repo (project-3's project-12 copy still pending the operator's call).
