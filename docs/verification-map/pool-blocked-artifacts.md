# Blocking artifacts survive the machine (a blocked pool build's plan.md)

**What it is:** a build that stops to ask something writes the question into a
FILE — `plan.md`, `review.md`, `decompose-run.txt` — and records a one-line
pointer to it as its `result` artifact. On a Fly pool machine that path dies with
the machine at reap, so the owning box used to stage
`PLAN_BLOCKED /root/harness/builds/<x>/plan.md` naming a file on a host that no
longer existed, and the sweep had nothing to quote to the client. Since BH-531
the builder pushes the file's BODY to the ledger before the result row, and the
box fetches it back into the staged dir and points `RESULT` at the local copy.

**How an operator reaches it:** there is no screen. The lane is two halves that
run on their own:

- **builder half** — the `# >>> blocking artifact body` block inside
  `_job_finish` in `bin/run-build.sh`. `_job_finish` is the EXIT trap of every
  build (armed at the `job_open` claim), so every terminal outcome crosses it,
  local and pool alike. On the three blocking terminals it calls
  `bin/transcript-push.sh` with `TRANSCRIPT_SOURCE=plan_md|review_md|decompose_run`.
- **box half** — the ledger loop in `bin/lib/rt/staging.sh` (`rt_stage`), which
  `bin/run-triage.sh` calls on EVERY triage tick, before the cost gate. When the
  pulled `result` row is one of the three it fetches the body with
  `job_transcript_get_source`, writes it into the staged `-remote…` dir under the
  file name the line points at, rewrites that path token, and keeps the
  builder's sentence as `ORIGINAL_RESULT:`.

**Key routes/files:**
- `POST /api/jobs/:id/transcript` and `GET /api/jobs/:id/transcript?phase_id=&attempt=`
  (harness-jobs worker, `worker/jobs/src/routes/transcripts.js`) — both already existed; BH-531
  added no worker code. The body rides the existing `job_transcripts` table on a
  RESERVED slot: no phase, attempt 100, which `bin/agent-call.sh` can never reach
  (it numbers real attempts 1..N against a real phase row). A re-push upserts.
- `bin/jobs-client.sh transcript-get <job-id> [phase-id] [attempt]` and
  `transcript-get <job-id> source=<plan_md|review_md|decompose_run>` — the read
  verb. stdout is the body and nothing else; a miss, an outage and an empty
  stored body are all rc 1 with no output.
- `bin/transcript-push.sh` — the same cap (`TRANSCRIPT_MAX_BYTES`, tail-first)
  and the same fail-closed scrub a session transcript gets. An artifact body
  carries NO provenance header, because the box writes it back to disk as the
  file and a session quotes that file to a client.
- `console-ui/src/lib/transcripts.js` — `sourceLabel` / `sourceNote` name the
  three sources for what they are, so the job drill-down does not render
  "provenance not recorded" over a row whose provenance is exactly known.

**Preconditions / seed needs:** no schema change, no migration, no new env var.
`TRANSCRIPT_MAX_BYTES` and `TRANSCRIPT_ARTIFACT_ATTEMPT` are both optional
overrides with the defaults stated in `bin/transcript-push.sh`. The build needs a
claim: with `JOB_ID` empty (worker unreachable at claim time) the builder half is
a no-op and the build behaves byte-identically.

**Verify it works:**
- `HARNESS_TEST_SANDBOX=1 bash tests/run-build-blocked-artifact.bh-531-test.sh` —
  the builder block lifted VERBATIM by its markers and driven: the three
  terminals hand over the right file/source/stage, the hand-over sits before the
  result row, and the neighbours that share a prefix or a word
  (`PLAN_MALFORMED`, `PLAN_STALE`, `DECOMPOSED`, `RESULT_UNVERIFIED PLAN_BLOCKED`,
  `PR_CREATED … (see plan.md)`) hand over nothing.
- `HARNESS_TEST_SANDBOX=1 bash tests/transcript-push-artifact.bh-531-test.sh` —
  the reserved slot, an explicit `$5` ignored, no header, the tail cap, the
  fail-closed scrub, an unallowlisted source refused, and a regression pin that
  a push with the override unset is unchanged.
- `HARNESS_TEST_SANDBOX=1 bash tests/jobs-client-transcript-get.bh-531-test.sh` —
  hit, miss, outage, `source=`, and a non-numeric address making NO request.
- `HARNESS_TEST_SANDBOX=1 bash tests/ledger-blocked-artifact.bh-531-test.sh` —
  the real `bin/run-triage.sh` over a stubbed ledger: the staged dir holds the
  file its RESULT names, `preplan.md` and `plan.mdx` tokens are NOT rewritten, a
  `PR_CREATED` row never fetches a body, a builder with no body on file is logged
  and never paged, and the relay json arriving a tick later is still consumed
  rather than staged twice.
- `cd console-ui && npm test` — `tests/transcripts.bh-531.test.js`.

**On a live box**, after a pool build ends blocked:
```
bin/jobs-client.sh transcripts <job-id>            # a row with source plan_md
bin/jobs-client.sh transcript-get <job-id> source=plan_md | head
ls  /root/harness/builds/<project>-<KEY>-remote*/plan.md
head -1 /root/harness/builds/<project>-<KEY>-remote*/RESULT   # names that file
```

**Known gaps, stated rather than implied:**
- `SECURITY_BLOCKED` and `REFUTE_BLOCKED` share the bug class and are NOT
  covered — the ticket named three terminals and widening them silently was not
  this build's call. Their artifacts (`security-review.md`, `refute-review.md`)
  still live only on the machine.
- Gate-produced `REVIEW_BLOCKED` lines (`test-tamper:`, `reproduction-gate:`,
  `intent-gate:`) point at their own files. `review.md` is pushed when it exists;
  those gate files are not, and their paths are left untouched on the line.
- `bin/fly-results-ingest.sh` is the hub-local relay path and already ships these
  files by ssh; it is untouched, and a dir it filled is not re-staged.
- During fleet propagation a builder on an older `bin/` pushes no body. The box
  stages the close-out with the builder's own path and writes one line to the
  project log — deliberately not an ALERT, or every blocked result on every box
  would page for as long as the rollout takes.
