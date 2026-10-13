# Bytecode never committed (the builder's staging step)

**What it is:** three mechanisms that together make it impossible for a build to
commit python bytecode into any repo the harness works in — the root cause, the
belt, and a tripwire that turns a fourth reappearance into a red build instead
of a review finding.

**The recurrence it ends (BH-1138):** `bin/__pycache__/gate-selfwrite.cpython-312.pyc`
is a tracked build artifact that came back onto `main` at least twice
(`c4c147a8` / #1125, and once before), each time as a stray hunk inside a PR
about something else. `.gitignore` had listed `__pycache__/` the whole time —
and could do nothing, because **gitignore has no say over a path that is already
tracked**: `git add -A` restages a tracked file whatever the ignore rules read.
The finding that opened the ticket (review N3 on PR #1094) is the point:
deleting the file per PR fixes the artifact, never the builder.

**What actually holds, in order of leverage:**

| # | where | what it does |
|---|---|---|
| 1a | `export PYTHONDONTWRITEBYTECODE=1` in every `bin/**/*.sh` that runs a `.py` file or inserts a `sys.path` entry | the interpreter writes no `__pycache__` at all — the only half where the file never exists |
| 1b | the same export in `tests/lib/scratch.sh` | **where the committed artifact actually came from.** `tests/gate-selfwrite-test.sh` loads `bin/gate-selfwrite.py` through `importlib.exec_module`, and a dozen tests `sys.path.insert` the repo's `bin/` and import `alert_family` — each writes into the CHECKOUT, not into `$T`. Every test sources this library first, so one export covers all of them and every test not written yet |
| 2 | `do_checkpoint` in `bin/lane-checkpoint.sh` | the builder's whole-tree `git add -A` carries `:!__pycache__/*  :!*/__pycache__/*  :!*.pyc  :!*.pyo`, **outside** `CHECKPOINT_EXCLUDE` so narrowing that knob cannot switch it off |
| 3 | the resolution commit in `bin/lander.sh` | the same pathspec on the other whole-tree stage in this repo |
| 4 | `tests/pycache-untracked.bh-1138-test.sh` | fails red if anything matching `__pycache__/`, `*.pyc` or `*.pyo` is tracked, and if a python call site under `bin/` forgets the export |

**How an operator reaches it:** there is no screen. It runs inside every build
(`bin/run-build.sh` → `bin/lane-checkpoint.sh --watch` during EXECUTE) and
inside the lander's merge-resolution commit. The observable end-state is a
harness PR whose diff carries no `.pyc`.

**How to drive it:**

| what | how |
|---|---|
| the whole contract: nothing tracked, the exports, both pathspecs, the mutation | `HARNESS_TEST_SANDBOX=1 bash tests/pycache-untracked.bh-1138-test.sh` |
| the checkpoint's surrounding behaviour is unchanged | `HARNESS_TEST_SANDBOX=1 bash tests/lane-checkpoint-test.sh` |
| what is tracked right now | `git ls-files \| grep -E '(^\|/)__pycache__/\|\.py[co]$'` — no output is the pass |
| the call sites the rule covers | `grep -rlE 'sys\.path\.insert\|spec_from_file_location\|python3[^\|;&]*[A-Za-z0-9_/$-]+\.py\b' bin tests --include='*.sh'` |

**Files it owns:**

- `tests/lib/scratch.sh` — the export every test inherits.
- `bin/lane-checkpoint.sh` — the `BH-1138-PYCACHE-EXCLUDE` pathspec.
- `bin/lander.sh` — the same pathspec on the resolution commit.
- the eleven python callers under `bin/` that carry the export.
- `.gitignore` — the three patterns, and the comment saying what they cannot do.
- `tests/pycache-untracked.bh-1138-test.sh` — this feature's suite.

**What must never regress:**

- **The exclusion never moves inside `CHECKPOINT_EXCLUDE`.** That variable is an
  operator's list of extra directories; an env line setting it to
  `node_modules` would silently restore the bug, and an env line is not a code
  review. Case 6 of the suite is that negative.
- **A new python call site carries the export.** The suite scans `bin/` and
  `tests/` for the property, never a hand-kept list — a list is what stops
  covering the next one. A test satisfies it by sourcing `tests/lib/scratch.sh`;
  a `bin/` script has no such prelude and carries it itself.
- **The tripwire keeps its two readers.** It asks git in a checkout and the
  filesystem in a `git archive` export (how the gates run it); a tree it could
  not read is a failure, never a quiet pass.

**Manual-only / not automatable:** nothing. Every assertion drives a real git
repo with a real bare origin in a scratch tree; there is no network, no `gh`,
and no LLM in this feature.
