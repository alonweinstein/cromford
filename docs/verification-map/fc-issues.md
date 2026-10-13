# Issues-lane child filer (`bin/lib/fc-issues.sh`)

**What it is:** the GitHub-Issues lane module of the child-filer contract. It
files one issue per child on the parent's repo, writes the split comment on the
parent thread and takes the `ai-build` label off the master. It is slice `.1` of
#816: the loop it holds used to live inline in `bin/run-decompose.sh`, and it
moved so that BOTH child-filing lanes — the decomposer that exists and the
rollout lane being built — write the same lines.

**How it is reached** — no cron line and no executable of its own:

```
cron/*.cron → bin/run-build.sh (size gate) → bin/run-decompose.sh
                                               ↓ sources bin/lib/file-children.sh
                                               file_children <project> <parent> <KEY> <build> <children.json> [--kind …]
                                                 ↓ resolves the lane with tracker_adapter (settings row
                                                   tracker_adapter.<project>, else fleet.conf column 4: "-" = issues)
                                                 ↓ sources fc-issues.sh beside it, else $HARNESS/bin/lib
                                               fc_file_issues        (no arguments; its inputs are the FC_* variables)
```

The parent-side calls (the label read, the split comment, the `ai-build`
removal) go through the GitHub adapter of the tracker contract,
`bin/lib/tracker/github-issues.sh` (BH-4075, [tracker-adapter.md](tracker-adapter.md)).
`decompose-gh.log` is still written by this module, line for line as before.

`bin/run-decompose.sh` keeps the decomposer half: the Fable call, the fenced-JSON
unwrap, the 2-5 count, the title/body and `contract` checks, the chain cap and
the re-entrancy guard. Everything after that is this module. `--kind rollout` has
no caller yet; `bin/run-rollout.sh` is a later slice of #816.

**How to drive it** (no network, no model, no `gh`, nothing outside the scratch
tree):

| what | how |
|---|---|
| the whole module, both kinds | `HARNESS_TEST_SANDBOX=1 bash tests/fc-issues.bh-982-test.sh` |
| the decompose bodies are byte-identical to the pre-move script | the same suite, section D1 — it drives the REAL `bin/run-decompose.sh` under `DECOMPOSE_DRY_RUN=1` and `cmp`s every `children/child-<n>.md`, `decompose-comment.md` and `decompose-gh.log` against `tests/fixtures/fc-issues/<set>/`, generated once from the script as it stood BEFORE the move |
| the library alone produces the same bytes | the same section — a second drive calls `file_children` from a `bash -c` with no script above it |
| a rollout, three waves | section R1/R2 — `file_children … --kind rollout` under `FILE_CHILDREN_DRY_RUN=1` |
| the real launcher reads a real wave body | section R3 — wave 3's produced body goes through `bin/unblocked-children.sh` |
| the decomposer is unchanged | `tests/run-decompose-issues-test.sh`, `tests/decompose-contract-first-test.sh`, `tests/run-decompose-labels.bh-637-test.sh`, `tests/run-decompose-fresh-token-test.sh`, all four UNEDITED |
| a real split, by hand, against a real repo, filing nothing | `DECOMPOSE_DRY_RUN=1 bin/run-decompose.sh <project> <issue> <KEY> <build-dir> 300 12` with a `children.json` already in the build dir — every `gh` command is printed and logged to `$BUILD/decompose-gh.log` instead of run |
| lint | `bash -n bin/lib/fc-issues.sh`, `shellcheck -S error bin/lib/fc-issues.sh` |

**What must never regress:**

- **The decompose child bodies are byte-identical to what the inline loop
  wrote.** Four scripts parse those exact lines: `bin/unblocked-children.sh`
  (`Blocked-by: #<n>`), `bin/lib/dep-verify-lib.sh` (the `(hard)` suffix),
  `bin/decompose-parent-close.sh` (`Part of #N` / `Order: n of N`) and
  `bin/size-gate.sh` (the size budget line). One byte of drift is a child that
  launches into a conflict, or never launches, days later and quietly. The
  checked-in fixtures are the proof and D1 fails on a single changed character.
- **The `, ` separator and the `(hard)` suffix on a multi-blocker line.**
  `bin/unblocked-children.sh` reads every `#<n>` on the `Blocked-by` line and
  holds the child until all of them are closed; a separator that merges two
  numbers releases a child early.
- **`10` is not position `1`.** The `after` matcher anchors on a non-digit, and a
  position that does not exist is dropped with a log line rather than guessed. A
  wrong blocker stands a wave behind an issue that will never close.
- **The `ai-build` floor.** Every child is filed with `--label ai-build` whether
  or not the parent still carries it — the label IS the handoff, and an
  unlabelled child is invisible to every watcher. Inherited labels come from a
  whitelist (`hotfix` plus `DECOMPOSE_INHERIT_LABELS`), never a copy: `not-hotfix`
  and `bug` are deliberately outside it.
- **A failed create returns, it does not exit.** This file is sourced, so an
  `exit` would kill the lane that sourced it. A create that answers no issue
  number sets `FC_ERROR`, returns 1, and leaves `children.txt` holding exactly
  the children that exist — the parent is not commented on and keeps its label,
  so a resumed build cannot double-file. The failure line now also names the
  children that are still missing so the sweep SOP and the next resume know what
  remains.
- **Sourcing is inert**: no `set -e`, no `exit`, no output, nothing written at
  source time, safe under the caller's `set -u`.
- **The dry-run re-entrancy guard still runs before any create**. In
  `DECOMPOSE_DRY_RUN=1` a non-empty `children.txt` still means "do nothing";
  synthetic issue titles cannot be verified, so recreating would change the
  fixtures. In a real run the guard is removed and the module instead resumes:
  it loads the existing `children.txt`, verifies each ordinal's title with
  `gh_rest GET repos/<slug>/issues/<n>` (BH-1650), files only the missing children, and appends their numbers
  to the file.
- **`children.txt` is append-only on the resume path.** It is the only evidence
  that a child exists on the client's repo, so no run rewrites it: a recorded
  child is re-proven and its line left byte-for-byte as the run that filed it
  wrote it, and only an ordinal this run created is appended. Every way of
  failing to prove a recorded child — the title read erroring, the title not
  matching, or the record holding more children than the spec — returns 1 with
  the file untouched, so the rerun after it is safe. A title read that
  ERRORS (non-2xx, or a 2xx with no parseable `.title`, rc 75) reads as "cannot
  read issue #N ... (issue read failed: HTTP <status>, rc=<n>)", never as a
  title mismatch: the first means retry, the second means go look at the issue.
- **Parent label reads, the split comment and the label removal are REST
  (BH-1650).** The parent's labels come from `gh_rest GET` (a failed read
  inherits and removes nothing), the comment posts through `gh_rest_comment`
  (failure is the same WARN), and parking is `gh_rest DELETE
  .../labels/ai-build`, where a 404 means "was not labelled" and is success.
  `decompose-gh.log` records these as `gh api -X POST|DELETE ...` lines.
  Suite: `tests/fc-issues-rest.bh-1641-test.sh`.
- **The record reader reads every line, or the run stops.** A final line with no
  trailing newline is read like any other (`|| [ -n "$_ei" ]`) — without it a
  one-line hand-edited record read as EMPTY and the rerun re-filed every child
  on the client's repo and exited 0. Any line that is not `^[A-Za-z]+-[0-9]+$`,
  blank included, fails the run closed BEFORE any GitHub call, naming the line
  number and its text and leaving the file byte-identical: a line we cannot read
  is not "no child at this ordinal". When a run does file a child and the record
  ends unterminated, the terminator is written first, so an appended key is
  never glued onto a hand-edited line. And a complete rerun re-reads the
  parent's labels once and takes `ai-build` off if the first run's remove
  failed — the split comment is never re-posted, because a duplicate on a
  client thread cannot be undone. Suite:
  `tests/fc-issues.bh-1482-test.sh`.

**Preconditions / seed needs:** none. The suite builds its own scratch
`fleet.conf`, env files, `gh`, `curl` and `agent-call.sh` stubs. A REAL run needs
`jq`, `gh`, and a token that can see the repo (`bin/gh-token.sh`, then
`gh_repo_use_token`, then the inherited `GH_TOKEN`).

**Manual-only / not automatable:** nothing. cromford has no user-facing app.
The operator-facing surface is the parent issue's split comment and the child
issues themselves, and the dry run prints both without touching a repo.
