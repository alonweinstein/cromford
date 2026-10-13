# Fast-path launcher (a wake that builds without buying a triage session)

**What it is:** `bin/launch-fastpath.sh <project> <key> [<key>…]` — the
deterministic half of the wake path (docs/EVENTS.md §5.7). It answers "is this
ticket buildable right now" from nineteen conditions with **no LLM call
anywhere**, launches `bin/run-build.sh` itself for the keys that pass, and
DECLINES everything else so the caller falls through to the triage tick that
would have run anyway.

**How an operator reaches it:** it is a CLI, run by hand or by a lane.

```sh
/root/harness/bin/launch-fastpath.sh project-5 900            one key
/root/harness/bin/launch-fastpath.sh project-5 TK-900 901     a key and a number
echo $?                                                        0 = every key launched, 1 = something declined
```

Its production caller is the wake receiver in `bin/wake-loop.sh`, which runs it
before every triage tick it would otherwise buy (BH-555, #728) and keeps only
the keys it declined. `flags/fastpath-off` on the hub takes that call back out;
the same flag on a box declines every key here.

**Reading the output:** stdout is the declined keys, one per line, exactly as
they were given. The detail is one line per key in `logs/<project>.log`:

```
2026-09-17 20:31:04Z [project-5] FASTPATH TK-900 (issue #900) — launched
2026-09-17 20:31:05Z [project-5] FASTPATH-DECLINED 901 :: HOLD in comment
```

`launched` is rung STARTED and nothing more: the build's own result is
`bin/run-build.sh`'s to report.

**How to drive it:**

| what | how |
|---|---|
| all nineteen conditions, the launch, both kill switches, the caps, and the four REST reads (T1.33: 404 vs unverifiable, a truncated thread, a capped blocker fetch, a missing lib) | `bash tests/launch-fastpath-test.sh` |
| the suite reads no clock and no network | `bin/test-determinism-lint.sh tests/launch-fastpath-test.sh` |
| the marker on this file keeps `gh pr` / `gh issue` / `gh run` out of it | `bash tests/gh-no-graphql-decision-guard-test.sh` |
| the blocker/HOLD/PR regexes have not drifted from the reconciler's | `diff <(sed -n '/^line_re/,/^close_re/p' bin/orphan-reconcile.sh) <(sed -n '/^line_re/,/^close_re/p' bin/launch-fastpath.sh)` — must be empty, and `tests/launch-fastpath-test.sh` T1.32 runs exactly that diff so CI fails on a drift instead of a doc claiming one cannot happen |
| syntax and the footguns CI checks | `bash -n bin/launch-fastpath.sh` and `shellcheck --severity=error bin/launch-fastpath.sh` |

**Files it names on a live box** (this is the "screen" — cromford has no UI):

| path | what it proves |
|---|---|
| `logs/<project>.log` | every `FASTPATH` / `FASTPATH-DECLINED` decision, with its one reason |
| `logs/<project>.<key>-build.out` | the spawned build's own output (the SOP line's redirect) |
| `state/orphan-reconcile/<project>/<KEY>.enqueued` | the grace marker, written BEFORE the spawn and shared with `bin/orphan-reconcile.sh` |
| `locks/launch-fastpath-<project>-<KEY>.lock` | the dedupe lock — seconds long, never held across a build |
| `state/wake-keys-<project>` | shrinks by the keys this run launched; deleted when it empties |
| `logs/wake-loop.log` | the caller's side — `fastpath[<p>]: every key launched … — no triage tick bought` |
| `logs/ALERTS.log` | one `gh-rest: launch-fastpath <what> HTTP <status> … unverifiable` line per read GitHub did not answer (never for a 404) |

**Knobs:** `flags/fastpath-off` (decline everything, before any gh call),
`flags/paused-<project>`, `ORPHAN_GRACE_MIN` in `env/global.env` (default 12 —
the reconciler's own window, shared on purpose). No new env var.

**Verify it works on a live box** (read-only):

```bash
# 1. the marker is on the file
grep -qx '# gh-rest: no-graphql' /root/harness/bin/launch-fastpath.sh && echo marked

# 2. no GraphQL reader survives. The backtick in the class is not decoration:
#    the file's own comments quote the readers it used to call, in backticks.
grep -cE '(^|[^a-zA-Z_`])gh (pr|issue|run) ' /root/harness/bin/launch-fastpath.sh   # 0

# 3. what the lane decided, per key
grep -oE 'FASTPATH(-DECLINED)? .*' /root/harness/logs/<project>.log | tail -5

# 4. what a declined READ looks like when it happens, and the two sentences apart
grep -E 'FASTPATH-DECLINED .* :: .*(absent \(HTTP 404\)|unverifiable \(HTTP)' \
  /root/harness/logs/<project>.log | tail -5
grep -E 'fastpath: the (ai-build state list|blocker read for) ' \
  /root/harness/logs/<project>.log | tail -5

# 5. and the alerts a 75 owes, one per read
grep 'gh-rest: launch-fastpath' /root/harness/logs/ALERTS.log | tail -5
```

A line in (4) is this lane declining to decide, which is the design: the caller
falls through to the triage tick it would have bought anyway. What must never
appear is a `FASTPATH … launched` line for a key whose read is in that list.

**What must never regress:**

- **No model call.** The whole point of this lane is a decision that costs no
  tokens. The suite fails if `agent-call.sh` or `claude` is invoked in any case.
- **Never writes to GitHub, and never reads it over GraphQL.** Every read is a
  REST GET through `bin/lib/gh-rest.sh` / `bin/lib/gh-rest-list.sh` —
  `GET /issues/{n}`, `GET /issues/{n}/comments` (only when the issue's own
  comment count is > 0), `GET /pulls?state=open`,
  `GET /issues?labels=ai-build&state=all` and `GET /issues/{b}` per uncached
  blocker — and the file carries `# gh-rest: no-graphql`, so
  `tests/gh-no-graphql-decision-guard-test.sh` fails on a `gh pr` / `gh issue` /
  `gh run` coming back (BH-1163). No comment, close, merge or label, ever; the
  suite's `gh` recorder asserts zero `(pr|issue|run) (list|view)` calls across a
  whole run.
- **404 and unverifiable are different sentences.** `rc 44` is GitHub saying
  there is no such thing and reads `<what> absent (HTTP 404)`; `rc 75` is GitHub
  not answering and reads `<what> unverifiable (HTTP <status> <reason>)` plus
  ONE `logs/ALERTS.log` line. A 404 owes no alert. This is the #768 lesson: a
  rate-limited read that answered an empty string was acted on as a state.
- **Every failed read declines.** A dead token, a low budget, an unreachable
  ledger, an unreadable PR list or issue, a thread that stopped short of the
  issue's own comment count, a blocker whose state cannot be read: all of them
  decline or read the blocker OPEN. Nothing here maps a failure to a launch.
  The two reads that do NOT decline a key on their own — the ai-build state list
  and the per-number blocker read — fail into "that blocker is open", say so on
  `logs/<project>.log`, and hand the call to `bin/dep-verify.sh`.
- **One reason per key, and it is the first failure.** A reason must be true in
  exactly the state that produced it.
- **The marker is written before the spawn**, or a run killed in between
  launches twice (this one and then the reconciler's).
- **The launch lock is dedupe, never a queue** (`flock -n`, held → declined) and
  the build-key lock is TESTED, never taken.
- **One spawn per key even when two runs decide it at once.** Conditions 16-18
  are read AGAIN inside the launch lock, so the marker is read and written in the
  same critical section. T1.28 runs two copies of the script on one key ten times
  and fails on a second spawn; with the in-lock re-read removed it goes red.
- **A hold is whatever `bin/lib/hold.sh` says it is, and the newest human
  comment wins** (BH-408, BH-6297). Condition 12 is `hold_classify`'s verdict,
  run by bash on the issue and its thread and handed to the classifier as
  `FP_HOLD` — the same reader triage, the conductor and the hold-push guard
  use. So a ticket the operator later said `RESUME` on gets this lane back, a lift
  behind a negation ("Do NOT RESUME this yet") does not, a bot comment never
  holds, and a comment holds only when its first non-blank line starts with
  `HOLD`. An unreadable verdict declines `hold unreadable`. A box mid-sync
  without the lib walks the thread itself with the first-line literal and NO
  lift vocabulary.
- **A hotfix declined for a HOLD writes ONE ALERTS line** (BH-6297) through
  `bin/alert-line.sh --id fastpath-hold-<project>-<KEY>`, quoting the line
  `hold_classify` decided on. Once per (KEY, line): the marker is
  `state/fastpath-hold-alert/<project>/<KEY>.<sha12>`. The decline, stdout and
  exit code do not change. `tests/hold-parse-shared.bh-6297-test.sh` H4.
- **An open PR that carries the FULL key the issue's title LEADS with owns the
  ticket** (`bin/orphan-reconcile.sh` class (b2)). A decompose child is titled
  `TK-2416.0` and its build's PR head is `ticket/TK-2416.0`: the PR never carries
  the issue number, so without that class this lane relaunches a ticket whose
  build is already open — the 2026-09-19 `#2566`/`#2579` loop, through the door
  with no session in it.
- **The regexes stay byte-identical to `bin/orphan-reconcile.sh`'s.** They are
  copied on purpose; the day they disagree is the day one script launches a
  ticket the other holds.
