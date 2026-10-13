#!/bin/bash
# tests/triage-state-contract.bh-3923-test.sh — BH-3923 (BH-3921.0): the
# triage-state hook points and their stub modules. This slice changes no tick
# outcome: every new function is a stub and every hook calls one. These cases
# pin the wiring the later BH-3921 slices fill in, and that the stubs are inert.
#
#   C1 sourcing the lib defines the five new functions; the module headers carry
#      the contract strings
#   C2 the stubs are inert, and the 0-changed tick line is byte-identical to
#      the line before this slice
#   C3 ts_precheck exports TS_ROWS_OK: 1 with the rows read, 0 when the read
#      fails, 0 with no board fingerprint
#   C4 ts_tick calls ts_rows_unreadable_tick once, never on a forced /
#      forced-env tick, and a 0 from it ends the tick before the enforce line
#   C5 ts_waste_account <path> + ts_waste_bracket at the four tick-line sites
#   C6 _ts_enforce_reason accepts ts-deferred; no-gate-state / gate-fetch-failed
#      stay observe-only in this slice. C6b the alert-after knob's reader
#   C7 with the waste module missing the lib still sources rc 0 and the
#      0-changed line is unchanged
#
# Everything real except the worker: bin/lib/triage-state.sh, its two modules,
# bin/triage-state.py and bin/triage-signal.py from this checkout, against an
# in-app board fingerprint. triage_state_list serves a rows file (or fails);
# triage_state_put records nothing. Threads are seeded as the .raw / .entry
# cache the pre-check reads (no fetch: TRIAGE_STATE_MAX_FETCH=0).
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/triage-state-contract.bh-3923-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is required"; exit 1; }
export PYTHONDONTWRITEBYTECODE=1
WASTE="$DIR/bin/lib/triage-state-waste.sh"
UNREAD="$DIR/bin/lib/triage-state-unreadable.sh"

# ── a scratch harness: the production files, linked ─────────────────────────
mkh() { # mkh <root> [module to leave out]
  mkdir -p "$1/bin/lib" "$1/state" "$1/logs" "$1/builds" "$1/flags"
  for s in triage-state.py triage-signal.py; do ln -s "$DIR/bin/$s" "$1/bin/$s"; done
  for s in triage-state.sh triage-state-unreadable.sh triage-state-waste.sh; do
    [ "$s" = "${2:-}" ] || ln -s "$DIR/bin/lib/$s" "$1/bin/lib/$s"
  done
}
H="$T/h"; P=project-4; mkh "$H"
ROWS="$T/rows.json"; echo '[]' > "$ROWS"; LIST_FAILS=0
triage_state_list() { [ "$LIST_FAILS" = 0 ] || return 1; cat "$ROWS"; }
triage_state_put() { :; }
LANE_TICK() { :; }
rt_gate_consume() { :; }
# shellcheck source=/dev/null
. "$H/bin/lib/triage-state.sh"; SRC_RC=$?

tick_env() { # tick_env <mode> [gate-reason]
  export HARNESS="$H" TRIAGE_STATE_MODE="$1" TRIAGE_STATE_MAX_FETCH=0
  PROJECT=$P; STAMP="2026-10-01 10:00:00Z"; LOG="$H/logs/$P.log"
  GATE_REASON="${2:-board-changed}"; SCOPE_N=full
  TICK_SCOPE=""; BOARD_SEC=""; QLINES=""; QDIRS=""; RDIRS=""; JOB_ID=""
  PROMPT_TEXT="SOP PROMPT"
}
# board <root> <id...> — the in-app fingerprint and the thread cache it hashes
board() {
  local r="$1" i sep="" d; shift
  d="$r/state/triage-state/$P"; mkdir -p "$d"
  { printf '{"b1":['
    for i in "$@"; do printf '%s{"id":"%s","key":"TK-%s","title":"t %s","status":"open","commentCount":1,"lastActivityAt":"2026-09-30T00:00:00Z"}' "$sep" "$i" "$i" "$i"; sep=,; done
    printf ']}\n'; } > "$r/state/$P.gate.pending"
  for i in "$@"; do
    jq -n --arg i "$i" '{kind:"inapp",doc:{id:$i,key:("TK-" + $i),title:("t " + $i),status:"open",description:"d",
      comments:[{id:("m-" + $i),authorName:"Client",body:"please",createdAt:"2026-09-30T00:00:00Z"}]}}' > "$d/$i.raw"
  done
  python3 "$DIR/bin/triage-state.py" entries --world "$r/state/$P.gate.pending" > "$T/entries.tsv"
  while IFS=$'\t' read -r k _ esha _; do printf '%s' "$esha" > "$d/$k.entry"; done < "$T/entries.tsv"
}
lastb() { # the text between a line's last `[` and last `]`
  printf '%s' "$1" | sed -E 's/.*\[([^][]*)\][^][]*$/\1/'
}

# ═══ C1 — the lib defines the five functions; the headers carry the contract ═
[ "$SRC_RC" = 0 ] && ok || bad "(C1) sourcing the lib returns 0, got $SRC_RC"
for fn in ts_rows_unreadable_tick ts_waste_account ts_waste_bracket ts_row_note_of ts_unreadable_alert_after; do
  [ "$(type -t "$fn")" = function ] && ok || bad "(C1) $fn is a function after sourcing the lib, got '$(type -t "$fn")'"
done
for s in 'skip deferred:cap' 'skip deferred:budget' 'ts:new=N:chg=N:due=N:cap=N:unr=N:pu=N' 'ts=<class>' ' paid_unchanged=N'; do
  [ -r "$WASTE" ] && grep -qF -- "$s" "$WASTE" && ok || bad "(C1) $WASTE header documents '$s'"
done
# TEST-CHANGE (BH-3921): the stub's 'always returns 1' is retired by BH-3925's real body; its header now names the streak file
for s in 'forced' 'TS_READY' 'rows-unreadable.streak'; do
  [ -r "$UNREAD" ] && grep -qF -- "$s" "$UNREAD" && ok || bad "(C1) $UNREAD header documents '$s'"
done

# ═══ C2 — the stubs are inert ═════════════════════════════════════════════════
ts_rows_unreadable_tick; rc=$?
[ "$rc" = 1 ] && ok || bad "(C2) ts_rows_unreadable_tick returns 1, got $rc"
out=$(ts_waste_bracket; echo x); [ "$out" = x ] && ok || bad "(C2) ts_waste_bracket prints nothing: [$out]"
out=$(ts_row_note_of TK-1; echo x); [ "$out" = x ] && ok || bad "(C2) ts_row_note_of prints nothing: [$out]"
out=$(ts_waste_account zero; echo "x$?"); [ "$out" = x0 ] && ok || bad "(C2) ts_waste_account zero prints nothing, rc 0: [$out]"
# the 0-changed line, through the real ts_tick: the line this slice must not change
board "$H"; : > "$H/logs/$P.log"
tick_env enforce board-changed
OUT=$( ts_tick; echo CONTINUED ) 2>/dev/null
case "$OUT" in *CONTINUED*) bad "(C2) an empty board under enforce ends the tick at \$0: [$OUT]" ;; *) ok ;; esac
ZERO_LINE=$(grep 'rc=skip' "$H/logs/$P.log")
# TEST-CHANGE (BH-3921): the bracket's deferred=N is now cap=N budget=N; the rest of the line is byte-identical.
# TEST-CHANGE (BH-3926): the waste stub has a body now; the 0-changed line carries
# its paid_unchanged=0 token inside the last bracket and is otherwise unchanged.
[ "$ZERO_LINE" = "2026-10-01 10:00:00Z [$P] rc=skip :: triage-state: 0 changed — 0 open, 0 to the model, 0 unchanged [reads=0 cap=0 budget=0]; no model call [gate=board-changed paid_unchanged=0]" ] && ok \
  || bad "(C2) the 0-changed line is the pre-BH-3923 line with cap=N budget=N (BH-3921) plus paid_unchanged=0 (BH-3926): [$ZERO_LINE]"

# ═══ C3 — TS_ROWS_OK ═════════════════════════════════════════════════════════
board "$H" r1
tick_env shadow
rok() { ( ts_precheck >/dev/null 2>&1; bash -c 'printf %s "${TS_ROWS_OK-unset}"' ); }
LIST_FAILS=0; got=$(rok); [ "$got" = 1 ] && ok || bad "(C3) TS_ROWS_OK=1 with the rows read (exported to a child), got '$got'"
LIST_FAILS=1; got=$(rok); [ "$got" = 0 ] && ok || bad "(C3) TS_ROWS_OK=0 when triage_state_list fails, got '$got'"
LIST_FAILS=0; mv "$H/state/$P.gate.pending" "$T/gp.save"
got=$(rok); [ "$got" = 0 ] && ok || bad "(C3) TS_ROWS_OK=0 with no board fingerprint, got '$got'"
mv "$T/gp.save" "$H/state/$P.gate.pending"

# ═══ C4 — the rows-unreadable hook in ts_tick ════════════════════════════════
hookrun() { # hookrun <gate-reason> <override rc> — prints the hook's call count
  : > "$T/hook"; : > "$H/logs/$P.log"
  tick_env enforce "$1"
  ( eval "ts_rows_unreadable_tick() { echo hit >> \"$T/hook\"; return $2; }"; ts_tick >/dev/null 2>&1; echo CONTINUED >> "$T/hook.cont" )
  wc -l < "$T/hook" | tr -d ' '
}
board "$H" r1
[ "$(hookrun board-changed 1)" = 1 ] && ok || bad "(C4) a board-changed tick calls ts_rows_unreadable_tick once"
grep -q 'triage-state enforce: 1 open' "$H/logs/$P.log" && ok \
  || bad "(C4) with the hook returning 1 the tick goes on to the enforce line: $(cat "$H/logs/$P.log")"
for r in forced forced-env; do
  [ "$(hookrun "$r" 1)" = 0 ] && ok || bad "(C4) a $r tick never calls ts_rows_unreadable_tick"
done
: > "$T/hook.cont"
[ "$(hookrun board-changed 0)" = 1 ] && ok || bad "(C4) the returning-0 hook is called once"
grep -q 'triage-state enforce:' "$H/logs/$P.log" && bad "(C4) a hook returning 0 ends the tick before the enforce line: $(cat "$H/logs/$P.log")" || ok
grep -q CONTINUED "$T/hook.cont" && ok || bad "(C4) a hook returning 0 makes ts_tick return 0 (the tick is not exited)"

# ═══ C5 — waste account + bracket at the four tick-line sites ════════════════
: > "$T/acct"; : > "$H/logs/$P.log"
c5() { # c5 <mode> <gate-reason> <board ids...>
  local m="$1" g="$2"; shift 2
  board "$H" "$@"; tick_env "$m" "$g"
  ( ts_waste_bracket() { printf ' paid_unchanged=7'; }
    ts_waste_account() { echo "$1" >> "$T/acct"; }
    ts_tick >/dev/null 2>&1 )
}
c5 shadow board-changed r1
c5 enforce forced r1
c5 enforce board-changed
c5 enforce board-changed r1
L_SHADOW=$(grep 'triage-state shadow: ' "$H/logs/$P.log")
L_OBS=$(grep 'observe only' "$H/logs/$P.log")
L_ZERO=$(grep 'rc=skip' "$H/logs/$P.log")
L_ENF=$(grep 'triage-state enforce: 1 open' "$H/logs/$P.log" | grep -v 'observe only')
for nm in SHADOW OBS ZERO ENF; do
  v="L_$nm"; l="${!v}"
  [ "$(printf '%s\n' "$l" | grep -c .)" = 1 ] || { bad "(C5) exactly one $nm line: [$l]"; continue; }
  [ "$(printf '%s' "$l" | grep -o 'paid_unchanged=7' | wc -l | tr -d ' ')" = 1 ] && ok \
    || bad "(C5) the $nm line carries the bracket token exactly once: [$l]"
  case "$(lastb "$l")" in *' paid_unchanged=7') ok ;; *) bad "(C5) the $nm line's last bracket ends ' paid_unchanged=7]': [$l]" ;; esac
done
# TEST-CHANGE (BH-3921): the bracket's deferred=N is now cap=N budget=N; the rest of the line is byte-identical.
case "$L_SHADOW" in *"[gate=board-changed reads=0 cap=0 budget=0 paid_unchanged=7]") ok ;; *) bad "(C5) shadow line: [$L_SHADOW]" ;; esac
case "$L_ZERO" in *"[reads=0 cap=0 budget=0]; no model call [gate=board-changed paid_unchanged=7]") ok ;; *) bad "(C5) zero line: [$L_ZERO]" ;; esac
case "$L_OBS" in *"[reads=0 cap=0 budget=0 paid_unchanged=7] — observe only on a 'forced' tick") ok ;; *) bad "(C5) observe-only line: [$L_OBS]" ;; esac
[ "$(tr '\n' ' ' < "$T/acct")" = "unrestricted unrestricted zero restricted " ] && ok \
  || bad "(C5) ts_waste_account paths in order: [$(tr '\n' ' ' < "$T/acct")]"

# ═══ C6 — _ts_enforce_reason ═════════════════════════════════════════════════
for r in ts-deferred board-changed event-wake daily-sweep queue-pending results-sweep remote-results-pending split-ready; do
  GATE_REASON=$r _ts_enforce_reason && ok || bad "(C6) _ts_enforce_reason accepts $r"
done
for r in no-gate-state gate-fetch-failed forced forced-env; do
  GATE_REASON=$r _ts_enforce_reason && bad "(C6) $r stays observe-only in this slice" || ok
done
# C6b — the alert-after knob's reader
got=$(unset TRIAGE_STATE_UNREADABLE_ALERT_AFTER; ts_unreadable_alert_after); [ "$got" = 3 ] && ok || bad "(C6b) unset reads 3, got '$got'"
got=$(TRIAGE_STATE_UNREADABLE_ALERT_AFTER=0 ts_unreadable_alert_after); [ "$got" = 1 ] && ok || bad "(C6b) 0 reads as 1, got '$got'"
got=$(TRIAGE_STATE_UNREADABLE_ALERT_AFTER=7 ts_unreadable_alert_after); [ "$got" = 7 ] && ok || bad "(C6b) 7 reads 7, got '$got'"

# ═══ C7 — a box mid-sync without the waste module ════════════════════════════
H7="$T/h7"; mkh "$H7" triage-state-waste.sh
OUT7=$( (
  unset -f ts_waste_account ts_waste_bracket ts_row_note_of ts_rows_unreadable_tick ts_unreadable_alert_after
  # shellcheck source=/dev/null
  . "$H7/bin/lib/triage-state.sh"; echo "SRC=$?"
  H="$H7"; board "$H7"; tick_env enforce board-changed; LOG="$H7/logs/$P.log"; : > "$LOG"
  ( ts_tick ) >/dev/null 2>&1
  grep 'rc=skip' "$LOG"
) 2>/dev/null )
case "$OUT7" in "SRC=0"*) ok ;; *) bad "(C7) the lib sources rc 0 with the waste module missing: [$OUT7]" ;; esac
L7=$(printf '%s\n' "$OUT7" | grep 'rc=skip')
# TEST-CHANGE (BH-3926): the waste stub has a body now, so $ZERO_LINE carries a
# bracket token; without the module the line is the literal pre-BH-3923 one.
# TEST-CHANGE (BH-3921, at the main merge): that line's first bracket is now
# cap=N budget=N, not deferred=N, the same as C2.
PRE_LINE="2026-10-01 10:00:00Z [$P] rc=skip :: triage-state: 0 changed — 0 open, 0 to the model, 0 unchanged [reads=0 cap=0 budget=0]; no model call [gate=board-changed]"
[ -n "$L7" ] && [ "$L7" = "$PRE_LINE" ] && ok || bad "(C7) the 0-changed line without the module is byte-identical: [$L7] vs [$PRE_LINE]"

echo "triage-state-contract.bh-3923: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
