#!/bin/bash
# tests/switch-convert-sweepers.bh-2444-test.sh — BH-2444 (BH-2408.4): six
# sweeper and metrics kill switches read through lane_switch, so a
# `switch.<name>` settings row decides before flags/<name> does.
#
#   site 1  bin/main-red-pr-pair.sh      main-red-pr-pair-off      (file mode)
#   site 2  bin/lib/orc-account.sh       orc-account-routing-off   (file mode)
#   site 3  bin/orphan-reconcile.sh      orphan-reconcile-off      (file mode)
#   site 4  bin/orphan-reconcile.sh      pr-owner-sweep-off        (file mode)
#   site 5  bin/outcome-metrics.sh       outcome-metrics-disabled  (flag mode)
#   site 6  bin/overlap-guard.sh         overlap-guard-off         (file mode)
#
# Each case runs the REAL script (or sources the real lib) copied into a fresh
# scratch harness from tests/lib/switch-convert-fixture.sh, and observes rc,
# stdout, the bash -x trace or a stub's call log — never the source text, except
# the registry checks C1/O1/X1, which are about the source by definition.
#   Rk  row switch.<n>=1, no file          -> the site is switched off
#   Fk  row switch.<n>=0 + flags/<n>       -> the site runs, one `ignored` line
#   Lk  no rows                            -> the file alone decides, as before
#   L23 no rows, client loaded             -> outcome-metrics reads the pause_flags row (BH-2412)
#   Mk  no rows, flag_active loaded        -> a file-mode site never asks it
#   N1  row switch.overlap-guard-off-proj=1 trips no project
#   N2  flags/overlap-guard-off-proj stops proj only (line 96 stays a file read)
#   G1  an unreadable row value is no row, the site runs
#   C1  every lane_switch literal in the five files has its catalog file
#   O1  each file's lowest lane_switch literal is in [g-o] (the slice's range)
#   X1  no code writes or removes any of the six switch files
# Run from anywhere: tests/switch-convert-sweepers.bh-2444-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/switch-convert-fixture.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

sc_stub_path "$T/stub"
export LANE_GATE_LOG_EVERY_S=0

MRP="$DIR/bin/main-red-pr-pair.sh"
ORC="$DIR/bin/lib/orc-account.sh"
ORR="$DIR/bin/orphan-reconcile.sh"
OMS="$DIR/bin/outcome-metrics.sh"
OVG="$DIR/bin/overlap-guard.sh"
FILES="bin/main-red-pr-pair.sh bin/lib/orc-account.sh bin/orphan-reconcile.sh bin/outcome-metrics.sh bin/overlap-guard.sh"
NAMES="main-red-pr-pair-off orc-account-routing-off orphan-reconcile-off pr-owner-sweep-off outcome-metrics-disabled overlap-guard-off"

# next_line <script> <ere> — the line number of the first code line matching
# <ere>: the command the script runs right after a switch read.
next_line() { grep -nE "$2" "$1" | grep -vE '^[0-9]+:[[:space:]]*#' | head -1 | cut -d: -f1; }
# The trace is observed at that exact line, not with sc_trace_past: every
# lane_switch read runs lane-gate.sh functions whose own LINENOs (600+) land in
# the same trace, so "any line past N" is true of a script that stopped at N.
N1=$(next_line "$MRP" '^command -v gh ')
N3=$(next_line "$ORR" '^GRACE_MIN=')
N5=$(next_line "$OMS" '^if command -v flock ')
N6=$(next_line "$OVG" '^\[ -e "\$HARNESS/flags/overlap-guard-off-\$PROJECT" \]')
N96=$(next_line "$OVG" '^command -v jq ')
for v in N1 N3 N5 N6 N96; do
  [ -n "${!v}" ] && ok || bad "setup: could not locate the $v line"
done

# fresh <k> [rows...] — a new scratch harness with the rows written.
FRESH_N=0
fresh() { local k="$1"; shift; FRESH_N=$((FRESH_N + 1)); sc_harness "$T/h$k-$FRESH_N" || exit 1; sc_rows "$@"; : > "$CALLS"; }

# ran <trace> <line> <text> — rc 0 when the script executed <line> (its own
# number and its own text), rc 1 when it stopped before it, rc 2 on no trace.
ran() { [ -s "$1" ] || return 2; grep -qE "^\++$2: $3" "$1"; }

# ---------- site 1: main-red-pr-pair ------------------------------------------
run1() { cp "$MRP" "$SC_ROOT/bin/"; HARNESS="$SC_ROOT" sc_trace "$T/tr1" "$SC_ROOT/bin/main-red-pr-pair.sh" >/dev/null 2>&1; }
fresh 1 switch.main-red-pr-pair-off=1; run1; ran "$T/tr1" "$N1" "command -v gh"; r=$?
[ "$r" = 1 ] && ok || bad "R1 switch.main-red-pr-pair-off=1 must stop main-red-pr-pair before :$N1 (ran rc $r)"
fresh 1 switch.main-red-pr-pair-off=0; touch "$SC_ROOT/flags/main-red-pr-pair-off"; run1; ran "$T/tr1" "$N1" "command -v gh"; r=$?
[ "$r" = 0 ] && ok || bad "F1 switch.main-red-pr-pair-off=0 must beat flags/main-red-pr-pair-off (ran rc $r)"
[ "$(sc_ignored_lines "$SC_ROOT" main-red-pr-pair-off)" = 1 ] && ok || bad "F1 want one 'flags/main-red-pr-pair-off ignored' line, got $(sc_ignored_lines "$SC_ROOT" main-red-pr-pair-off)"
fresh 1; touch "$SC_ROOT/flags/main-red-pr-pair-off"; run1; ran "$T/tr1" "$N1" "command -v gh"; r=$?
[ "$r" = 1 ] && ok || bad "L1 no rows + flags/main-red-pr-pair-off must stop it (ran rc $r)"
fresh 1; run1; ran "$T/tr1" "$N1" "command -v gh"; r=$?
[ "$r" = 0 ] && ok || bad "L1 no rows, no file must run past :$N1 (ran rc $r)"
# G1 — a row nobody can read is no row: no file, so it runs.
fresh 1 switch.main-red-pr-pair-off=maybe; run1; ran "$T/tr1" "$N1" "command -v gh"; r=$?
[ "$r" = 0 ] && ok || bad "G1 switch.main-red-pr-pair-off=maybe with no file must run (ran rc $r)"

# M1 — file mode: with flag_active loaded and no row, the file alone answers.
fresh 1; STUB_FLAG_ACTIVE=1 run1; ran "$T/tr1" "$N1" "command -v gh"; r=$?
[ "$r" = 0 ] && ok || bad "M1 no rows, no file, flag_active loaded must run (ran rc $r)"
grep -qE 'FLAG_ACTIVE main-red-pr-pair-off|GET /api/flags/main-red-pr-pair-off$' "$CALLS" && bad "M1 main-red-pr-pair-off is a file-mode read: flag_active / the pause_flags row must never be asked ($(cat "$CALLS"))" || ok

# ---------- site 2: orc_pick_account -------------------------------------------
run2() {
  cp "$ORC" "$SC_ROOT/bin/lib/"
  ACCOUNT_ROUTING=1 HARNESS="$SC_ROOT" bash -c '. "$HARNESS/bin/lib/orc-account.sh"; orc_pick_account m; echo "rc=$? reason=$ORC_ACCOUNT_REASON"' 2>/dev/null
}
fresh 2 switch.orc-account-routing-off=1; out=$(run2)
[ "$out" = "rc=0 reason=orc-routing-off" ] && ok || bad "R2 switch.orc-account-routing-off=1 must answer orc-routing-off, got '$out'"
fresh 2 switch.orc-account-routing-off=0; touch "$SC_ROOT/flags/orc-account-routing-off"; out=$(run2)
[ "$out" = "rc=0 reason=no-picker" ] && ok || bad "F2 switch.orc-account-routing-off=0 must beat the file (want no-picker), got '$out'"
[ "$(sc_ignored_lines "$SC_ROOT" orc-account-routing-off)" = 1 ] && ok || bad "F2 want one 'ignored' line, got $(sc_ignored_lines "$SC_ROOT" orc-account-routing-off)"
fresh 2; touch "$SC_ROOT/flags/orc-account-routing-off"; out=$(run2)
[ "$out" = "rc=0 reason=orc-routing-off" ] && ok || bad "L2 no rows + the file must answer orc-routing-off, got '$out'"
fresh 2; out=$(run2)
[ "$out" = "rc=0 reason=no-picker" ] && ok || bad "L2 no rows, no file must answer no-picker, got '$out'"
# routing off at the fleet level: the switch is never asked, no settings read.
fresh 2 switch.orc-account-routing-off=0; out=$(cp "$ORC" "$SC_ROOT/bin/lib/"; ACCOUNT_ROUTING=0 HARNESS="$SC_ROOT" bash -c '. "$HARNESS/bin/lib/orc-account.sh"; orc_pick_account m; echo "reason=$ORC_ACCOUNT_REASON"' 2>/dev/null)
[ "$out" = "reason=routing-off" ] && ! grep -q 'api/settings' "$CALLS" && ok \
  || bad "L2 ACCOUNT_ROUTING=0 must answer routing-off with no settings read, got '$out' calls: $(cat "$CALLS")"

# M2 — file mode.
fresh 2; out=$(STUB_FLAG_ACTIVE=1 run2)
[ "$out" = "rc=0 reason=no-picker" ] && ok || bad "M2 no rows, no file, flag_active loaded must answer no-picker, got '$out'"
grep -qE 'FLAG_ACTIVE orc-account-routing-off|GET /api/flags/orc-account-routing-off$' "$CALLS" && bad "M2 orc-account-routing-off is a file-mode read: flag_active / the pause_flags row must never be asked ($(cat "$CALLS"))" || ok

# ---------- site 3: orphan-reconcile :139 ---------------------------------------
run3() { cp "$ORR" "$SC_ROOT/bin/"; HARNESS="$SC_ROOT" sc_trace "$T/tr3" "$SC_ROOT/bin/orphan-reconcile.sh" project-5 >/dev/null 2>&1; }
fresh 3 switch.orphan-reconcile-off=1; run3; ran "$T/tr3" "$N3" "GRACE_MIN="; r=$?
[ "$r" = 1 ] && ok || bad "R3 switch.orphan-reconcile-off=1 must stop orphan-reconcile before :$N3 (ran rc $r)"
fresh 3 switch.orphan-reconcile-off=0; touch "$SC_ROOT/flags/orphan-reconcile-off"; run3; ran "$T/tr3" "$N3" "GRACE_MIN="; r=$?
[ "$r" = 0 ] && ok || bad "F3 switch.orphan-reconcile-off=0 must beat the file (ran rc $r)"
[ "$(sc_ignored_lines "$SC_ROOT" orphan-reconcile-off)" = 1 ] && ok || bad "F3 want one 'ignored' line, got $(sc_ignored_lines "$SC_ROOT" orphan-reconcile-off)"
fresh 3; touch "$SC_ROOT/flags/orphan-reconcile-off"; run3; ran "$T/tr3" "$N3" "GRACE_MIN="; r=$?
[ "$r" = 1 ] && ok || bad "L3 no rows + the file must stop it (ran rc $r)"
fresh 3; run3; ran "$T/tr3" "$N3" "GRACE_MIN="; r=$?
[ "$r" = 0 ] && ok || bad "L3 no rows, no file must run past :$N3 (ran rc $r)"

# M3 — file mode.
fresh 3; STUB_FLAG_ACTIVE=1 run3
grep -qE 'FLAG_ACTIVE orphan-reconcile-off|GET /api/flags/orphan-reconcile-off$' "$CALLS" && bad "M3 orphan-reconcile-off is a file-mode read: flag_active / the pause_flags row must never be asked ($(cat "$CALLS"))" || ok

# ---------- site 4: orphan-reconcile's pr-owner-sweep hook ----------------------
# A GitHub-Issues board with one ticket an open PR owns, so the reconciler
# enqueues nothing and reaches the hook. Lifted from tests/orphan-reconcile-test.sh
# sections 0 and 10b: the gh-rest libs are copied (the REST contract is theirs),
# gh answers the wire shape, the jobs client knows /api/jobs and /api/queue too.
mkdir -p "$T/gh4"
cat > "$T/gh4/gh" <<'SH'
#!/bin/bash
SEND() { printf 'HTTP/2 200\r\nserver: x\r\n\r\n%s' "$1"; exit 0; }
PAGE=$(printf '%s' "$*" | sed -nE 's/.*page=([0-9]+).*/\1/p'); [ "${PAGE:-1}" = 1 ] || SEND '[]'
case "$*" in
  *"api rate_limit"*) exit 1 ;;
  *"/comments"*) SEND '[]' ;;
  *"/pulls"*) SEND '[{"number":1044,"title":"TK-902: the PR that owns it","body":"","head":{"ref":"ticket/TK-902"}}]' ;;
  *"/issues"*"state=all"*) SEND '[{"number":902,"state":"open","closed_at":null}]' ;;
  *"/issues"*) SEND '[{"number":902,"title":"TK-902 has an open PR","body":"## Scope","comments":0,"updated_at":"2026-01-01T00:00:00Z"}]' ;;
esac
exit 1
SH
chmod +x "$T/gh4/gh"
setup4() {
  local r="$SC_ROOT" f
  cp "$ORR" "$r/bin/"
  for f in preplan-lib.sh hold.sh gh-rest.sh gh-rest-var.sh gh-rest-list.sh; do cp "$DIR/bin/lib/$f" "$r/bin/lib/"; done
  mkdir -p "$r/prompts" "$r/locks"
  echo 'setsid /root/harness/bin/run-build.sh project-5 <issue-number> TK-<issue-number> > x' > "$r/prompts/project-5.md"
  cat >> "$r/bin/jobs-client.sh" <<'SH'
_sc_req4() { case "$2" in /api/jobs*) echo '{"jobs":[]}' ;; /api/queue*) echo '{"queue":[]}' ;; *) return 1 ;; esac; }
eval "_sc_req0() $(declare -f _jobs_req | tail -n +2)"
_jobs_req() { case "$2" in /api/settings) _sc_req0 "$@" ;; *) echo "$1 $2" >> "$CALLS"; _sc_req4 "$@" ;; esac; }
queue_list() { _jobs_req GET "/api/queue?project=$1" >/dev/null && return 0; }
SH
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$HARNESS/sweep-called.log"\n' > "$r/bin/pr-owner-sweep.sh"
  chmod +x "$r/bin/pr-owner-sweep.sh"
}
run4() {
  PATH="$T/gh4:$PATH" HARNESS="$SC_ROOT" GH_ISSUES_REPO=example-org/project-5 ORPHAN_GRACE_MIN=0 \
    "$SC_ROOT/bin/orphan-reconcile.sh" project-5 >/dev/null 2>&1
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$SC_ROOT/sweep-called.log" ] && break; sleep 0.2; done
}
swept() { grep -q -- '--repo example-org/project-5' "$SC_ROOT/sweep-called.log" 2>/dev/null; }
fresh 4; setup4; run4
if swept; then ok; else bad "L4 setup: with no switch the hook must sweep its repo (log: $(cat "$SC_ROOT/sweep-called.log" 2>/dev/null); reconcile: $(grep -o 'reconcile: .*' "$SC_ROOT/logs/project-5.log" 2>/dev/null | tail -1))"; fi
fresh 4 switch.pr-owner-sweep-off=1; setup4; run4
if swept; then bad "R4 switch.pr-owner-sweep-off=1 must stop the hook: $(cat "$SC_ROOT/sweep-called.log")"; else ok; fi
# it really got that far: the reconciler logged its summary line.
grep -q 'reconcile: open=' "$SC_ROOT/logs/project-5.log" 2>/dev/null && ok || bad "R4 the reconciler must reach its summary before the hook"
fresh 4 switch.pr-owner-sweep-off=0; setup4; touch "$SC_ROOT/flags/pr-owner-sweep-off"; run4
swept && ok || bad "F4 switch.pr-owner-sweep-off=0 must beat flags/pr-owner-sweep-off: $(cat "$SC_ROOT/sweep-called.log" 2>/dev/null)"
[ "$(sc_ignored_lines "$SC_ROOT" pr-owner-sweep-off)" = 1 ] && ok || bad "F4 want one 'ignored' line, got $(sc_ignored_lines "$SC_ROOT" pr-owner-sweep-off)"
fresh 4; setup4; touch "$SC_ROOT/flags/pr-owner-sweep-off"; run4
if swept; then bad "L4 no rows + flags/pr-owner-sweep-off must stop the hook"; else ok; fi

# M4 — file mode.
fresh 4; setup4; STUB_FLAG_ACTIVE=1 run4
swept && ok || bad "M4 no rows, no file, flag_active loaded must sweep"
grep -qE 'FLAG_ACTIVE pr-owner-sweep-off|GET /api/flags/pr-owner-sweep-off$' "$CALLS" && bad "M4 pr-owner-sweep-off is a file-mode read: flag_active / the pause_flags row must never be asked ($(cat "$CALLS"))" || ok

# ---------- site 5: outcome-metrics ---------------------------------------------
run5() { cp "$OMS" "$SC_ROOT/bin/"; HARNESS="$SC_ROOT" OUTCOME_DRY=1 sc_trace "$T/tr5" "$SC_ROOT/bin/outcome-metrics.sh" >/dev/null 2>&1; }
fresh 5 switch.outcome-metrics-disabled=1; run5; ran "$T/tr5" "$N5" "command -v flock"; r=$?
[ "$r" = 1 ] && ok || bad "R5 switch.outcome-metrics-disabled=1 must stop outcome-metrics before :$N5 (ran rc $r)"
fresh 5 switch.outcome-metrics-disabled=0; touch "$SC_ROOT/flags/outcome-metrics-disabled"; run5; ran "$T/tr5" "$N5" "command -v flock"; r=$?
[ "$r" = 0 ] && ok || bad "F5 switch.outcome-metrics-disabled=0 must beat the file (ran rc $r)"
[ "$(sc_ignored_lines "$SC_ROOT" outcome-metrics-disabled)" = 1 ] && ok || bad "F5 want one 'ignored' line, got $(sc_ignored_lines "$SC_ROOT" outcome-metrics-disabled)"
fresh 5; touch "$SC_ROOT/flags/outcome-metrics-disabled"; run5; ran "$T/tr5" "$N5" "command -v flock"; r=$?
[ "$r" = 1 ] && ok || bad "L5 no rows + the file must stop it (ran rc $r)"
fresh 5; run5; ran "$T/tr5" "$N5" "command -v flock"; r=$?
[ "$r" = 0 ] && ok || bad "L5 no rows, no file must run past :$N5 (ran rc $r)"
# L23 — the default flag mode still consults the pause_flags row when the client
# has it; since BH-2412 it reads it (GET /api/flags/<name>) instead of calling
# flag_active, whose reconcile writes flags/.
fresh 5; touch "$SC_ROOT/flags/outcome-metrics-disabled"; STUB_FLAG_ACTIVE=1 run5; ran "$T/tr5" "$N5" "command -v flock"; r=$?
[ "$r" = 1 ] && ok || bad "L23 no rows + flag_active + the file must stop it (ran rc $r)"
grep -qx 'GET /api/flags/outcome-metrics-disabled' "$CALLS" && ok || bad "L23 the pause_flags row for outcome-metrics-disabled must be read: $(cat "$CALLS")"
grep -q 'FLAG_ACTIVE outcome-metrics-disabled' "$CALLS" && bad "L23 flag_active (it writes flags/) must not be called: $(cat "$CALLS")" || ok

# ---------- site 6: overlap-guard :92, and :96 left alone -----------------------
run6() { cp "$OVG" "$SC_ROOT/bin/"; HARNESS="$SC_ROOT" sc_trace "$T/tr6" "$SC_ROOT/bin/overlap-guard.sh" "$1" K-1 >/dev/null 2>&1; }
fresh 6 switch.overlap-guard-off=1; run6 proj; ran "$T/tr6" "$N6" "'\\[' -e .*/flags/overlap-guard-off-"; r=$?
[ "$r" = 1 ] && ok || bad "R6 switch.overlap-guard-off=1 must stop overlap-guard before :$N6 (ran rc $r)"
fresh 6 switch.overlap-guard-off=0; touch "$SC_ROOT/flags/overlap-guard-off"; run6 proj; ran "$T/tr6" "$N6" "'\\[' -e .*/flags/overlap-guard-off-"; r=$?
[ "$r" = 0 ] && ok || bad "F6 switch.overlap-guard-off=0 must beat the file (ran rc $r)"
[ "$(sc_ignored_lines "$SC_ROOT" overlap-guard-off)" = 1 ] && ok || bad "F6 want one 'ignored' line, got $(sc_ignored_lines "$SC_ROOT" overlap-guard-off)"
fresh 6; touch "$SC_ROOT/flags/overlap-guard-off"; run6 proj; ran "$T/tr6" "$N6" "'\\[' -e .*/flags/overlap-guard-off-"; r=$?
[ "$r" = 1 ] && ok || bad "L6 no rows + the file must stop it (ran rc $r)"
fresh 6; run6 proj; ran "$T/tr6" "$N6" "'\\[' -e .*/flags/overlap-guard-off-"; r=$?
[ "$r" = 0 ] && ok || bad "L6 no rows, no file must run past :$N6 (ran rc $r)"
# M6 — file mode.
fresh 6; STUB_FLAG_ACTIVE=1 run6 proj
grep -qE 'FLAG_ACTIVE overlap-guard-off|GET /api/flags/overlap-guard-off$' "$CALLS" && bad "M6 overlap-guard-off is a file-mode read: flag_active / the pause_flags row must never be asked ($(cat "$CALLS"))" || ok
# N1 — a per-project row is not the fleet switch.
fresh 6 switch.overlap-guard-off-proj=1; run6 other; ran "$T/tr6" "$N96" "command -v jq"; r=$?
[ "$r" = 0 ] && ok || bad "N1 switch.overlap-guard-off-proj=1 must not stop project other past :$N96 (ran rc $r)"
( . "$SC_ROOT/bin/lib/lane-switch.sh"; HARNESS="$SC_ROOT" lane_switch overlap-guard-off file ); r=$?
[ "$r" = 1 ] && ok || bad "N1 switch.overlap-guard-off-proj=1 must not turn overlap-guard-off on (rc $r)"
# N3 — line 96 stays a FILE read: a row under the per-project name is read by
# nothing, so it does not stop that project either.
fresh 6 switch.overlap-guard-off-proj=1; run6 proj; ran "$T/tr6" "$N96" "command -v jq"; r=$?
[ "$r" = 0 ] && ok || bad "N3 switch.overlap-guard-off-proj=1 must not stop proj: flags/overlap-guard-off-<project> is a file, not a row (ran rc $r)"
# N2 — the per-project file still stops that project, and only that one.
fresh 6; touch "$SC_ROOT/flags/overlap-guard-off-proj"; run6 proj; ran "$T/tr6" "$N96" "command -v jq"; r=$?
[ "$r" = 1 ] && ok || bad "N2 flags/overlap-guard-off-proj must stop proj at :$N96 (ran rc $r)"
run6 other; ran "$T/tr6" "$N96" "command -v jq"; r=$?
[ "$r" = 0 ] && ok || bad "N2 flags/overlap-guard-off-proj must not stop project other (ran rc $r)"

# ---------- C1 — the registry ----------------------------------------------------
for f in $FILES; do
  lits=$(grep -hE 'lane_switch [a-z0-9_-]+' "$DIR/$f" | grep -vE '^[[:space:]]*#' \
    | grep -oE 'lane_switch [a-z0-9_-]+' | awk '{print $2}' | sort -u)
  [ -n "$lits" ] && ok || bad "C1 $f reads no switch through lane_switch"
  for n in $lits; do
    c="$DIR/catalog/switches.d/$n.json"
    if [ "$(jq -r '.name // empty' "$c" 2>/dev/null)" = "$n" ] \
       && jq -e --arg f "$f" '.readers | index($f)' "$c" >/dev/null 2>&1; then ok
    else bad "C1 lane_switch $n in $f: catalog/switches.d/$n.json must name it and list $f in readers"; fi
  done
done
jq -e '.readers == ["bin/orphan-reconcile.sh","bin/pr-owner-sweep.sh"]' "$DIR/catalog/switches.d/pr-owner-sweep-off.json" >/dev/null 2>&1 && ok \
  || bad "C1 catalog/switches.d/pr-owner-sweep-off.json readers must be both bin/orphan-reconcile.sh and bin/pr-owner-sweep.sh"
for c in "$DIR/catalog/switches.d/main-red-pr-pair-off.json" "$DIR/catalog/switches.d/orc-account-routing-off.json" \
         "$DIR/catalog/switches.d/orphan-reconcile-off.json" "$DIR/catalog/switches.d/pr-owner-sweep-off.json" \
         "$DIR/catalog/switches.d/outcome-metrics-disabled.json" "$DIR/catalog/switches.d/overlap-guard-off.json"; do
  jq -e '(.name|type)=="string" and (.readers|type)=="array" and .box_scoped==true and ((.what|type)=="string" and (.what|length)>0)' "$c" >/dev/null 2>&1 \
    && ok || bad "C1 ${c#"$DIR"/} must be {name, readers[], box_scoped:true, what}"
done

# ---------- O1 — the slice's range -------------------------------------------------
for f in $FILES; do
  lo=$(grep -hE 'lane_switch [a-z0-9_-]+' "$DIR/$f" | grep -vE '^[[:space:]]*#' \
    | grep -oE 'lane_switch [a-z0-9_-]+' | awk '{print $2}' | sort | head -1)
  case "$lo" in [g-o]*) ok ;; *) bad "O1 $f: lowest lane_switch literal '$lo' is outside [g-o]" ;; esac
done

# ---------- X1 — nothing writes the switch files -----------------------------------
alt=$(printf '%s' "$NAMES" | tr ' ' '|')
XRE="^[^#]*\\b(touch|rm|flag_set|flag_clear)\\b[^#]*flags?/?($alt)\\b|^[^#]*>[[:space:]]*\"?[^\"]*flags/($alt)\"?"
# An operator message names the file for a human to touch; it writes nothing.
MSG='^[^:]+:[0-9]+:[[:space:]]*(printf|echo|say|log)[[:space:]]'
hits=$(cd "$DIR" && grep -rnE "$XRE" bin fly worker console-ui/src 2>/dev/null | grep -vE "$MSG")
[ -z "$hits" ] && ok || bad "X1 no code may write or remove a switch file: $hits"
raw=$(cd "$DIR" && grep -rnE "$XRE" bin/overlap-guard.sh | grep -E "^[0-9]+:[[:space:]]*printf .*touch .*flags/overlap-guard-off")
if [ -n "$raw" ] && ! grep -qF "bin/overlap-guard.sh:${raw%%:*}:" <<<"$hits"; then ok
else bad "X1 the overlap-guard operator printf must match the raw pattern and be excluded (raw: '${raw%%:*}')"; fi

echo "switch-convert-sweepers.bh-2444: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
