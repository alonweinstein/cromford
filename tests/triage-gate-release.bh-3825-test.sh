#!/bin/bash
# tests/triage-gate-release.bh-3825-test.sh — BH-3828 (slice 2 of #3825): the
# READY-QUEUE release pass, gr_release_queue in bin/lib/gate-release/queue.sh.
#
# THE INCIDENT. project-4 TK-2186 sat behind `LAUNCH-QUEUE gate: TK-2185 ...
# merged` for 1h44m after TK-2185 merged, until an operator launched it by hand.
# This pass re-reads every merge-gated queue line on each triage tick, and when
# every blocker has merged and nobody owns the key it launches run-build.sh,
# drops the line and logs GATE_RELEASED. It ships DARK: with no
# GATE_RELEASE_MAX_LAUNCHES row or env it does nothing at all (R0).
#
#   R0      fresh install (no knob) launches nothing, reads nothing
#   R1-R10  the release pass through the real bin/gate-release.sh / rt_gate
#   P1-P5   gr_parse_gate: a separator's tail must be filler, else prose
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/triage-gate-release.bh-3825-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$3] got [$2]"; fi; }
command -v jq >/dev/null 2>&1 || { echo "triage-gate-release: jq missing, cannot run" >&2; exit 1; }
command -v flock >/dev/null 2>&1 || { echo "triage-gate-release: flock missing, cannot run" >&2; exit 1; }

H="$T/h"
P=project-4
NOW=$(date +%s)
export GR_NOW="$NOW"
U=https://github.com/example-org/project-4/pull
Q="$H/logs/READY-QUEUE.log"
S="$H/state/gate-release/$P"
mkdir -p "$H/bin/lib/gate-release" "$H/state" "$H/logs" "$H/locks" "$H/flags" "$H/builds" "$H/env" "$H/fixture"
# Test-first: each file is copied only when present, so on a tree without the
# pass every release case fails on its assertion instead of crashing.
QUEUE_PART="$DIR/bin/lib/gate-release/queue.sh"
for f in "$DIR/bin/lib/gate-release.sh" "$QUEUE_PART" "$DIR/bin/lib/split-chain.sh" \
         "$DIR/bin/lib/ready-queue.sh" "$DIR/bin/lib/lock-hygiene.sh" "$DIR/bin/lib/lane-gate.sh" \
         "$DIR/bin/lib/lane-switch.sh" "$DIR/bin/lib/hub-box.sh" "$DIR/bin/lib/env-path.sh" \
         "$DIR/bin/gate-release.sh" "$DIR/bin/queue-line-drop.sh"; do
  [ -f "$f" ] && cp "$f" "$H/${f#"$DIR"/}"
done
for f in gate-release.sh queue-line-drop.sh; do [ -f "$H/bin/$f" ] && chmod +x "$H/bin/$f"; done
: > "$H/env/global.env"

# --- stubs ---------------------------------------------------------------------
cat > "$H/bin/run-build.sh" <<'SH'
#!/bin/bash
echo "$*" >> "$HARNESS/fixture/launches"
SH
cat > "$H/bin/free-slots.sh" <<'SH'
#!/bin/bash
cat "$HARNESS/fixture/slots" 2>/dev/null || echo "2 (test)"
SH
cat > "$H/bin/triage-gate.sh" <<'SH'
#!/bin/bash
if [ "${2:-}" = --buildable-strict ]; then
  echo "$3" >> "$HARNESS/fixture/buildable-asked"
  cat "$HARNESS/fixture/buildable" 2>/dev/null || echo OK
else
  echo "SKIP queue-unchanged"
fi
SH
cat > "$H/bin/project-of.sh" <<'SH'
#!/bin/bash
case "$*" in *project-4*) echo project-4 ;; *) exit 1 ;; esac
SH
cat > "$H/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$1/$2" in
  project-4/repo) echo example-org/project-4 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$H/bin/run-build.sh" "$H/bin/free-slots.sh" "$H/bin/triage-gate.sh" "$H/bin/project-of.sh" "$H/bin/fleet-conf.sh"
cat > "$H/bin/lib/pause.sh" <<'SH'
pause_active() { [ -f "$HARNESS/fixture/paused" ] && [ "$2" = builds ]; }
SH
# The ledger the driver loads from bin/jobs-client.sh: fixture/ledger-rc is its
# answer, absent = an outage (rc 1).
cat > "$H/bin/jobs-client.sh" <<'SH'
merge_ledger_has() {
  echo "$1" >> "$HARNESS/fixture/ledger"
  [ -f "$HARNESS/fixture/ledger-rc" ] || return 1
  return "$(cat "$HARNESS/fixture/ledger-rc")"
}
SH
# The REST PR-state read (the contract suite's stub verbatim).
cat > "$H/bin/lib/gh-rest.sh" <<'SH'
gh_rest_pr_state_var() {
  local _ghrv_v="$1" _ghrv_slug="$2" _ghrv_n="$3" _ghrv_st=""
  echo "$_ghrv_slug $_ghrv_n" >> "$HARNESS/fixture/gh-calls"
  if [ "$(cat "$HARNESS/fixture/gh-mode" 2>/dev/null)" = fail ]; then
    printf -v "$_ghrv_v" '%s' ""; return 75
  fi
  _ghrv_st=$(cat "$HARNESS/fixture/pr-$_ghrv_n" 2>/dev/null)
  [ -n "$_ghrv_st" ] || { printf -v "$_ghrv_v" '%s' ""; return 44; }
  printf -v "$_ghrv_v" '%s' "$_ghrv_st"; return 0
}
SH
for t in gh curl; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/fixture/calls"\nexit 22\n' "$t" "$H" > "$H/bin/$t"
  chmod +x "$H/bin/$t"
done

reset() {
  for _p in "$H/state" "$H/logs" "$H/flags" "$H/builds" "$H/fixture" "$H/locks"; do scratch_rm "$_p"; done
  mkdir -p "$H/state" "$H/logs" "$H/flags" "$H/builds" "$H/fixture" "$H/locks"
  return 0
}
res() { # res <dir-name> <line1> [mtime-epoch]
  mkdir -p "$H/builds/$1"; printf '%s\nTICKET_ID: x\n' "$2" > "$H/builds/$1/RESULT"
  [ -n "${3:-}" ] && touch -d "@$3" "$H/builds/$1/RESULT" "$H/builds/$1"
  return 0
}
merged() { res "$P-TK-2185-a1" "PR_MERGED $U/1817" $((NOW-600)); }
LINE="TK-2186 cm1x9 2026-10-01T16:00:00Z — LAUNCH-QUEUE gate: TK-2185 (PR #1817) merged to main project=$P"
queue() { printf '%s\n' "$@" > "$Q"; }
# drive [max] — the real driver as a script; max "" = no knob at all.
drive() {
  [ -f "$H/bin/gate-release.sh" ] || { echo "lib absent: bin/gate-release.sh" >&2; return 99; }
  local max="${1-2}"
  if [ -n "$max" ]; then
    env PATH="$H/bin:$PATH" HARNESS="$H" BOX_NAME=test-box JOBS_URL= GATE_RELEASE_MAX_LAUNCHES="$max" \
      bash "$H/bin/gate-release.sh" "$P"
  else
    env -u GATE_RELEASE_MAX_LAUNCHES PATH="$H/bin:$PATH" HARNESS="$H" BOX_NAME=test-box JOBS_URL= \
      bash "$H/bin/gate-release.sh" "$P"
  fi
}
# launches [want] — the spawn is backgrounded: poll up to 5 s for <want> lines,
# then print the count. want 0 waits a short beat so a late launch is caught.
launches() {
  local want="${1:-1}" i
  if [ "$want" = 0 ]; then sleep 0.5; else
    for i in $(seq 1 50); do [ "$(count "$H/fixture/launches")" -ge "$want" ] && break; sleep 0.1; done
  fi
  sleep 0.2
  count "$H/fixture/launches"
}
count() { [ -f "$1" ] && grep -c . "$1" || echo 0; }
glog() { local n; n=$(grep -c "$1" "$H/logs/$P.log" 2>/dev/null); echo "${n:-0}"; }
has() { [ -e "$1" ] && echo yes || echo no; }
parse() {
  ( export HARNESS="$H" JOBS_URL=
    [ -f "$H/bin/lib/gate-release.sh" ] || exit 99
    . "$H/bin/lib/gate-release.sh"; gr_parse_gate "$1" )
}
norm_sha() { printf '%s' "$1" | sed -E 's/20[0-9]{2}-[0-9]{2}-[0-9]{2}[T ][0-9:.]{5,12}Z?//g' | sha256sum | awk '{print $1}'; }

# --- R0: a fresh install is dark ------------------------------------------------------
reset; merged; queue "$LINE"; cp "$Q" "$T/q0"
out=$(drive ""); rc=$?
eq "R0 rc" "$rc" 0
eq "R0 driver silent" "$out" ""
eq "R0 no launch" "$(launches 0)" 0
eq "R0 queue byte-identical" "$(cmp -s "$Q" "$T/q0" && echo same || echo changed)" same
eq "R0 no released dir" "$(has "$S/released")" no
eq "R0 no gh calls" "$(count "$H/fixture/gh-calls")" 0
eq "R0 no ledger calls" "$(count "$H/fixture/ledger")" 0
eq "R0 no GATE_RELEASED" "$(glog GATE_RELEASED)" 0
eq "R0 registry default is 0" \
  "$(jq '.libs[]|select(.id=="gate-release").knobs[]|select(.env=="GATE_RELEASE_MAX_LAUNCHES").default' "$DIR/catalog/lanes.d/_lib.json")" 0
# global.env carrying the knob turns it on for one box
reset; merged; queue "$LINE"; echo GATE_RELEASE_MAX_LAUNCHES=1 > "$H/env/global.env"
out=$(drive ""); eq "R0 env row turns it on" "$(launches 1)" 1
: > "$H/env/global.env"

# --- R1: the incident line, released once ---------------------------------------------
reset; merged; queue "$LINE"
out=$(drive); rc=$?
eq "R1 rc" "$rc" 0
eq "R1 summary" "$out" "gate-release $P: 1 action(s)"
eq "R1 one launch" "$(launches 1)" 1
eq "R1 launch args" "$(cat "$H/fixture/launches" 2>/dev/null)" "$P cm1x9 TK-2186"
eq "R1 line dropped" "$(grep -c '^TK-2186 ' "$Q" 2>/dev/null || true)" 0
eq "R1 GATE_RELEASED logged" "$(glog 'GATE_RELEASED TK-2186: TK-2185 merged (#1817)$')" 1
eq "R1 log line shape" "$(grep -cE "^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}Z \[$P\] GATE_RELEASED TK-2186" "$H/logs/$P.log" 2>/dev/null || true)" 1
eq "R1 marker holds the line sha" "$(cat "$S/released/TK-2186" 2>/dev/null)" "$(norm_sha "$LINE")"
eq "R1 build-out file" "$(has "$H/logs/$P.TK-2186-gate-release.out")" yes

# --- R2: the same line again (new stamp) does not launch twice ------------------------
queue "${LINE/16:00:00Z/18:30:00Z}"
out=$(drive); rc=$?
eq "R2 still one launch" "$(launches 0)" 1
eq "R2 silent" "$out" ""
eq "R2 line kept" "$(grep -c '^TK-2186 ' "$Q")" 1

# --- R3: ledger tier merged -> launch; ledger outage + REST open -> no launch ----------
reset; res "$P-TK-2185-c1" "PR_CREATED $U/1817"; echo 0 > "$H/fixture/ledger-rc"; queue "$LINE"
drive >/dev/null
eq "R3 ledger merged launches" "$(launches 1)" 1
eq "R3 ledger asked with the url" "$(cat "$H/fixture/ledger" 2>/dev/null)" "$U/1817"
reset; res "$P-TK-2185-c1" "PR_CREATED $U/1817"; echo 1 > "$H/fixture/ledger-rc"; echo open > "$H/fixture/pr-1817"; queue "$LINE"
drive >/dev/null
eq "R3 open PR: no launch" "$(launches 0)" 0
eq "R3 open PR: line kept" "$(grep -c '^TK-2186 ' "$Q")" 1
eq "R3 open PR: one REST read" "$(count "$H/fixture/gh-calls")" 1
eq "R3 open PR: no released marker" "$(has "$S/released/TK-2186")" no

# --- R4: no evidence at all -------------------------------------------------------------
reset; queue "$LINE"
drive >/dev/null
eq "R4 no launch" "$(launches 0)" 0
eq "R4 line kept" "$(grep -c '^TK-2186 ' "$Q")" 1
eq "R4 no log line" "$(glog GATE_)" 0

# --- R5: a prose gate is untouched and silent -------------------------------------------
reset; merged; queue "TK-2186 cm1x9 — gate: TK-2185 merged and Claudia approves project=$P"; cp "$Q" "$T/q5"
out=$(drive)
eq "R5 no launch" "$(launches 0)" 0
eq "R5 queue byte-identical" "$(cmp -s "$Q" "$T/q5" && echo same || echo changed)" same
eq "R5 no state files" "$(find "$H/state/gate-release" -type f 2>/dev/null | wc -l)" 0
eq "R5 empty log" "$(cat "$H/logs/$P.log" 2>/dev/null)" ""
eq "R5 driver silent" "$out" ""

# --- R6: every blocker must have merged ---------------------------------------------------
L6="TK-2186 cm1x9 — gate: TK-2185 and TK-2190 merged project=$P"
reset; merged; queue "$L6"
drive >/dev/null
eq "R6 one of two merged: no launch" "$(launches 0)" 0
eq "R6 line kept" "$(grep -c '^TK-2186 ' "$Q")" 1
mkdir -p "$H/state/split-chain/$P/merged"; : > "$H/state/split-chain/$P/merged/TK-2190"
drive >/dev/null
eq "R6 both merged: one launch" "$(launches 1)" 1
eq "R6 log joins blockers" "$(glog 'GATE_RELEASED TK-2186: TK-2185 merged (#1817), TK-2190 merged$')" 1

# --- R7: every owner check fails closed ---------------------------------------------------
kept() { eq "R7 $1: no launch" "$(launches 0)" 0; eq "R7 $1: line kept" "$(grep -c '^TK-2186 ' "$Q")" 1; }
reset; merged; queue "$LINE"; touch "$H/fixture/paused"; drive >/dev/null; kept "builds pause"

reset; merged; queue "$LINE"
LK="$H/locks/build-key-$P-TK-2186.lock"
( exec 7>"$LK"; flock -n 7 && exec sleep 30 ) & HOLDER=$!
for _ in $(seq 1 50); do ( flock -n 7 ) 7>"$LK" 2>/dev/null || break; sleep 0.1; done
drive >/dev/null; kept "build-key lock held"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null

reset; merged; queue "$LINE"; mkdir -p "$H/builds/$P-TK-2186-fly"; drive >/dev/null; kept "INFLIGHT"

reset; merged; queue "$LINE"; res "$P-TK-2186-b1" "PR_CREATED $U/1900"
drive >/dev/null; drive >/dev/null; kept "PR_CREATED owner"
eq "R7 PR_CREATED: SKIP logged once" "$(glog 'GATE_RELEASE_SKIP TK-2186: PR_CREATED already owns it')" 1

reset; merged; queue "$LINE"; echo "BLOCKED waiting-on-client" > "$H/fixture/buildable"; drive >/dev/null; kept "buildable-strict BLOCKED"
eq "R7 buildable-strict asked with the ticket id" "$(cat "$H/fixture/buildable-asked" 2>/dev/null)" cm1x9

reset; merged; queue "$LINE"; echo '{"TK-2100":"zz1"}' > "$H/state/$P.keymap.json"
drive >/dev/null; drive >/dev/null; kept "closed ticket"
eq "R7 closed: logged once" "$(glog 'GATE_RELEASE_SKIP TK-2186: ticket closed')" 1

reset; merged; queue "$LINE"; echo "0 (busy)" > "$H/fixture/slots"
drive >/dev/null; drive >/dev/null; kept "no free slot"
eq "R7 WAIT once inside the window" "$(glog 'GATE_RELEASE_WAIT TK-2186: no free slot')" 1
touch -d "@$((NOW-21601))" "$S/wait/TK-2186"
drive >/dev/null
eq "R7 WAIT again past the window" "$(glog 'GATE_RELEASE_WAIT TK-2186: no free slot')" 2
eq "R7 no free slot: no marker" "$(has "$S/released/TK-2186")" no

reset; merged
queue "$LINE" "${LINE/TK-2186 cm1x9/TK-2187 cm1x8}" "${LINE/TK-2186 cm1x9/TK-2188 cm1x7}"
out=$(drive)
eq "R7 cap: two launches" "$(launches 2)" 2
eq "R7 cap: third line kept" "$(grep -c '^TK-2188 ' "$Q")" 1
eq "R7 cap: summary counts two" "$out" "gate-release $P: 2 action(s)"
drive >/dev/null
eq "R7 cap: third released next pass" "$(launches 3)" 3

# --- R8: PLAN_BLOCKED (and COMMENTED) is not an owner ---------------------------------------
reset; merged; queue "$LINE"; res "$P-TK-2186-p1" "PLAN_BLOCKED waiting on TK-2185"; touch "$H/builds/$P-TK-2186-p1/COMMENTED"
drive >/dev/null
eq "R8 PLAN_BLOCKED released" "$(launches 1)" 1

# --- R9: the kill switch --------------------------------------------------------------------
reset; merged; queue "$LINE"; cp "$Q" "$T/q9"; touch "$H/flags/gate-release-off"
out=$(drive)
eq "R9 no launch" "$(launches 0)" 0
eq "R9 queue byte-identical" "$(cmp -s "$Q" "$T/q9" && echo same || echo changed)" same
eq "R9 no gh calls" "$(count "$H/fixture/gh-calls")" 0
eq "R9 silent" "$out" ""

# --- R10: the real rt_gate call site releases even when triage-gate says SKIP ---------------
reset; merged; queue "$LINE"
( export PATH="$H/bin:$PATH" HARNESS="$H" BOX_NAME=test-box JOBS_URL= GATE_RELEASE_MAX_LAUNCHES=2
  PROJECT="$P" ORPHAN_RECONCILE=0
  . "$DIR/bin/lib/rt/gate.sh"
  rt_gate_pat_note_alert() { echo reached >> "$H/fixture/cost-gate"; exit 0; }
  rt_gate ) >/dev/null 2>&1
eq "R10 rt_gate launched" "$(launches 1)" 1
eq "R10 line dropped" "$(grep -c '^TK-2186 ' "$Q" 2>/dev/null || true)" 0
eq "R10 cost gate still reached" "$(cat "$H/fixture/cost-gate" 2>/dev/null)" reached
eq "R10 triage-gate says SKIP" "$("$H/bin/triage-gate.sh" "$P")" "SKIP queue-unchanged"

# --- P: a separator's tail must be filler, else the whole line is prose ----------------------
while IFS='|' read -r name line; do
  out=$(parse "$line"); rc=$?
  eq "$name rc" "$rc" 1; eq "$name stdout" "$out" ""
done <<'EOF'
P1 client step after ;|TK-2186 gate: TK-2185 merged; then QA by the client
P2 second key after ;|TK-2186 gate: TK-2185 merged; TK-2190 merged
P2 own key after em dash|TK-2186 gate: TK-2185 merged — TK-2186
P5 dotted key|TK-2186 gate: BH-3825.0 merged
EOF
out=$(parse 'TK-2186 gate: TK-2185,TK-2190 merged | note'); rc=$?
eq "P3 pipe note rc" "$rc" 1; eq "P3 pipe note stdout" "$out" ""
out=$(parse "TK-2186 gate: TK-2185 merged — 2026-10-01T16:03Z project=$P"); rc=$?
eq "P4 stamp tail rc" "$rc" 0; eq "P4 stamp tail keys" "$out" "TK-2185"
out=$(parse "TK-2186 gate: TK-2185 merged; (PR #1817) merged to main"); rc=$?
eq "P4 vocabulary tail rc" "$rc" 0; eq "P4 vocabulary tail keys" "$out" "TK-2185"
out=$(parse "TK-2186 gate: TK-2185 merged project=$P — 2026-10-01"); rc=$?
eq "P4 project token mid-line rc" "$rc" 0
# P1 through the pass: TK-2185 merged and the line is still never released.
reset; merged; queue "TK-2186 cm1x9 — gate: TK-2185 merged; then QA by the client project=$P"; cp "$Q" "$T/qp"
drive >/dev/null
eq "P1 pass: no launch" "$(launches 0)" 0
eq "P1 pass: queue byte-identical" "$(cmp -s "$Q" "$T/qp" && echo same || echo changed)" same

echo "triage-gate-release: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
