#!/bin/bash
# tests/gate-release-contract.bh-3825-test.sh — BH-3827 (slice 1 of #3825): the
# gate-release contract the three sibling slices import.
#
# THE INCIDENT. project-4 TK-2186 came back PLAN_BLOCKED on TK-2185. TK-2185
# merged at 16:03Z and nothing re-launched TK-2186: the `LAUNCH-QUEUE gate:
# TK-2185 ... merged` line was never re-read. This slice lands the shared
# pieces: the gate grammar, the "has KEY merged?" truth and an inert driver.
#
# What this suite drives, all REAL code against a scratch harness:
#   C1/C2  gr_parse_gate accepts merge gates, refuses prose gates
#   C3     gr_key_merged tiers (a) RESULT, (b) ledger, (c) split-chain REST
#   C4     bin/gate-release.sh run as a script (kill switch, hub, parts)
#   H*     gr_newest_result, gr_ticket_id, gr_state_dir, `set -u` sourcing
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/gate-release-contract.bh-3825-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$3] got [$2]"; fi; }
command -v jq >/dev/null 2>&1 || { echo "gate-release: jq missing, cannot run" >&2; exit 1; }

H="$T/h"
P=project-4
NOW=$(date +%s)
TAB=$(printf '\t')
mkdir -p "$H/bin/lib" "$H/state" "$H/logs" "$H/locks" "$H/flags" "$H/builds" "$H/env" "$H/fixture"
# Test-first: each file is copied only when present, so on a tree without the
# feature every case fails with "lib absent" instead of crashing.
for f in "$DIR/bin/lib/gate-release.sh" "$DIR/bin/lib/split-chain.sh" "$DIR/bin/lib/lane-switch.sh" \
         "$DIR/bin/lib/lane-gate.sh" "$DIR/bin/lib/hub-box.sh" "$DIR/bin/lib/env-path.sh" "$DIR/bin/gate-release.sh"; do
  [ -f "$f" ] && cp "$f" "$H/${f#"$DIR"/}"
done
[ -f "$H/bin/gate-release.sh" ] && chmod +x "$H/bin/gate-release.sh"
: > "$H/env/global.env"

# --- stubs ---------------------------------------------------------------------
cat > "$H/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$1/$2" in
  project-4/repo) echo example-org/project-4 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$H/bin/fleet-conf.sh"
# The REST contract's PR-state read (the split-chain stub verbatim): every call
# is counted in fixture/gh-calls, the answer is fixture/pr-<n>.
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
# Any network tool a pass reaches for is recorded and refused.
for t in gh curl; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/fixture/calls"\nexit 22\n' "$t" "$H" > "$H/bin/$t"
  chmod +x "$H/bin/$t"
done

reset() {
  for _p in "$H/state" "$H/logs" "$H/flags" "$H/builds" "$H/fixture" "$H/bin/lib/gate-release"; do scratch_rm "$_p"; done
  mkdir -p "$H/state" "$H/logs" "$H/flags" "$H/builds" "$H/fixture"
  return 0
}
# res <dir-name> <line1> [mtime-epoch] — a finished build record.
res() {
  mkdir -p "$H/builds/$1"; printf '%s\nTICKET_ID: x\n' "$2" > "$H/builds/$1/RESULT"
  [ -n "${3:-}" ] && touch -d "@$3" "$H/builds/$1/RESULT" "$H/builds/$1"
  return 0
}
# gr <fn> <args...> — call a lib function in a fresh shell, the way a sibling
# sources it. fixture/ledger-rc present = a merge_ledger_has stub answering it.
gr() {
  ( export HARNESS="$H" BOX_NAME=test-box JOBS_URL=
    [ -f "$H/bin/lib/gate-release.sh" ] || { echo "lib absent: bin/lib/gate-release.sh" >&2; exit 99; }
    . "$H/bin/lib/gate-release.sh"
    if [ -f "$H/fixture/ledger-rc" ]; then
      merge_ledger_has() { echo "$1" >> "$H/fixture/ledger"; return "$(cat "$H/fixture/ledger-rc")"; }
    fi
    "$@" )
}
count() { [ -f "$1" ] && grep -c . "$1" || echo 0; }
mt() { stat -c %Y "$1" 2>/dev/null || echo none; }

# --- C1: accepted merge gates ---------------------------------------------------
out=$(gr gr_parse_gate 'LAUNCH-QUEUE gate: TK-2185 (PR #1817) merged to main project=project-4'); rc=$?
eq "C1 queue gate rc" "$rc" 0
eq "C1 queue gate keys" "$out" "TK-2185"
out=$(gr gr_parse_gate 'TK-2186 gate: TK-2185 and TK-2190 merged'); rc=$?
eq "C1 two keys rc" "$rc" 0
eq "C1 two keys" "$out" "TK-2185
TK-2190"
out=$(gr gr_parse_gate 'TK-2186 GATE: TK-2185 merged'); rc=$?
eq "C1 upper GATE: rc" "$rc" 0; eq "C1 upper GATE: keys" "$out" "TK-2185"
# A separator's tail must be filler (the operator, 2026-10-02 on BH-3828): a client
# step or any other word after `;`, ` — ` or ` | ` makes the whole line prose.
out=$(gr gr_parse_gate 'TK-2186 Gate: TK-2185 merged; then QA by the client'); rc=$?
eq "C1 ; client step is prose rc" "$rc" 1; eq "C1 ; client step is prose stdout" "$out" ""
out=$(gr gr_parse_gate 'TK-2186 gate: TK-2185 merged — then the client reviews'); rc=$?
eq "C1 em dash client step is prose rc" "$rc" 1; eq "C1 em dash client step stdout" "$out" ""
out=$(gr gr_parse_gate 'TK-2186 gate: TK-2185,TK-2190 merged | note'); rc=$?
eq "C1 comma + pipe note is prose rc" "$rc" 1; eq "C1 comma + pipe note stdout" "$out" ""
out=$(gr gr_parse_gate 'TK-2186 gate: TK-2185 and TK-2185 merged'); rc=$?
eq "C1 duplicate printed once" "$out" "TK-2185"

# --- C2: prose gates are refused (rc 1, nothing printed) ------------------------
while IFS= read -r line; do
  out=$(gr gr_parse_gate "$line"); rc=$?
  eq "C2 rc [$line]" "$rc" 1
  eq "C2 stdout [$line]" "$out" ""
done <<'EOF'
gate: TK-2185 merged and the client confirms copy
TK-2185 merged and Claudia approves
TK-2186 LAUNCH-QUEUE gate: TK-2186 merged
TK-2186 gate: TK-2186 merged
gate: PR #1817 merged
gate: TK-2185 approved
gate: TK-2185 lands
TK-2186 waiting on TK-2185 merged to main
gate: TK-2185's PR merged
gate: TK-2185 merged
EOF

# --- C3: gr_key_merged -----------------------------------------------------------
U=https://github.com/example-org/project-4/pull
# (a) PR_MERGED, box layout and pool layout; merged_at = RESULT mtime.
reset; res "$P-TK-2185-a1" "PR_MERGED $U/1817" $((NOW-600))
out=$(gr gr_key_merged "$H" "$P" TK-2185); rc=$?
eq "C3a box rc" "$rc" 0; eq "C3a box out" "$out" "1817${TAB}$((NOW-600))"
reset; res "pool-$P-TK-2185-a1" "PR_MERGED $U/1818?x=1" $((NOW-900))
out=$(gr gr_key_merged "$H" "$P" TK-2185); rc=$?
eq "C3a pool rc" "$rc" 0; eq "C3a pool out" "$out" "1818${TAB}$((NOW-900))"
# TK-20 never matches TK-202's dirs.
reset; res "$P-TK-21850-a1" "PR_MERGED $U/1817"
out=$(gr gr_key_merged "$H" "$P" TK-2185); rc=$?
eq "C3a longer key is not this key" "$rc" 1

# (b) ledger hit on the newest PR_CREATED: cache written, no REST read.
reset; res "$P-TK-2185-b1" "PR_CREATED $U/1817"; echo 0 > "$H/fixture/ledger-rc"
out=$(gr gr_key_merged "$H" "$P" TK-2185); rc=$?
C="$H/state/split-chain/$P/merged/TK-2185"
eq "C3b rc" "$rc" 0
eq "C3b out" "$out" "1817${TAB}$(mt "$C")"
eq "C3b cache holds the PR" "$(cat "$C" 2>/dev/null)" "1817"
eq "C3b ledger asked with the url" "$(cat "$H/fixture/ledger" 2>/dev/null)" "$U/1817"
eq "C3b no REST read" "$(count "$H/fixture/gh-calls")" 0
# the cache answers the next call with no ledger and no REST
out=$(gr gr_key_merged "$H" "$P" TK-2185); rc=$?
eq "C3b cached rc" "$rc" 0; eq "C3b cached: no 2nd ledger call" "$(count "$H/fixture/ledger")" 1

# (c-miss) ledger real miss, REST open -> not merged, nothing cached, one read.
reset; res "$P-TK-2185-c1" "PR_CREATED $U/1817"; echo 2 > "$H/fixture/ledger-rc"; echo open > "$H/fixture/pr-1817"
out=$(gr gr_key_merged "$H" "$P" TK-2185); rc=$?
eq "C3c-miss rc" "$rc" 1; eq "C3c-miss stdout" "$out" ""
eq "C3c-miss no cache" "$([ -e "$H/state/split-chain/$P/merged/TK-2185" ] && echo yes || echo no)" no
eq "C3c-miss one REST read" "$(count "$H/fixture/gh-calls")" 1

# (c-hit) ledger outage, REST merged -> merged and cached.
reset; res "$P-TK-2185-c1" "PR_CREATED $U/1817"; echo 1 > "$H/fixture/ledger-rc"; echo merged > "$H/fixture/pr-1817"
out=$(gr gr_key_merged "$H" "$P" TK-2185); rc=$?
eq "C3c-hit rc" "$rc" 0
eq "C3c-hit out" "$out" "1817${TAB}$(mt "$C")"
eq "C3c-hit cached" "$(cat "$C" 2>/dev/null)" "1817"

# closed is not merged
reset; res "$P-TK-2185-c1" "PR_CREATED $U/1817"; echo 2 > "$H/fixture/ledger-rc"; echo closed > "$H/fixture/pr-1817"
out=$(gr gr_key_merged "$H" "$P" TK-2185); rc=$?
eq "C3 closed rc" "$rc" 1; eq "C3 closed stdout" "$out" ""
# REST rate limited is not merged
reset; res "$P-TK-2185-c1" "PR_CREATED $U/1817"; echo 1 > "$H/fixture/ledger-rc"; echo fail > "$H/fixture/gh-mode"
out=$(gr gr_key_merged "$H" "$P" TK-2185); rc=$?
eq "C3 REST outage rc" "$rc" 1
eq "C3 REST outage no cache" "$([ -e "$C" ] && echo yes || echo no)" no

# foreign repo: zero ledger and zero REST calls
reset; res "$P-TK-2185-c1" "PR_CREATED https://github.com/Other/repo/pull/1817"
echo 0 > "$H/fixture/ledger-rc"; echo merged > "$H/fixture/pr-1817"
out=$(gr gr_key_merged "$H" "$P" TK-2185); rc=$?
eq "C3 foreign rc" "$rc" 1
eq "C3 foreign ledger calls" "$(count "$H/fixture/ledger")" 0
eq "C3 foreign REST calls" "$(count "$H/fixture/gh-calls")" 0

# no build dir at all
reset; echo 0 > "$H/fixture/ledger-rc"
out=$(gr gr_key_merged "$H" "$P" TK-2185); rc=$?
eq "C3 no evidence rc" "$rc" 1; eq "C3 no evidence stdout" "$out" ""

# GATE_RELEASE_MAX_LOOKUPS=0: no REST read at all
reset; res "$P-TK-2185-c1" "PR_CREATED $U/1817"; echo merged > "$H/fixture/pr-1817"
out=$(GATE_RELEASE_MAX_LOOKUPS=0 gr gr_key_merged "$H" "$P" TK-2185); rc=$?
eq "C3 cap 0 rc" "$rc" 1
eq "C3 cap 0 REST calls" "$(count "$H/fixture/gh-calls")" 0
# ... and the same fixture with the default cap does read (the cap is what stopped it)
out=$(gr gr_key_merged "$H" "$P" TK-2185); rc=$?
eq "C3 default cap reads" "$rc" 0

# Mutation guard (D1): tier (a) wins over (b), with zero ledger calls.
reset; res "$P-TK-2185-m1" "PR_MERGED $U/1817" $((NOW-1200)); res "$P-TK-2185-m2" "PR_CREATED $U/1900" $((NOW-60))
echo 0 > "$H/fixture/ledger-rc"
out=$(gr gr_key_merged "$H" "$P" TK-2185); rc=$?
eq "C3 a-before-b rc" "$rc" 0
eq "C3 a-before-b out" "$out" "1817${TAB}$((NOW-1200))"
eq "C3 a-before-b ledger calls" "$(count "$H/fixture/ledger")" 0
# ... and tier (a) answers before the cache: the RESULT's PR and mtime, not the cache's.
mkdir -p "$H/state/split-chain/$P/merged"; echo 1999 > "$C"
out=$(gr gr_key_merged "$H" "$P" TK-2185); rc=$?
eq "C3 a-before-cache out" "$out" "1817${TAB}$((NOW-1200))"

# --- C4: the driver, run as a script ----------------------------------------------
drive() { # drive [BOX_NAME] — prints stdout, returns the driver's rc
  [ -f "$H/bin/gate-release.sh" ] || { echo "lib absent: bin/gate-release.sh" >&2; return 99; }
  PATH="$H/bin:$PATH" HARNESS="$H" BOX_NAME="${1:-test-box}" JOBS_URL= bash "$H/bin/gate-release.sh" "$P"
}
part() { # a sibling part file whose work reaches the network and prints one action
  mkdir -p "$H/bin/lib/gate-release"
  cat > "$H/bin/lib/gate-release/zz.sh" <<'SH'
gr_release_queue() { gh api repos/x >/dev/null 2>&1; merge_ledger_has u >/dev/null 2>&1; echo "GATE_RELEASED X"; }
SH
}
# no part files: silent, rc 0
reset
out=$(drive); rc=$?
eq "C4 no parts rc" "$rc" 0; eq "C4 no parts silent" "$out" ""
eq "C4 no parts no calls" "$(count "$H/fixture/calls")" 0
# a part file: auto-sourced, exactly one summary line
reset; part
out=$(drive); rc=$?
eq "C4 part rc" "$rc" 0
eq "C4 part summary" "$out" "gate-release $P: 1 action(s)"
eq "C4 part ran (its gh call is recorded)" "$(count "$H/fixture/calls")" 1
# kill switch: same part file, nothing runs, nothing read
reset; part; touch "$H/flags/gate-release-off"
out=$(drive); rc=$?
eq "C4 off rc" "$rc" 0; eq "C4 off silent" "$out" ""
for f in calls gh-calls ledger; do
  eq "C4 off: fixture/$f absent" "$([ -e "$H/fixture/$f" ] && echo present || echo absent)" absent
done
# the hub runs no gate-release
reset; part
out=$(drive box-hub); rc=$?
eq "C4 hub rc" "$rc" 0; eq "C4 hub silent" "$out" ""
eq "C4 hub no calls" "$(count "$H/fixture/calls")" 0
# no project: rc 0, silent
out=$(PATH="$H/bin:$PATH" HARNESS="$H" bash "$H/bin/gate-release.sh" 2>&1); rc=$?
eq "C4 no project rc" "$rc" 0; eq "C4 no project silent" "$out" ""

# --- C4r: rt_gate (bin/lib/rt/gate.sh, the real call site) runs the driver before
# the cost gate. rt_gate_pat_note_alert is the next statement after the free
# block, so the stub stops the stage there.
R="$T/rt"; mkdir -p "$R/bin"
printf '#!/bin/bash\necho "$1" >> "%s/driver-ran"\n' "$R" > "$R/bin/gate-release.sh"; chmod +x "$R/bin/gate-release.sh"
( HARNESS="$R" PROJECT="$P" ORPHAN_RECONCILE=0
  . "$DIR/bin/lib/rt/gate.sh"
  rt_gate_pat_note_alert() { echo reached >> "$R/cost-gate"; exit 0; }
  rt_gate ) >/dev/null 2>&1
eq "C4r rt_gate ran the driver for the project" "$(cat "$R/driver-ran" 2>/dev/null)" "$P"
eq "C4r ... before the cost gate" "$(cat "$R/cost-gate" 2>/dev/null)" reached
# a tree without the driver: rt_gate carries on to the cost gate
rm -f "$R/bin/gate-release.sh" "$R/cost-gate"
( HARNESS="$R" PROJECT="$P" ORPHAN_RECONCILE=0
  . "$DIR/bin/lib/rt/gate.sh"
  rt_gate_pat_note_alert() { echo reached >> "$R/cost-gate"; exit 0; }
  rt_gate ) >/dev/null 2>&1
eq "C4r no driver: cost gate still reached" "$(cat "$R/cost-gate" 2>/dev/null)" reached

# --- helpers ------------------------------------------------------------------------
reset
res "$P-TK-2185-old" "PR_CREATED $U/1817" $((NOW-3600))
res "$P-TK-2185-new" "PLAN_BLOCKED waiting on TK-2100" $((NOW-60))
out=$(gr gr_newest_result "$H" "$P" TK-2185); rc=$?
eq "H newest rc" "$rc" 0
eq "H newest" "$out" "$H/builds/$P-TK-2185-new${TAB}PLAN_BLOCKED waiting on TK-2100"
mkdir -p "$H/builds/pool-$P-TK-2185-fly"
out=$(gr gr_newest_result "$H" "$P" TK-2185); rc=$?
eq "H newest inflight" "$out" "$H/builds/pool-$P-TK-2185-fly${TAB}INFLIGHT"
out=$(gr gr_newest_result "$H" "$P" TK-9999); rc=$?
eq "H newest none rc" "$rc" 1; eq "H newest none stdout" "$out" ""

out=$(gr gr_ticket_id "$H" "$P" TK-2185 3825); rc=$?
eq "H ticket fallback numeric rc" "$rc" 0; eq "H ticket fallback numeric" "$out" 3825
out=$(gr gr_ticket_id "$H" "$P" TK-2185 HOLD); rc=$?
eq "H ticket fallback HOLD refused" "$rc" 1; eq "H ticket HOLD stdout" "$out" ""
out=$(gr gr_ticket_id "$H" "$P" TK-2185 'a b'); rc=$?
eq "H ticket fallback with space refused" "$rc" 1
out=$(gr gr_ticket_id "$H" "$P" TK-2185); rc=$?
eq "H ticket no keymap no fallback" "$rc" 1
echo '{"TK-2185":"cm1x9","cm1x9":"TK-2185"}' > "$H/state/$P.keymap.json"
out=$(gr gr_ticket_id "$H" "$P" TK-2185 3825); rc=$?
eq "H ticket keymap rc" "$rc" 0; eq "H ticket keymap id" "$out" cm1x9
out=$(gr gr_ticket_id "$H" "$P" TK-2190 3825); rc=$?
eq "H ticket closed rc" "$rc" 1; eq "H ticket closed stdout" "$out" ""
echo 'not json' > "$H/state/$P.keymap.json"
out=$(gr gr_ticket_id "$H" "$P" TK-2185 3825); rc=$?
eq "H ticket junk keymap -> fallback" "$out" 3825

out=$(gr gr_state_dir "$H" "$P"); rc=$?
eq "H state dir rc" "$rc" 0; eq "H state dir path" "$out" "$H/state/gate-release/$P"
eq "H state dir exists" "$([ -d "$H/state/gate-release/$P" ] && echo yes || echo no)" yes

# set -u sourcing, twice (idempotent)
if [ -f "$H/bin/lib/gate-release.sh" ]; then
  HARNESS="$H" bash -c 'set -u; . "$1"; . "$1"; declare -F gr_key_merged split_chain_key_merged >/dev/null' _ "$H/bin/lib/gate-release.sh"
  eq "H set -u source rc" "$?" 0
else
  bad "H set -u source: lib absent"
fi

echo "gate-release-contract: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
