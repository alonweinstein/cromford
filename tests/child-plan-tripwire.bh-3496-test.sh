#!/bin/bash
# tests/child-plan-tripwire.bh-3496-test.sh — the child plan cost tripwire
# checker, cpt_check in bin/lib/child-plan-tripwire.sh (BH-3478.4). The ticket
# body calls this suite child-plan-tripwire.bh-3478-test.sh; it is named for
# its own ticket key, the same as #3492 did for context-pack-wire.
#
# No network anywhere: _jobs_req is a shell stub that answers by path from
# files under $T (the knob, cost-rows fixtures, the ledger). The REAL
# bin/lib/jobs/settings.sh and bin/lib/jobs/jobs.sh are sourced over it, so
# setting_get / job_ledger_get / job_ledger_put are the production verbs, and
# the alert goes through a copy of the REAL bin/alert-line.sh. T10 drives the
# plan.sh hook block extracted verbatim from the flattened pipeline.
#
# Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 bash tests/child-plan-tripwire.bh-3496-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/rb-all.sh" || exit 1
LIB="$DIR/bin/lib/child-plan-tripwire.sh"
NOW="2026-09-29 12:00:00Z"
export ALERT_LINE_STAMP="$NOW"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: expected [$3] got [$2]"; }

# The stub, as text, so a fresh bash (the hook and loader cases) gets the same one.
# At a ledger PUT it records how many ALERTS lines exist, so T1 can prove the
# alert was written BEFORE the put.
STUB='_jobs_req() {
  local m="$1" p="$2" b="${3:-}" tk st f
  printf "%s %s\n" "$m" "$p" >> "$T/calls"
  case "$p" in
    /api/settings/child_plan_tripwire_pct)
      [ -e "$T/knob" ] || return 2
      [ "$(cat "$T/knob")" = outage ] && return 1
      jq -nc --arg v "$(cat "$T/knob")" "{setting:{value:\$v}}"; return 0 ;;
    /api/metrics/cost-rows\?*)
      tk=$(printf "%s" "$p" | sed -n "s/.*[?&]ticket=\([^&]*\).*/\1/p")
      st=$(printf "%s" "$p" | sed -n "s/.*[?&]stage=\([^&]*\).*/\1/p")
      f="$T/rows/$tk.$st"
      [ -e "$f.fail" ] && return 1
      if [ -e "$f.json" ]; then cat "$f.json"; else printf "{\"cost_rows\":[]}"; fi
      return 0 ;;
    /api/ledger\?*)
      [ -s "$T/ledger" ] || return 2
      jq -nc --arg s "$(cat "$T/ledger")" "{ledger:{status:\$s}}"; return 0 ;;
    /api/ledger)
      printf "%s\n" "$b" >> "$T/ledger-puts"
      printf "put alerts=%s\n" "$(cat "$T/h/logs/ALERTS.log" 2>/dev/null | grep -c .)" >> "$T/seq"
      echo fired > "$T/ledger"; return 0 ;;
  esac
  return 1
}'
export T

# rows <ticket> <stage> <cost...> — a cost-rows page; "null" and quoted
# strings pass through as JSON. extra <ticket> <stage> <other-stage> <cost>
# appends a row of a DIFFERENT stage to that page (a worker ignoring stage=).
rows() {
  local tk="$1" st="$2"; shift 2
  printf '%s\n' "$@" | jq -sc --arg t "$tk" --arg s "$st" \
    '{cost_rows: map({ticket:$t, stage:$s, project:"cromford", cost_usd:.})}' > "$T/rows/$tk.$st.json"
}
extra() {
  jq -c --arg t "$1" --arg s "$3" --argjson c "$4" \
    '.cost_rows += [{ticket:$t, stage:$s, project:"cromford", cost_usd:$c}]' \
    "$T/rows/$1.$2.json" > "$T/rows/x" && mv "$T/rows/x" "$T/rows/$1.$2.json"
}
fresh() { # fresh scratch harness: alert-line.sh copy, no fixtures, no knob
  rm -rf "$T/h" "$T/rows" "$T/knob" "$T/calls" "$T/ledger" "$T/ledger-puts" "$T/seq" "$T/out"
  mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/rows"; : > "$T/calls"
  cp "$DIR/bin/alert-line.sh" "$T/h/bin/alert-line.sh"; chmod +x "$T/h/bin/alert-line.sh"
}
t1_rows() { # child 1.20 + (2.00 + 0.75 + null) = 3.95 ; parent 2.43 + 4.00 = 6.43
  rows BH-3496 preplan 1.20; rows BH-3496 plan '"2.00"' 0.75 null
  rows BH-3478 preplan 2.43; rows BH-3478 plan 4.00
}
run() { # run [child] [parent] -> first stdout line in OUT, full stdout in $T/out
  ( export HARNESS="$T/h" JOBS_BOX=test-box HARNESS_SECRET=s3cr3t-stub-value JOBS_URL=https://jobs.example
    eval "$STUB"
    . "$DIR/bin/lib/jobs/settings.sh"; . "$DIR/bin/lib/jobs/jobs.sh"
    . "$LIB"; cpt_check cromford "${1-BH-3496}" "${2-BH-3478}"; echo "rc=$?" >&2 ) > "$T/out" 2> "$T/err"
  OUT=$(head -n1 "$T/out")
}
nlines() { local n; n=$(grep -c . "$1" 2>/dev/null); echo "${n:-0}"; }
alerts() { nlines "$T/h/logs/ALERTS.log"; }
costreads() { grep -c 'cost-rows' "$T/calls"; }
no_alert() { eq "$1.alerts" "$(alerts)" 0; [ -e "$T/ledger-puts" ] && bad "$1: ledger PUT without FIRE" || ok; }

# ============================================================================
# T1 FIRE: one ALERTS line through alert-line.sh, then one ledger PUT
# ============================================================================
fresh; t1_rows; echo 50 > "$T/knob"; run
eq T1.verdict "$OUT" "FIRE 3.95 6.43 61.4 50"
eq T1.stdout-lines "$(nlines "$T/out")" 1
grep -q '^rc=0$' "$T/err" && ok || bad "T1: rc not 0 ($(cat "$T/err"))"
eq T1.alerts "$(alerts)" 1
A=$(cat "$T/h/logs/ALERTS.log" 2>/dev/null)
for s in "$NOW [child-plan-tripwire]" cromford/BH-3496 BH-3478 '$3.95' '$6.43' '61.4%' '(threshold 50%)' \
         'api/metrics/cost-rows?ticket=BH-3496' '$HARNESS_SECRET' '$JOBS_URL'; do
  case "$A" in *"$s"*) ok ;; *) bad "T1: ALERTS line lacks [$s]: $A" ;; esac
done
case "$A" in *s3cr3t-stub-value*|*jobs.example*) bad "T1: ALERTS line leaks an env value" ;; *) ok ;; esac
eq T1.puts "$(nlines "$T/ledger-puts")" 1
eq T1.put-kind "$(jq -r .kind "$T/ledger-puts" 2>/dev/null)" child_plan_tripwire
eq T1.put-key "$(jq -r .key "$T/ledger-puts" 2>/dev/null)" "cromford BH-3496"
eq T1.put-status "$(jq -r .status "$T/ledger-puts" 2>/dev/null)" fired
eq T1.put-detail "$(jq -r .detail "$T/ledger-puts" 2>/dev/null)" "3.95 6.43 61.4 50 parent=BH-3478"
eq T1.alert-before-put "$(cat "$T/seq" 2>/dev/null)" "put alerts=1"
eq T1.ledger-read-first "$(grep -m1 -n 'api/ledger' "$T/calls" | cut -d: -f2-)" \
  "GET /api/ledger?kind=child_plan_tripwire&key=cromford%20BH-3496"
# every cost read carries project=, ticket=, stage= and the 2000-row limit
eq T1.cost-reads "$(grep 'cost-rows' "$T/calls" | sort | tr '\n' '|')" \
"GET /api/metrics/cost-rows?project=cromford&ticket=BH-3478&stage=plan&limit=2000|GET /api/metrics/cost-rows?project=cromford&ticket=BH-3478&stage=preplan&limit=2000|GET /api/metrics/cost-rows?project=cromford&ticket=BH-3496&stage=plan&limit=2000|GET /api/metrics/cost-rows?project=cromford&ticket=BH-3496&stage=preplan&limit=2000|"

# T1b: alert-line.sh gets the id and project
fresh; t1_rows; echo 50 > "$T/knob"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alert-argv"\n' "$T" > "$T/h/bin/alert-line.sh"
rm -f "$T/alert-argv"; run
eq T1b.verdict "$OUT" "FIRE 3.95 6.43 61.4 50"
eq T1b.calls "$(nlines "$T/alert-argv")" 1
case "$(cat "$T/alert-argv" 2>/dev/null)" in
  "--severity warn --id child-plan-tripwire:cromford:BH-3496 --project cromford [child-plan-tripwire] cromford/BH-3496: "*) ok ;;
  *) bad "T1b: alert-line argv: $(cat "$T/alert-argv" 2>/dev/null)" ;; esac
eq T1b.no-direct-append "$(alerts)" 0

# T1c: no alert-line.sh on the box -> FIRE still printed, no alert, no PUT (next build retries)
fresh; t1_rows; echo 50 > "$T/knob"; rm -f "$T/h/bin/alert-line.sh"; run
eq T1c.verdict "$OUT" "FIRE 3.95 6.43 61.4 50"
no_alert T1c

# ============================================================================
# T2 already fired: FIRE printed, no second alert, no second PUT
# ============================================================================
fresh; t1_rows; echo 50 > "$T/knob"; run; run
eq T2.verdict "$OUT" "FIRE 3.95 6.43 61.4 50"
eq T2.alerts "$(alerts)" 1
eq T2.puts "$(nlines "$T/ledger-puts")" 1
# T2b: a ledger outage fails OPEN for the page (a duplicate beats a silence)
fresh; t1_rows; echo 50 > "$T/knob"; echo broken > "$T/ledger"
run; eq T2b.verdict "$OUT" "FIRE 3.95 6.43 61.4 50"; eq T2b.alerts "$(alerts)" 1

# ============================================================================
# T3 OK, and the strict boundary
# ============================================================================
fresh; t1_rows; rows BH-3496 plan; rows BH-3496 preplan 1.00; echo 50 > "$T/knob"; run
eq T3.verdict "$OUT" "OK 1.00 6.43 15.6 50"
no_alert T3
grep -q 'api/ledger' "$T/calls" && bad "T3: ledger touched on OK" || ok
fresh; rows BH-3496 preplan 1.00; rows BH-3478 plan 2.00; echo 50 > "$T/knob"; run
eq T3b.exactly-at-threshold "$OUT" "OK 1.00 2.00 50.0 50"
fresh; t1_rows; echo 50.5 > "$T/knob"; run
eq T3c.decimal-knob "$OUT" "FIRE 3.95 6.43 61.4 50.5"
fresh; rows BH-3478 plan 2.00; echo 50 > "$T/knob"; run
eq T3d.child-no-rows "$OUT" "OK 0.00 2.00 0.0 50"

# ============================================================================
# T4 no parent baseline
# ============================================================================
fresh; rows BH-3496 plan 3.00; echo 50 > "$T/knob"; run
eq T4.verdict "$OUT" "UNMEASURED no parent baseline"; no_alert T4
fresh; rows BH-3496 plan 3.00; rows BH-3478 plan null null; rows BH-3478 preplan 0; echo 50 > "$T/knob"; run
eq T4b.all-null "$OUT" "UNMEASURED no parent baseline"; no_alert T4b

# ============================================================================
# T5 a full 2000-row page is truncated, never summed
# ============================================================================
fresh; t1_rows; echo 50 > "$T/knob"
jq -nc '{cost_rows:[range(2000)|{ticket:"BH-3496",stage:"plan",cost_usd:0.01}]}' > "$T/rows/BH-3496.plan.json"
run
eq T5.verdict "$OUT" "UNMEASURED BH-3496 plan truncated (2000-row page)"; no_alert T5

# ============================================================================
# T6 knob 0 -> OFF, no cost reads
# ============================================================================
for k in 0 0.0; do
  fresh; t1_rows; echo "$k" > "$T/knob"; run
  eq "T6.$k" "$OUT" OFF; eq "T6.$k.reads" "$(costreads)" 0; no_alert "T6.$k"
done

# ============================================================================
# T7 invalid knob -> UNMEASURED + one log line, no clamp, no cost reads
# ============================================================================
for k in abc -5 50% ' '; do
  fresh; t1_rows; printf '%s' "$k" > "$T/knob"; run
  eq "T7[$k]" "$OUT" "UNMEASURED invalid knob child_plan_tripwire_pct=$k"
  eq "T7[$k].log" "$(nlines "$T/h/logs/child-plan-tripwire.log")" 1
  case "$(cat "$T/h/logs/child-plan-tripwire.log" 2>/dev/null)" in
    *"[cromford/BH-3496] child_plan_tripwire_pct=$k is not a non-negative number; tripwire unmeasured (D11, no clamp)") ok ;;
    *) bad "T7[$k]: log line: $(cat "$T/h/logs/child-plan-tripwire.log" 2>/dev/null)" ;; esac
  eq "T7[$k].reads" "$(costreads)" 0; no_alert "T7[$k]"
done

# ============================================================================
# T8 no knob row -> the documented fallback 50
# ============================================================================
fresh; t1_rows; run
eq T8.verdict "$OUT" "FIRE 3.95 6.43 61.4 50"

# ============================================================================
# T9 other stages leaking into a page are never summed; URLs ask only preplan/plan
# ============================================================================
fresh; t1_rows; rows BH-3496 plan; rows BH-3496 preplan 1.00
extra BH-3478 preplan decompose 500.00; extra BH-3496 plan execute 90.00; echo 50 > "$T/knob"; run
eq T9.verdict "$OUT" "OK 1.00 6.43 15.6 50"
eq T9.stages "$(grep -o 'stage=[a-z-]*' "$T/calls" | sort | uniq -c | awk '{print $2"x"$1}' | tr '\n' ' ')" "stage=planx2 stage=preplanx2 "

# ============================================================================
# T11 outages are UNMEASURED, never $0
# ============================================================================
fresh; t1_rows; echo outage > "$T/knob"; run
eq T11.knob-outage "$OUT" "UNMEASURED knob unreadable"; eq T11.reads "$(costreads)" 0
fresh; t1_rows; echo 50 > "$T/knob"; touch "$T/rows/BH-3478.plan.fail"; run
eq T11.read-failed "$OUT" "UNMEASURED BH-3478 plan read failed"; no_alert T11
fresh; t1_rows; echo 50 > "$T/knob"; echo 'not json' > "$T/rows/BH-3478.preplan.json"; run
eq T11b.unparseable "$OUT" "UNMEASURED BH-3478 preplan unparseable"; no_alert T11b
fresh; t1_rows; echo 50 > "$T/knob"; echo '{"cost_rows":{}}' > "$T/rows/BH-3496.plan.json"; run
eq T11c.not-array "$OUT" "UNMEASURED BH-3496 plan unparseable"

# ============================================================================
# T0 bad arguments never reach the network
# ============================================================================
fresh; t1_rows; echo 50 > "$T/knob"
run BH-3478 BH-3478; eq T0.self "$OUT" "UNMEASURED bad arguments"
run "BH 1" BH-3478;  eq T0.space "$OUT" "UNMEASURED bad arguments"
run BH-3496 "";      eq T0.empty "$OUT" "UNMEASURED bad arguments"
eq T0.calls "$(nlines "$T/calls")" 0

# ============================================================================
# T12 empty root, nothing beside the lib -> no jobs client, nothing created
# ============================================================================
mkdir -p "$T/l12/cwd"; cp "$LIB" "$T/l12/child-plan-tripwire.sh"; : > "$T/calls"
( cd "$T/l12/cwd" && env HARNESS= H= T="$T" bash -c '
  . "$T/l12/child-plan-tripwire.sh"; cpt_check cromford BH-3496 BH-3478; echo "rc=$?"' ) > "$T/l12.out" 2>&1
eq T12.verdict "$(head -n1 "$T/l12.out")" "UNMEASURED no jobs client"
eq T12.rc "$(sed -n 2p "$T/l12.out")" rc=0
[ -z "$(ls -A "$T/l12/cwd")" ] && ok || bad "T12: files created in \$PWD: $(ls -A "$T/l12/cwd")"
# T12b: the client beside the lib is loaded lazily, caller options put back
fresh; t1_rows; echo 50 > "$T/knob"
mkdir -p "$T/h/bin/lib/jobs"; cp "$LIB" "$T/h/bin/lib/child-plan-tripwire.sh"
cp "$DIR/bin/lib/jobs/settings.sh" "$DIR/bin/lib/jobs/jobs.sh" "$T/h/bin/lib/jobs/"; : > "$T/h/bin/lib/jobs/req.sh"
printf 'set -uo pipefail\nJOBS_BOX=test-box\n%s\n. "%s/h/bin/lib/jobs/settings.sh"\n. "%s/h/bin/lib/jobs/jobs.sh"\n' \
  "$STUB" "$T" "$T" > "$T/h/bin/jobs-client.sh"
env -u HARNESS -u H T="$T" bash -c '
  set +u; set +o pipefail
  . "$T/h/bin/lib/child-plan-tripwire.sh"
  cpt_check cromford BH-3496 BH-3478
  set -o | awk '\''$1=="pipefail"||$1=="nounset"{print $1"="$2}'\''' > "$T/l12b.out" 2>&1
eq T12b.verdict "$(head -n1 "$T/l12b.out")" "FIRE 3.95 6.43 61.4 50"
grep -q '^pipefail=off$' "$T/l12b.out" && grep -q '^nounset=off$' "$T/l12b.out" && ok \
  || bad "T12b: caller shell options not restored: $(tr '\n' ' ' < "$T/l12b.out")"

# ============================================================================
# T13 sourcing defines functions only
# ============================================================================
: > "$T/calls"
bash -c 'set +u; set +o pipefail
  '"$STUB"'
  . "$1"; . "$1"
  set -o | awk '\''$1=="pipefail"||$1=="nounset"{print $1"="$2}'\''
  type -t cpt_check' _ "$LIB" > "$T/t13.out" 2>&1
eq T13.out "$(tr '\n' ' ' < "$T/t13.out")" "nounset=off pipefail=off function "
eq T13.calls "$(nlines "$T/calls")" 0

# ============================================================================
# T10 the real plan.sh hook block drives the real checker
# ============================================================================
RB=$(rb_all "$DIR" "$T/run-build.all.sh") || { echo "FAIL: rb_all"; exit 1; }
awk 'index($0, "# >>> child plan tripwire")==1 {f=1;next} index($0, "# <<< child plan tripwire")==1 {exit} f' \
  "$RB" > "$T/block.sh"
[ -s "$T/block.sh" ] && ok || bad "T10: could not extract the child plan tripwire block"
cat > "$T/drive.sh" <<EOF
set -uo pipefail
STAMP() { echo TS; }
JOBS_BOX=test-box
$STUB
. "$DIR/bin/lib/jobs/settings.sh"; . "$DIR/bin/lib/jobs/jobs.sh"
. "\$1"
echo "\$?" > "\$T/blockrc"
echo after > "\$T/after"
EOF
fresh; t1_rows; echo 50 > "$T/knob"
cp "$DIR/bin/lib/context-pack.sh" "$LIB" "$T/h/bin/lib/"
rm -rf "$T/b" "$T/after" "$T/blockrc"; mkdir -p "$T/b"; : > "$T/b/pipeline.log"
printf 'the map\n' > "$T/b/context-pack.md"; echo BH-3478 > "$T/b/context-pack.md.parent"
env -u CP_PARENT HARNESS="$T/h" PROJECT=cromford KEY=BH-3496 BUILD="$T/b" T="$T" \
  bash "$T/drive.sh" "$T/block.sh" > "$T/h.out" 2>&1
eq T10.block-rc "$(cat "$T/blockrc" 2>/dev/null)" 0
eq T10.after "$(cat "$T/after" 2>/dev/null)" after
eq T10.line "$(grep CHILD_PLAN_TRIPWIRE "$T/b/pipeline.log")" \
  "TS [cromford/BH-3496] CHILD_PLAN_TRIPWIRE FIRE 3.95 6.43 61.4 50"
eq T10.alerts "$(alerts)" 1
eq T10.puts "$(nlines "$T/ledger-puts")" 1

echo "child-plan-tripwire: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
