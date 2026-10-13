# Deterministic rollout parser (`bin/run-rollout.sh`)

**What it is:** a lane script that reads a ticket body, finds a top-level
`## Rollout` section, parses `### Wave: <title>` / `### Wave <n>: <title>` headings into a
`children.json` spec, and files the waves through the shared
`bin/lib/file-children.sh` contract with `--kind rollout`. It is slice `.1` of
#816 — the deterministic parser that lets wave-style tickets decompose without a
model call.

**Nothing calls it yet, on purpose.** The `bin/run-build.sh` hook that will
dispatch to it is a later slice. `run-rollout.sh` exits cleanly when a ticket
has no `## Rollout` section and refuses malformed rollouts loudly.

**How an operator reaches it** — no cron line yet. Run it by hand against a
scratch build dir:

```sh
DECOMPOSE_DRY_RUN=1 bin/run-rollout.sh scoutish 552 TK-552 /tmp/build-552
```

For the in-app board lane:

```sh
DECOMPOSE_DRY_RUN=1 bin/run-rollout.sh widget-os 2 WO-2 /tmp/build-2
```

The dry-run flag prints the filing commands and writes
`/tmp/build-<KEY>/children.json`, `rollout-run.txt`, and
`rollout-comment.md`.

**How to drive it:**

| what | how |
|---|---|
| the whole lane, on a scratch tree | `HARNESS_TEST_SANDBOX=1 bash tests/run-rollout.bh-984-test.sh` |
| the resume, the two parser holes and the `after:` edges | `HARNESS_TEST_SANDBOX=1 bash tests/run-rollout.bh-1335-test.sh` (filters: `lints`, `hidden-pre`, `midline-h3`, `after-edges`, `resume`, `never-green`, `regression`, `pins`) |
| the cheap detector alone | `bin/run-rollout.sh --is-rollout <body-file>`; exit 0/1, no output |
| the shared contract it sources | `HARNESS_TEST_SANDBOX=1 bash tests/file-children.bh-981-test.sh` |
| the sibling decomposer is unchanged | `HARNESS_TEST_SANDBOX=1 bash tests/run-decompose-issues-test.sh` |
| generated-file freshness | `bin/verification-map-build.sh --check` |
| lint | `bash -n bin/run-rollout.sh`, `shellcheck -S error bin/run-rollout.sh` |

**What must never regress:**

- **Fences and code spans are stripped before the section is detected.** A body
  that documents the convention inside a fence, or writes `<h2>Rollout</h2>` in
  code, must not arm the lane.
- **Waves are 2-12 only.** Fewer than two waves, more than twelve waves, or no
  waves under the heading are refused with `ROLLOUT_FAILED` and no filing.
- **Duplicate titles, self dependencies, forward dependencies, and unknown
  dependencies are refused.** `after:` only counts on the first non-blank line of
  a wave body; any deeper `after:` line stays in the child's body as prose.
- **Wave titles resolve case-insensitively and trimmed.** `### Wave 3: wire hook`
  and `### wire hook` are equivalent, and an `after: Scaffold Parser` reference
  matches `scaffold parser`.
- **A wave titled `Rollout` is an ordinary wave**, not the section heading.
- **A partially filed record resumes; it never answers green.** The top-of-script
  watermark compares the RECORD (`children.txt`, append-only, one key per wave
  GitHub actually returned) against the SPEC (`children.json`): K ≥ N logs
  `ROLLOUT_ALREADY_FILED <KEY> (K of N waves on the record)` and prints a truthful
  `RESULT "ROLLOUT_FILED N"`; 0 < K < N logs `ROLLOUT_RESUME <KEY> (K of N waves
  already filed)` and falls through so `fc_file_issues` files only the missing
  waves; and a record with no readable `children.json` REFUSES — absent is not
  zero. Before BH-1335 a non-empty `children.txt` exited 0 with no RESULT line at
  all, so a run that died on wave 2 reported success forever and waves 2 and 3
  were never filed.
- **The final RESULT is derived from the record, never from the filer's rc.**
  Fewer than N keys after the filer returns is `RESULT "ROLLOUT_FAILED filed K of
  N waves"`, rc 1 — including when the filer returned 0 (the dry-run arm of
  `fc_file_issues` returns 0 without filing when `children.txt` is non-empty).
  `ROLLOUT_FILED N` is printed only when N keys are on the record.
- **A heading tag that is not the whole trimmed line refuses inside the section.**
  `body <h3>Wave 2: b</h3> trailing` is a wave to the detector and body text to
  the parser, so it used to file fewer waves than the author wrote with a green
  result; it is now `ROLLOUT_FAILED mid-line heading tag`. Whole-line `<h2>`/`<h3>`
  elements (the in-app board's normal shape) are unaffected, and so is an inline
  tag in the master's PREAMBLE.
- **The three `after:` edges answer by their real names.** An indented (4+ space)
  `after:` line is `ROLLOUT_FAILED indented after: line`, not the misleading
  "unknown dependency"; a 1-3 space indent parses the way markdown renders it;
  `after:` with nothing after it is `ROLLOUT_FAILED empty after: list` instead of
  being consumed in silence; and `after: a, a` renders `[1]`, not `[1,1]`.
- **`### Wave: <title>` and `### Wave <n>: <title>` are both the prefix (BH-4061).**
  Case-insensitive, with a space before the colon tolerated (`### wave 3 : a`
  is `a`). A letter after `wave` is part of the title (`### Wavefront rework`,
  `### Waves: x`). Before BH-4061 only the numbered form was stripped, so
  `### Wave: a` was titled `Wave: a` and every `after: a` refused.
- **An unknown dependency names itself and the known titles.** The reason is
  `unknown dependency "<name as written>" (known: "a", "b")`, rc 17.
- **A comma in a wave title refuses when any wave has an `after:` line**, as
  `ROLLOUT_FAILED comma in wave title` (rc 26), because `after:` splits on
  commas and such a title can never be named. With no `after:` anywhere a comma
  title files.
- **A parse refusal is said on the master and parks it (issues lane only).**
  `bin/lib/rollout-refusal.sh` posts one comment per (issue, reason), whose first
  line is `<!-- rollout-refusal:<16 hex> -->`, then removes `ai-build`. The next
  tick with the same reason finds the marker and posts nothing. An unreadable
  comment list logs `ROLLOUT_REFUSAL_UNKNOWN` to `pipeline.log` and posts and
  parks nothing. Fetch, filer and partial failures never comment. Dry run writes
  `rollout-refusal-comment.md` and the two `gh api` lines to `decompose-gh.log`.
  Suites: `tests/run-rollout-unnumbered-wave.bh-4061-test.sh`,
  `tests/rollout-refusal-comment.bh-4061-test.sh`.
- **`bin/run-build.sh` and `bin/run-decompose.sh` are not modified** by this
  slice.

**Preconditions / seed needs:** none for the lane itself. A real run needs the
project's `fleet.conf` row and, for the board lane, the env file with
`*_INTERNAL_API_TOKEN` and `*_API_BASE`.

**Manual-only / not automatable:** nothing. cromford has no user-facing app.
