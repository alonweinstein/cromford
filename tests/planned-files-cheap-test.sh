#!/bin/bash
# tests/planned-files-cheap-test.sh — bin/planned-files-cheap.sh against a
# scratch harness, a scratch repo, a stubbed codegraph and a stubbed agent call.
# Run from anywhere: tests/planned-files-cheap-test.sh   (exit 0 = all pass)
#
# WHAT THIS PINS AND WHY. The file half of bin/dep-verify.sh used to come from
# the speculative pre-plan lane, which cost $2-6 a ticket on a frontier model
# and was switched off on 2026-09-16 (flags/preplan-speculative-off) after 34 of
# 52 plans went stale in three hours. Switching it off took the dependency
# evidence with it, so every `Blocked-by:` line went back to being obeyed rather
# than checked and independent children waited on parents they share no file
# with. Most of that evidence was in the ticket body the whole time.
#
# So the load-bearing assertion here is NOT "a list was produced" — it is WHICH
# TIER produced it, and above all that the model was NOT called when the
# deterministic tiers had an answer. The agent-call stub records every
# invocation; a test that only checked the output file would pass just as
# happily with a $0.002 call on every tick, which over a fleet of four boards is
# the whole saving gone.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

export HARNESS="$T" FLEET_CONF="$T/fleet.conf"
mkdir -p "$T/bin/lib" "$T/env" "$T/flags" "$T/logs" "$T/plans" "$T/state" "$T/prompts" "$T/catalog"
cp "$DIR/bin/planned-files-cheap.sh" "$T/bin/" 2>/dev/null || { echo "FAIL: bin/planned-files-cheap.sh does not exist"; exit 1; }
cp "$DIR/bin/lib/lane-switch.sh" "$DIR/bin/lib/lane-gate.sh" "$T/bin/lib/"
cp "$DIR/bin/lib/preplan-lib.sh" "$DIR/bin/lib/dep-verify-lib.sh" "$T/bin/lib/"
# TEST-CHANGE (BH-782): bin/preplan-candidates.sh reads GitHub through the
# REST contract now. Without the lib beside it every tick answers "launch gate
# UNKNOWN" and prints no candidates, so the suite would be measuring a missing
# library rather than candidate selection.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/bin/lib/"
cp "$DIR/bin/fleet-conf.sh" "$T/bin/"
cp "$DIR/catalog/model-prices.json" "$T/catalog/"
cat > "$T/fleet.conf" <<'CONF'
proj  example-org/proj   -                 -           0 local -
CONF
echo 'setsid /root/harness/bin/run-build.sh proj <issue-number> AB-<issue-number> > x' > "$T/prompts/proj.md"

# ---- the repo the paths are checked against --------------------------------
# "Exists on main, or sits under a directory that does" is the filter, because a
# NEW file is the normal case for a ticket and its directory is what the overlap
# rule can compare. src/lib and tests exist; src/ghost does not.
REPO="$T/repos/proj"
mkdir -p "$REPO/src/lib" "$REPO/tests" "$REPO/docs/verification-map"
: > "$REPO/src/lib/a.ts"
: > "$REPO/src/lib/importer.ts"
echo '# index' > "$REPO/docs/verification-map/README.md"
export REPOS_ROOT="$T/repos"

# ---- the stubs -------------------------------------------------------------
CALLDIR="$T/calls"; mkdir -p "$CALLDIR"; export CALLDIR
cat > "$T/bin/agent-call.sh" <<'STUB'
#!/bin/bash
# agent-call.sh <stage> <project> <model> <timeout> <outfile> <prompt|@file>
D="${CALLDIR:?}"
PR="$6"; case "$PR" in @/*) PR=$(cat "${PR#@}") ;; esac
F=$(mktemp "$D/prompt-XXXXXXXX.txt"); printf '%s' "$PR" > "$F"
printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$D/calls.tsv"
printf '%s\n' "${STUB_ANSWER:-src/lib/a.ts}" > "$5"
exit "${STUB_RC:-0}"
STUB
chmod +x "$T/bin/agent-call.sh"

# codegraph stub: the real CLI's `node -f <file> --symbols-only` header line is
# "**<path>** — N symbols, used by K files: a, b, c" (verified against
# codegraph 1.6.0), and that list IS the one-hop importer set.
cat > "$T/bin/codegraph" <<'SH'
#!/bin/bash
[ "${CG_FAIL:-}" = 1 ] && exit 1
f=""
while [ $# -gt 0 ]; do case "$1" in -f) f="$2"; shift 2 ;; *) shift ;; esac; done
case "$f" in
  src/lib/a.ts) echo "**src/lib/a.ts** — 3 symbols, used by 2 files: src/lib/importer.ts, src/ghost/gone.ts" ;;
  *)            echo "**$f** — 1 symbols, no other indexed file depends on it" ;;
esac
SH
chmod +x "$T/bin/codegraph"
export PATH="$T/bin:$PATH"

ncalls() { [ -s "$CALLDIR/calls.tsv" ] && grep -c . "$CALLDIR/calls.tsv" || echo 0; }
reset_calls() { scratch_rm "$CALLDIR"; mkdir -p "$CALLDIR"; }
run() { "$T/bin/planned-files-cheap.sh" proj "$@" >/dev/null 2>&1; }
src_of() { sed -n '1s/^SOURCE:[[:space:]]*//p' "$1"; }

# ---------- 1. the ticket body alone, and NO model call ----------------------
# The ticket's own fixture: a body naming src/lib/a.ts and tests/a.test.ts.
BODY="$T/body-1.md"
cat > "$BODY" <<'MD'
## Scope
Add the rollup helper in `src/lib/a.ts` and cover it in `tests/a.test.ts`.
MD
L="$T/plans/proj-AB-20/planned-files.txt"
PLANNED_FILES_BODY_FILE="$BODY" run AB-20
[ -s "$L" ] && ok || bad "a body naming two paths must produce a list at $L"
[ "$(src_of "$L")" = "ticket-body" ] && ok \
  || bad "the list must declare SOURCE: ticket-body (got: $(src_of "$L"))"
grep -qx 'src/lib/a.ts' "$L" && ok || bad "the existing file named in the body must be in the list"
grep -qx 'tests/a.test.ts' "$L" && ok \
  || bad "a NEW file under an existing directory must be in the list (it is the overlap unit)"
[ "$(ncalls)" = 0 ] && ok || bad "the deterministic tier must not call the model at all (calls: $(ncalls))"

# ...and a path under a directory that does not exist is dropped, because it is
# evidence about nothing: an invented path can only ever manufacture a disjoint.
cat > "$T/body-ghost.md" <<'MD'
Touch `src/ghost/nowhere.ts` and `src/lib/a.ts`.
MD
reset_calls
PLANNED_FILES_BODY_FILE="$T/body-ghost.md" run AB-21
grep -q 'src/ghost' "$T/plans/proj-AB-21/planned-files.txt" \
  && bad "a path under a non-existent directory must be dropped" || ok
[ "$(ncalls)" = 0 ] && ok || bad "a body that yielded one real path must not reach the model"

# ---------- 2. codegraph adds the one-hop importers -------------------------
mkdir -p "$REPO/.codegraph"
reset_calls
PLANNED_FILES_BODY_FILE="$BODY" run AB-22
L22="$T/plans/proj-AB-22/planned-files.txt"
[ "$(src_of "$L22")" = "ticket-body+codegraph" ] && ok \
  || bad "with .codegraph/ present and an importer found, SOURCE must say ticket-body+codegraph (got: $(src_of "$L22"))"
grep -qx 'src/lib/importer.ts' "$L22" && ok || bad "the one-hop importer must be added to the list"
grep -q 'src/ghost/gone.ts' "$L22" \
  && bad "an importer the checkout does not have must still be filtered out" || ok
[ "$(ncalls)" = 0 ] && ok || bad "the codegraph tier must not call the model either"
# a dead codegraph is a narrower list, never a failure
reset_calls
CG_FAIL=1 PLANNED_FILES_BODY_FILE="$BODY" run AB-23
[ "$(src_of "$T/plans/proj-AB-23/planned-files.txt")" = "ticket-body" ] && ok \
  || bad "a codegraph that errors must fall back to the ticket-body list"
scratch_rm "$REPO/.codegraph"

# ---------- 3. nothing in the body: ONE floor-model call --------------------
cat > "$T/body-empty.md" <<'MD'
## Scope
Make the weekly digest read better. No file names here on purpose.
MD
reset_calls
PLANNED_FILES_BODY_FILE="$T/body-empty.md" run AB-30
L30="$T/plans/proj-AB-30/planned-files.txt"
[ "$(ncalls)" = 1 ] && ok || bad "a body naming nothing must reach the model exactly once (calls: $(ncalls))"
[ "$(src_of "$L30")" = "model-floor" ] && ok \
  || bad "the model list must declare SOURCE: model-floor (got: $(src_of "$L30"))"
grep -qx 'src/lib/a.ts' "$L30" && ok || bad "the model's answer must become the list"
# the cost row's stage, and the model id resolved from the catalog rather than
# typed into the script — a hardcoded claude-* string is the bug this repo's
# own iron laws name.
cut -f1 "$CALLDIR/calls.tsv" | grep -qx 'preplan-files' && ok \
  || bad "the call must be billed to the preplan-files stage (got: $(cut -f1 "$CALLDIR/calls.tsv"))"
M=$(cut -f3 "$CALLDIR/calls.tsv" | head -1)
[ -n "$M" ] && python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["per_token"]; sys.exit(0 if sys.argv[2] in d else 1)' \
     "$T/catalog/model-prices.json" "$M" && ok \
  || bad "the model id must be one the price catalog carries (got: $M)"
grep -qE 'claude-[a-z]+-[0-9]' <<<"$(grep -vE '^[[:space:]]*#' "$DIR/bin/planned-files-cheap.sh")" \
  && bad "a hardcoded claude-* model id in the script — it must come from the catalog" || ok

# ---------- 4. the cap: one call per ticket per 6h --------------------------
reset_calls
PLANNED_FILES_BODY_FILE="$T/body-empty.md" run AB-30
[ "$(ncalls)" = 0 ] && ok || bad "a second run inside the window must not call again (calls: $(ncalls))"
[ "$(src_of "$L30")" = "model-floor" ] && ok || bad "the earlier list must survive the skipped call"
# ...and the marker is written BEFORE the call, so a crashed or empty call
# cannot re-bill on the next tick (dedup-before-spend).
reset_calls
STUB_RC=1 PLANNED_FILES_BODY_FILE="$T/body-empty.md" run AB-31
[ "$(ncalls)" = 1 ] && ok || bad "the first call for a new ticket must happen (calls: $(ncalls))"
reset_calls
STUB_RC=1 PLANNED_FILES_BODY_FILE="$T/body-empty.md" run AB-31
[ "$(ncalls)" = 0 ] && ok || bad "a FAILED call must still burn the window — otherwise every tick re-bills"
# ...and a marker that cannot be WRITTEN means no call at all. A billable call
# with no persisted record of it is the guard that exists and never becomes
# true, which is the most expensive bug shape in this class.
reset_calls
# A FILE where the marker directory should be. Not a chmod: the fleet runs these
# as root and root writes through a mode bit, so the refusal would never fire and
# the case would prove nothing.
rm -rf "$T/state/preplan-files"; : > "$T/state/preplan-files"
PLANNED_FILES_BODY_FILE="$T/body-empty.md" run AB-32
rm -f "$T/state/preplan-files"
[ "$(ncalls)" = 0 ] && ok \
  || bad "an unwritable dedup marker must stop the call, not proceed without it (calls: $(ncalls))"

# ---------- 5. a real pre-plan is better evidence and is never overwritten ---
PD="$T/plans/proj-AB-40"; mkdir -p "$PD"
printf '## Scope\nreal plan\n' > "$PD/plan.md"
printf 'src/lib/from-the-real-plan.ts\n' > "$PD/planned-files.txt"
reset_calls
PLANNED_FILES_BODY_FILE="$BODY" run AB-40
grep -qx 'src/lib/from-the-real-plan.ts' "$PD/planned-files.txt" && ok \
  || bad "a directory holding a real plan.md must be left alone"
[ "$(ncalls)" = 0 ] && ok || bad "a ticket with a real pre-plan must cost nothing"

# ---------- 6. the kill flag -------------------------------------------------
reset_calls
PLANNED_FILES_CHEAP=0 PLANNED_FILES_BODY_FILE="$BODY" run AB-50
[ -e "$T/plans/proj-AB-50/planned-files.txt" ] \
  && bad "PLANNED_FILES_CHEAP=0 must write nothing" || ok
touch "$T/flags/planned-files-cheap-off"
PLANNED_FILES_BODY_FILE="$BODY" run AB-51
[ -e "$T/plans/proj-AB-51/planned-files.txt" ] \
  && bad "flags/planned-files-cheap-off must write nothing" || ok
rm -f "$T/flags/planned-files-cheap-off"
PLANNED_FILES_BODY_FILE="$BODY" run AB-52
[ -s "$T/plans/proj-AB-52/planned-files.txt" ] && ok || bad "removing the flag must turn it back on"

# ---------- 7. garbage in, exit 0 -------------------------------------------
reset_calls
"$T/bin/planned-files-cheap.sh" proj >/dev/null 2>&1
[ $? -ne 0 ] && ok || bad "a missing KEY must fail loudly rather than write a list for ''"
PLANNED_FILES_BODY_FILE="$T/no-such-body" run AB-60
[ $? -eq 0 ] && ok || bad "an unreadable body must exit 0 — this is an optimisation, never a tick killer"

# ---------- 8. the caller: preplan-candidates runs it with the flag off -----
# THE LEG THAT MAKES ANY OF THIS REACH A BOX. With PREPLAN_SPECULATIVE=0 the
# tick takes the first `queued` row and nothing else, so a `child` or `blocked`
# row is printed and then ignored — which is the state dep-verify was left in
# when the speculative lane was switched off. Driven end to end here rather than
# grepped, because "the block is in the file" and "the block runs" are different
# claims and only one of them is worth anything: the assertion is a real
# planned-files.txt on disk for a ticket nothing else planned, produced from the
# body the candidates script had ALREADY fetched (the fake gh answers one
# `issue list` and no `issue view` at all, so a second fetch would fail).
#
# PLATFORM GATE, stated rather than silently passing: bin/preplan-candidates.sh
# sources bin/lib/preplan-lib.sh, which does not PARSE under bash 3.2 (a `case`
# inside a `while` inside a command substitution — the same reason
# tests/dep-verify-test.sh is one of the suites CONTRIBUTING.md says fail on
# macOS). On that shell this section cannot run at all, so it says so and is
# skipped rather than counted either way. It runs for real in the container,
# which is the platform the fleet is.
# Probed with /bin/bash on purpose — that is the shebang every script in bin/
# carries, and on macOS it is 3.2 even when the shell running this suite is 5.x.
if ! /bin/bash -n "$T/bin/lib/preplan-lib.sh" 2>/dev/null; then
  echo "planned-files-cheap: SKIPPING section 8 — this shell cannot parse bin/lib/preplan-lib.sh (bash 3.2); run it in the container"
  echo "planned-files-cheap: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]; exit
fi
cp "$DIR/bin/preplan-candidates.sh" "$T/bin/"
touch "$T/flags/preplan-speculative-off"
# TEST-CHANGE (BH-782): bin/preplan-candidates.sh reads issues and PRs through
# the REST contract now (`gh api -i`), so the shim peels the flags and answers a
# status line + blank line + body. The fixtures are the same rows.
cat > "$T/bin/gh" <<'SH'
#!/bin/bash
[ "${1:-}" = api ] || exit 1
shift
INC=0; P=""
while [ $# -gt 0 ]; do
  case "$1" in
    -i) INC=1; shift ;;
    -X|-f|-F|-H) shift 2 ;;
    -*) shift ;;
    *) P="$1"; shift; break ;;
  esac
done
case "$P" in
  */issues*) BODY=$(cat "$HARNESS/issues.json" 2>/dev/null || echo '[]') ;;
  */pulls*)  BODY='[]' ;;
  *)         exit 1 ;;
esac
[ "$INC" = 1 ] && printf 'HTTP/2.0 200\r\n\r\n'
printf '%s\n' "$BODY"
SH
chmod +x "$T/bin/gh"
cat > "$T/issues.json" <<'JSON'
[{"number":91,"state":"OPEN","title":"parent","body":"## Scope\nthe parent\n"},
 {"number":90,"state":"OPEN","title":"child","body":"## Scope\nTouch `src/lib/a.ts` and add `tests/rollup.test.ts`.\nBlocked-by: #91\n"}]
JSON
: > "$REPO/src/lib/rollup.ts"
reset_calls
ROWS=$("$T/bin/preplan-candidates.sh" proj 2>/dev/null)
grep -q 'AB-90' <<<"$ROWS" && ok || bad "the candidates script must still print its rows (got: $ROWS)"
CL="$T/plans/proj-AB-90/planned-files.txt"
[ -s "$CL" ] && ok || bad "a blocked child must get a cheap list with PREPLAN_SPECULATIVE=0"
[ "$(src_of "$CL")" = "ticket-body" ] && ok \
  || bad "that list must come from the body the candidates script already had (got: $(src_of "$CL"))"
grep -qx 'src/lib/a.ts' "$CL" && ok || bad "the child's own named file must be in it"
[ "$(ncalls)" = 0 ] && ok || bad "the candidates pass must not have cost a model call (calls: $(ncalls))"
[ -e "$T/plans/proj-AB-91/planned-files.txt" ] \
  && bad "an unblocked parent is not a child or blocked row — it must not be listed" || ok

# ---------- 8b. a MID-BUILD parent's child is written too (2026-09-16) -------
# `child-building` is the class bin/preplan-candidates.sh gives a child whose
# parent is BUILDING RIGHT NOW — the hour between a parent's build starting and
# its PR existing, which is exactly the hour dep-verify's file half has nothing
# to read. Leaving it out of this pass would write the evidence for every child
# EXCEPT the one that needs it soonest.
rm -f "$CL"; rmdir "$T/plans/proj-AB-90" 2>/dev/null
touch "$T/flags/preplan-speculative-off"
# A build directory with no RESULT in it is a pipeline that has not ENDED —
# preplan_midbuild_keys' first source, and an event rather than a stopwatch.
mkdir -p "$T/builds/proj-AB-91-20260916000001"
reset_calls
ROWS=$("$T/bin/preplan-candidates.sh" proj 2>/dev/null)
grep -qP '^AB-90\t90\tchild-building$' <<<"$ROWS" \
  && ok || bad "a child of a MID-BUILD parent must be classed child-building (got: $ROWS)"
[ -s "$CL" ] \
  && ok || bad "and it must get the same cheap planned-files list child and blocked rows get — it is the row dep-verify needs first"
grep -qx 'src/lib/a.ts' "$CL" && ok || bad "the child-building list must carry the child's own named file"
[ "$(ncalls)" = 0 ] && ok || bad "still no model call (calls: $(ncalls))"
rm -rf "$T/builds/proj-AB-91-20260916000001"
# ...and with speculative mode back ON the full pre-plan lane owns this, so the
# candidates script is byte-for-byte what it was: rows printed, nothing written.
rm -f "$T/flags/preplan-speculative-off" "$CL"
rmdir "$T/plans/proj-AB-90" 2>/dev/null
ROWS=$("$T/bin/preplan-candidates.sh" proj 2>/dev/null)
grep -q 'AB-90' <<<"$ROWS" && ok || bad "rows must still print with speculative mode on (got: $ROWS)"
[ -e "$CL" ] && bad "with PREPLAN_SPECULATIVE=1 the candidates script must write nothing" || ok

echo "planned-files-cheap: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
