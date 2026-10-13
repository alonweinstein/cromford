#!/bin/bash
# tests/plan-gate-shared-files.bh-5269-test.sh — BH-5269 (BH-5248.3): the plan
# gate flags a plan that names a conflict hotspot and does not list it under
# `## Shared files` (prompts/plan-contract.md §11).
#
# THE REPLAY. Three plans this repo really built, read in place from
# .harness/specs/, through the real bin/plan-gate.sh, against the measured
# hotspot table in docs/CONFLICT_HOTSPOTS.md:
#   R1 BH-5001 — appends to the D1 schema file and the worker route index, both
#                top-10 hotspots, and has no `## Shared files`: flagged;
#   R2 BH-2411 — names no top-10 path: ok;
#   R3 BH-4969 — names hotspots; with a `## Shared files` section appended that
#                lists each one with a reason: ok.
# The flag is a REPORT: the trace verdict and the exit code never change.
# No network, no model call. Run from anywhere (exit 0 = all pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

GATE="$DIR/bin/plan-gate.sh"
# TEST-CHANGE (BH-5800): bin/plan-gate.sh also refuses a bin/ or worker/ plan
# with no `## Failure modes` section now, and S5 runs real archived plans that
# predate it. This suite pins the Shared-files report, so it runs the gate with
# no failure-mode catalog (PLAN_FAILURE_MODES: unread, never a refusal).
# tests/plan-failure-modes.bh-5800-test.sh pins the checklist itself.
export PLAN_FAILURE_MODES_CATALOG="$T/no-failure-modes-catalog.tsv"
R1="$DIR/.harness/specs/BH-5001/plan.md"
R2="$DIR/.harness/specs/BH-2411/plan.md"
R3SRC="$DIR/.harness/specs/BH-4969/plan.md"
# The prompts that define the section this gate checks. Named here so a change
# to either one selects this suite (bin/test-impact.sh).
for f in "$DIR/prompts/plan-contract.md" "$DIR/prompts/build-discipline.md"; do
  grep -qF '## Shared files' "$f" && ok || bad "$f must define the ## Shared files section"
done

# The hotlist: the measured table's paths, one per line.
sed -nE 's/^\| *[0-9]+ *\| *`([^`]+)` *\|.*/\1/p' "$DIR/docs/CONFLICT_HOTSPOTS.md" > "$T/hot.txt"
NH=$(grep -c . "$T/hot.txt")
named_in_r1=0
while IFS= read -r p; do grep -qF "$p" "$R1" && named_in_r1=$((named_in_r1+1)); done < "$T/hot.txt"
if [ "$NH" -lt 2 ] || [ "$named_in_r1" = 0 ]; then
  bad "FIXTURE BROKEN: docs/CONFLICT_HOTSPOTS.md gave $NH paths, $named_in_r1 of them named in R1"
fi

run() { # run <plan> [hotlist|-]  -> G, GRC
  if [ "${2:-}" = - ]; then G=$("$GATE" "$1" 2>&1); GRC=$?
  else G=$(PLAN_GATE_HOTSPOTS="${2:-$T/hot.txt}" "$GATE" "$1" 2>&1); GRC=$?; fi
}
field() { sed -n "s/^$1:[[:space:]]*//p" <<<"$G" | tail -1; }
unlisted() { sed -n 's/^  SHARED_UNLISTED: //p' <<<"$G"; }

# ---- S1. R1 is flagged, and the flag never refuses ------------------------------
run "$R1" -; BASE_RC=$GRC; BASE_TRACE=$(field PLAN_TRACE)
run "$R1"
[ "$(field PLAN_SHARED)" = unlisted ] && ok || bad "S1 R1 must read PLAN_SHARED: unlisted: $G"
U=$(unlisted)
grep -qxF 'worker/jobs/schema.sql' <<<"$U" && ok || bad "S1 R1 must flag worker/jobs/schema.sql: $U"
grep -qxF 'worker/jobs/src/index.js' <<<"$U" && ok || bad "S1 R1 must flag worker/jobs/src/index.js: $U"
[ "$(grep -c . <<<"$U")" = "$(field PLAN_SHARED_NAMED)" ] && ok || bad "S1 one SHARED_UNLISTED per named path (named=$(field PLAN_SHARED_NAMED)): $U"
while IFS= read -r p; do
  [ -n "$p" ] || continue
  grep -qxF "$p" "$T/hot.txt" && grep -qF "$p" "$R1" && ok || bad "S1 flagged '$p' is not a hotlist path R1 names"
done <<<"$U"
[ "$GRC" = 0 ] && [ "$GRC" = "$BASE_RC" ] && ok || bad "S1 the flag must not change the rc (got $GRC, without it $BASE_RC)"
[ "$(field PLAN_TRACE)" = ok ] && [ "$BASE_TRACE" = ok ] && ok || bad "S1 PLAN_TRACE must stay ok: $G"
[ "$(tail -1 <<<"$G")" = 'PLAN_TRACE: ok' ] && ok || bad "S1 PLAN_TRACE must stay the last line: $(tail -1 <<<"$G")"

# ---- S2. R2 names no hotspot -------------------------------------------------------
run "$R2"
[ "$(field PLAN_SHARED)" = ok ] && ok || bad "S2 R2 must read PLAN_SHARED: ok: $G"
[ "$(field PLAN_SHARED_NAMED)" = 0 ] && ok || bad "S2 R2 names no hotspot: $G"
grep -q '^  SHARED_' <<<"$G" && bad "S2 R2 must carry no SHARED_ line" || ok

# ---- S3. R3 + a ## Shared files section that lists what it names ------------------
run "$R3SRC"
R3U=$(unlisted)
[ "$(field PLAN_SHARED)" = unlisted ] && [ -n "$R3U" ] && ok || bad "S3 R3 as recorded must be flagged first (it names hotspots): $G"
cp "$R3SRC" "$T/r3.md"
{ echo; echo '## Shared files'; echo
  while IFS= read -r p; do printf -- '- `%s` — named in this plan; the edit is one appended block.\n' "$p"; done <<<"$R3U"
} >> "$T/r3.md"
run "$T/r3.md"
[ "$(field PLAN_SHARED)" = ok ] && ok || bad "S3 R3 with every hotspot listed must read ok: $G"
grep -q '^  SHARED_UNLISTED:' <<<"$G" && bad "S3 R3 must carry no SHARED_UNLISTED: $G" || ok
[ "$(field PLAN_TRACE)" = ok ] && ok || bad "S3 the appended section must not open a task block: $G"

# ---- S4. a listed path with no reason --------------------------------------------
FIRST=$(head -1 <<<"$R3U")
awk -v p="$FIRST" 'index($0, "- `" p "` —") == 1 { print "- `" p "`"; next } { print }' "$T/r3.md" > "$T/r3-noreason.md"
run "$T/r3-noreason.md"
grep -qxF "  SHARED_NOREASON: $FIRST" <<<"$G" && ok || bad "S4 a listed path with no reason must be named: $G"
[ "$(field PLAN_SHARED)" = unlisted ] && ok || bad "S4 a path with no reason must read unlisted: $G"
[ "$GRC" = 0 ] && ok || bad "S4 rc must stay 0 (got $GRC)"

# ---- S5. env unset: byte-identical to the trace-only output ----------------------
for p in "$R1" "$R2" "$T/r3.md"; do
  run "$p" -; OFF=$G; OFFRC=$GRC
  run "$p";  ON=$G
  grep -qE '^(PLAN_SHARED|  SHARED_)' <<<"$OFF" && bad "S5 env unset must print no PLAN_SHARED line ($p)" || ok
  [ "$OFF" = "$(grep -vE '^(PLAN_SHARED|  SHARED_)' <<<"$ON")" ] && ok || bad "S5 the hotspot pass must only ADD lines ($p)"
  [ "$(tail -1 <<<"$OFF")" = 'PLAN_TRACE: ok' ] && [ "$OFFRC" = 0 ] && ok || bad "S5 env unset must end PLAN_TRACE: ok rc 0 ($p)"
done

# ---- S6. the hotlist named but unreadable ------------------------------------------
run "$R1" "$T/missing.txt"
[ "$(field PLAN_SHARED)" = unread ] && ok || bad "S6 a missing hotlist must read unread, never ok: $G"
grep -q '^  SHARED_' <<<"$G" && bad "S6 unread must list nothing" || ok

# An EMPTY hotlist is a real answer (measured, zero rows): nothing is hot.
: > "$T/empty.txt"
run "$R1" "$T/empty.txt"
[ "$(field PLAN_SHARED)" = ok ] && [ "$(field PLAN_SHARED_NAMED)" = 0 ] && ok || bad "S6 an empty hotlist must read ok, named 0: $G"

# ---- S7. the mention matcher's negatives -------------------------------------------
printf 'bin/hot.sh\n' > "$T/h7.txt"
cat > "$T/s7.md" <<'EOF'
# X-1

## Tasks

### Task 1 — edit around the hot file
- touch bin/hot.sh.bak, bin/hot.sh-old, xbin/hot.sh and src/bin/hot.sh only
- VALIDATE: `true`
- SATISFIES: criterion 1

```
bin/hot.sh is inside a fence
```

## Sibling claims (not touched)
- #9 edits bin/hot.sh in another region.

## Size
SIZE: S
EOF
run "$T/s7.md" "$T/h7.txt"
[ "$(field PLAN_SHARED_NAMED)" = 0 ] && [ "$(field PLAN_SHARED)" = ok ] && ok || bad "S7 prefix/suffix/fence/sibling mentions must not count: $G"
sed 's/^- touch .*/- We change bin\/hot.sh./' "$T/s7.md" > "$T/s7b.md"
run "$T/s7b.md" "$T/h7.txt"
[ "$(field PLAN_SHARED_NAMED)" = 1 ] && grep -qxF '  SHARED_UNLISTED: bin/hot.sh' <<<"$G" && ok || bad "S7 a sentence-final path is a mention: $G"
sed 's/^- touch .*/- edit `bin\/hot.sh` (one line)/' "$T/s7.md" > "$T/s7c.md"
run "$T/s7c.md" "$T/h7.txt"
[ "$(field PLAN_SHARED_NAMED)" = 1 ] && ok || bad "S7 a backticked path is a mention: $G"
printf '\n## Shared files\n- bin/hot.sh: the one-line call site.\n' >> "$T/s7c.md"
run "$T/s7c.md" "$T/h7.txt"
[ "$(field PLAN_SHARED)" = ok ] && ok || bad "S7 a colon reason must count as a reason: $G"
# A Shared-files bullet that opens with a task designator is a reason, not a
# task block: the trace verdict must not turn untraced on it.
printf '\n## Shared files\n- T1: `bin/hot.sh` — Task 1 edits one line.\n' >> "$T/s7b.md"
run "$T/s7b.md" "$T/h7.txt"
[ "$GRC" = 0 ] && [ "$(field PLAN_TRACE)" = ok ] && [ "$(field PLAN_SHARED)" = ok ] && ok || bad "S7 a T1: bullet under ## Shared files must not open a task (rc $GRC): $G"

# ---- S8. the build's plan gate block, run ------------------------------------------
mkdir -p "$T/h/state" "$T/h/logs"
scratch_install_closure bin/plan-gate.sh "$T/h" >/dev/null || bad "S8 cannot install bin/plan-gate.sh"
awk '/^# >>> plan gate/{f=1;next} /^# <<< plan gate/{exit} f' "$RB_ALL" > "$T/gate.sh"
[ -s "$T/gate.sh" ] && ok || bad "S8 could not extract the plan-gate block"
rm -rf "$T/b"; mkdir -p "$T/b"
cp "$R1" "$T/b/plan.md"; cp "$T/hot.txt" "$T/b/hotspots.txt"
: > "$T/cc.log"
OUT=$( env HARNESS="$T/h" BUILD="$T/b" PROJECT=widget-os KEY=WD-9 PLAN_MODEL=stub-model \
        ALERTS="$T/h/logs/ALERTS.log" CCLOG="$T/cc.log" JOB_ID=job-1 \
  bash -c 'set -uo pipefail
           STAMP() { echo TS; }
           RESULT() { echo "RESULT=$*"; }
           BB() { echo "BB=$1"; }
           CC() { echo "$*" >> "$CCLOG"; return 0; }
           job_artifact_put() { :; }
           . "$0"; echo "CONTINUED"' "$T/gate.sh" 2>&1 )
grep -q CONTINUED <<<"$OUT" && ok || bad "S8 a flagged plan must not stop the build: $OUT"
grep -q '^PLAN_SHARED: unlisted$' "$T/b/plan-gate.txt" && ok || bad "S8 plan-gate.txt must carry PLAN_SHARED: unlisted: $(cat "$T/b/plan-gate.txt")"
N=$(grep -c '^  SHARED_UNLISTED:' "$T/b/plan-gate.txt")
grep -qxF "TS [widget-os/WD-9] plan gate: shared files unlisted (unlisted=$N, noreason=0)" "$T/b/pipeline.log" \
  && ok || bad "S8 pipeline.log must carry the shared-files line: $(cat "$T/b/pipeline.log" 2>&1)"
[ ! -s "$T/cc.log" ] && ok || bad "S8 a flagged plan must not buy a repair session"
grep -q PLAN_MALFORMED "$T/b/pipeline.log" 2>/dev/null && bad "S8 a flagged plan must not be PLAN_MALFORMED" || ok
# No hotlist this build (never measured / outage): the line says unread.
rm -f "$T/b/hotspots.txt" "$T/b/pipeline.log"
( env HARNESS="$T/h" BUILD="$T/b" PROJECT=widget-os KEY=WD-9 PLAN_MODEL=stub-model \
        ALERTS="$T/h/logs/ALERTS.log" CCLOG="$T/cc.log" JOB_ID=job-1 \
  bash -c 'STAMP() { echo TS; }; RESULT() { :; }; BB() { :; }; CC() { :; }; job_artifact_put() { :; }; . "$0"' "$T/gate.sh" ) >/dev/null 2>&1
grep -qxF "TS [widget-os/WD-9] plan gate: shared files unread (unlisted=0, noreason=0)" "$T/b/pipeline.log" \
  && ok || bad "S8 no hotlist must log unread: $(cat "$T/b/pipeline.log" 2>&1)"

echo "plan-gate-shared-files.bh-5269: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
