#!/bin/bash
# tests/triage-gate-ledger.bh-2318-test.sh — a project that moves boxes (or a
# rebuilt box) does not re-buy a full triage, and never skips work it has not
# seen (BH-2318).
#
# THE PROPERTY. The triage gate's per-project state (state/<p>.gate.json's sha,
# state/<p>.gate-meta and state/<p>.gate.fail) has a ledgers(kind=triage_gate)
# twin keyed by project, written after every file write. A box whose state/ is
# empty reads the row: an unchanged live board restores gate.json and SKIPs, a
# changed or re-armed board still answers RUN no-gate-state, and a failure
# streak continues where the old box left it. Flag off, outage, malformed row,
# or another project's row: exactly today's answers.
#
# Driven, not grepped: section B/D/E run the REAL bin/triage-gate.sh against a
# fake gh (the tests/triage-gate-self-comments.bh-2133-test.sh fixture), section
# C runs the real rt_gate_consume / rt_gate_fail_consume / rt_launch, and the
# ledger is a directory SHARED by every scratch "box" behind a stub
# bin/jobs-client.sh — the only thing two boxes have in common, as in prod.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/triage-gate-ledger.bh-2318-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "jq/python3 missing — skipping"; exit 0; }
unset FULL_SWEEP_SECS TRIAGE_FAIL_CONSUME_AFTER
P=boardA
export TGL_TEST_LEDGER="$T/ledger"
mkdir -p "$TGL_TEST_LEDGER" "$T/fakebin" "$T/stub"

# ── the shared ledger: one file per (kind,key), every call logged ────────────
cat > "$T/stub/jobs-client.sh" <<'SH'
_tl_f() { local k="$2"; printf '%s/%s.%s' "$TGL_TEST_LEDGER" "$1" "${k// /_}"; }
job_ledger_get() {
  echo "GET $1|$2" >> "$TGL_TEST_LEDGER/calls"
  [ -f "$TGL_TEST_LEDGER/getfail" ] && return 1
  [ -f "$(_tl_f "$1" "$2")" ] || return 2
  cat "$(_tl_f "$1" "$2")"
}
job_ledger_put() {
  echo "PUT $1|$2|$3" >> "$TGL_TEST_LEDGER/calls"
  [ -f "$TGL_TEST_LEDGER/putfail" ] && return 1
  printf '%s' "$3" > "$(_tl_f "$1" "$2")"
}
flag_active() { [ -f "${HARNESS:-/nonexistent}/flags/$1" ]; }
SH
row()    { cat "$TGL_TEST_LEDGER/triage_gate.${1// /_}" 2>/dev/null; }
setrow() { printf '%s' "$2" > "$TGL_TEST_LEDGER/triage_gate.${1// /_}"; }
calls()  { cat "$TGL_TEST_LEDGER/calls" 2>/dev/null; }
reset_ledger() { rm -f "$TGL_TEST_LEDGER"/*; }

# box <name> [off] — a fresh scratch harness. "off" = the no-twin-ledgers flag down.
box() {
  local h="$T/box-$1"
  mkdir -p "$h/bin" "$h/state" "$h/flags" "$h/logs" "$h/env"
  cp "$T/stub/jobs-client.sh" "$h/bin/jobs-client.sh"
  # The gate runs from the box's own bin/, as on a box: bin/lib/ready-queue.sh
  # sources the client beside it, and that must be the stub, never the real one.
  cp "$DIR/bin/triage-gate.sh" "$h/bin/triage-gate.sh"
  cp -r "$DIR/bin/lib" "$h/bin/lib"
  cat > "$h/bin/fleet-conf.sh" <<'SH'
case "${2:-}" in board_prefix) echo "-" ;; repo) echo "o/r" ;; *) exit 1 ;; esac
SH
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\n' "$h" > "$h/bin/lane-alert.sh"
  printf '#!/bin/sh\nexit 0\n' > "$h/bin/decision-log.sh"
  chmod +x "$h/bin/"*.sh
  [ "${2:-}" = off ] || : > "$h/flags/no-twin-ledgers"
  printf '%s' "$h"
}

# fake gh: the ai-build issue list and the open PR list.
cat > "$T/fakebin/gh" <<'SH'
[ "${1:-}" = api ] || exit 1
shift; P=""
while [ $# -gt 0 ]; do case "$1" in -i) shift ;; -X|-f|-F|-H) shift 2 ;; -*) shift ;; *) P="$1"; break ;; esac; done
case "$P" in
  repos/o/r/issues/*/comments*) BODY='[]' ;;
  repos/o/r/issues*) BODY=$(cat "$ISSUES") ;;
  repos/o/r/pulls*)  BODY='[]' ;;
  *) exit 1 ;;
esac
printf 'HTTP/2.0 200\r\n\r\n%s\n' "$BODY"
SH
chmod +x "$T/fakebin/gh"
export ISSUES="$T/issues.json"
board() { # board <comment count on #7>
  jq -nc --argjson c "$1" '[{number:7, state:"open", title:"Add sort", comments:$c, updated_at:"2026-09-24T11:00:00Z",
     body:"b", labels:[{name:"ai-build"}], assignees:[], milestone:null},
    {number:8, state:"open", title:"Export", comments:0, updated_at:"2026-09-24T09:00:00Z",
     body:"c", labels:[{name:"ai-build"}], assignees:[], milestone:null}]' > "$ISSUES"
}
# gate <harness> [project] [args...] — the real gate, on that box.
gate() { local h="$1" pj="${2:-$P}"; shift 2 2>/dev/null || shift
  ( export PATH="$T/fakebin:$PATH" HARNESS="$h"; "$h/bin/triage-gate.sh" "$pj" "$@" 2>>"$T/err.txt" ); }
# in_rt <harness> <cmd...> — run a bin/lib/rt function the way run-triage.sh's shell does.
in_rt() { local h="$1"; shift
  ( HARNESS="$h" PROJECT="$P" STAMP=t LOG="$h/logs/$P.log" ALERTS="$h/logs/ALERTS.log" RC="${RC:-1}" OUT=/dev/null
    . "$h/bin/jobs-client.sh"; . "$DIR/bin/lib/rt/gate.sh"; . "$DIR/bin/lib/rt/launch.sh"; "$@" ); }
sha() { sha256sum < "$1" | cut -d' ' -f1; }

# ══ A — the lib against the stub ledger ══════════════════════════════════════
A=$(box A)
printf '{"issues":[1]}' > "$A/state/$P.gate.json"; echo 1758800000 > "$A/state/$P.gate-meta"
( HARNESS="$A"; . "$A/bin/jobs-client.sh"; . "$DIR/bin/lib/triage-gate-ledger.sh" 2>/dev/null; tgl_put_gate "$A" "$P" ) >/dev/null 2>&1
[ "$(row "$P")" = "$(sha "$A/state/$P.gate.json") 1758800000" ] && ok \
  || bad "A1: put wrote '$(row "$P")', want '<sha256 of gate.json> 1758800000' under key $P"
OUT=$( HARNESS="$A"; . "$A/bin/jobs-client.sh"; . "$DIR/bin/lib/triage-gate-ledger.sh" 2>/dev/null
       tgl_read_gate "$A" "$P" && echo "$TGL_SHA $TGL_EPOCH" )
[ "$OUT" = "$(row "$P")" ] && ok || bad "A1: read back '$OUT', want '$(row "$P")'"
for m in "abc 12" "" "$(printf '%063d' 0) 5" "$(sha "$A/state/$P.gate.json")" "$(sha "$A/state/$P.gate.json") -1"; do
  setrow "$P" "$m"
  ( HARNESS="$A"; . "$A/bin/jobs-client.sh"; . "$DIR/bin/lib/triage-gate-ledger.sh" 2>/dev/null; tgl_read_gate "$A" "$P" ) >/dev/null 2>&1
  [ $? = 1 ] && ok || bad "A2: malformed row '$m' was read as a hit"
done
# A3 — hydrate never overwrites a local file
GOOD="$(sha "$A/state/$P.gate.json") 1758800000"; setrow "$P" "$GOOD"; setrow "$P fail" "0123456789abcdef 2"
echo 5 > "$A/state/$P.gate-meta"; printf 'LOCAL' > "$A/state/$P.gate.json"; printf 'x\n9\n' > "$A/state/$P.gate.fail"
( HARNESS="$A"; . "$A/bin/jobs-client.sh"; . "$DIR/bin/lib/triage-gate-ledger.sh" 2>/dev/null
  tgl_hydrate_meta "$A" "$P"; tgl_hydrate_gate "$A" "$P" '{"issues":[1]}'; tgl_hydrate_fail "$A" "$P" ) >/dev/null 2>&1
[ "$(cat "$A/state/$P.gate-meta")" = 5 ] && [ "$(cat "$A/state/$P.gate.json")" = LOCAL ] \
  && [ "$(cat "$A/state/$P.gate.fail")" = $'x\n9' ] && ok || bad "A3: a hydrate overwrote a local file"
# A3b — and it does fill an absent one
rm -f "$A/state/$P.gate-meta" "$A/state/$P.gate.json" "$A/state/$P.gate.fail"
( HARNESS="$A"; . "$A/bin/jobs-client.sh"; . "$DIR/bin/lib/triage-gate-ledger.sh" 2>/dev/null
  tgl_hydrate_meta "$A" "$P"; tgl_hydrate_gate "$A" "$P" '{"issues":[1]}'; tgl_hydrate_fail "$A" "$P" ) >/dev/null 2>&1
[ "$(cat "$A/state/$P.gate-meta" 2>/dev/null)" = 1758800000 ] && [ "$(cat "$A/state/$P.gate.json" 2>/dev/null)" = '{"issues":[1]}' ] \
  && [ "$(cat "$A/state/$P.gate.fail" 2>/dev/null)" = $'0123456789abcdef\n2' ] && ok || bad "A3b: an absent file was not hydrated from a good row"

# ══ B — box A consumes, box B arrives with an empty state/ ═══════════════════
reset_ledger
BA=$(box BA); board 2
OUT=$(gate "$BA" "$P" --seed); grep -q '^SEEDED' <<<"$OUT" && ok || bad "B0: seed '$OUT' err=$(tail -3 "$T/err.txt")"
[ "$(row "$P")" = "$(sha "$BA/state/$P.gate.json") $(cat "$BA/state/$P.gate-meta")" ] && ok || bad "B0: --seed wrote row '$(row "$P")'"
board 3
OUT=$(gate "$BA"); grep -q '^RUN board-changed' <<<"$OUT" && ok || bad "B0: a new comment must RUN on box A: '$OUT'"
in_rt "$BA" rt_gate_consume
[ "$(row "$P")" = "$(sha "$BA/state/$P.gate.json") $(cat "$BA/state/$P.gate-meta")" ] && ok \
  || bad "B0: rt_gate_consume did not mirror the consumed gate: row '$(row "$P")'"
# B1 — box B, same board
: > "$TGL_TEST_LEDGER/calls"
BB=$(box BB)
OUT=$(gate "$BB")
grep -q '^SKIP no-change' <<<"$OUT" && grep -q 'restored from ledger' <<<"$OUT" && ok \
  || bad "B1: a moved box re-bought a triage on an unchanged board: '$OUT'"
cmp -s "$BA/state/$P.gate.json" "$BB/state/$P.gate.json" && ok || bad "B1: box B's restored gate.json differs from box A's"
[ "$(cat "$BB/state/$P.gate-meta" 2>/dev/null)" = "$(cat "$BA/state/$P.gate-meta")" ] && ok || bad "B2: gate-meta not restored from the row"
! grep -qi 'pending' "$TGL_TEST_LEDGER/calls" && ok || bad "B1: a pending row was touched: $(calls)"
[ "$(grep -c '^GET' "$TGL_TEST_LEDGER/calls")" -le 2 ] && ok || bad "B1: more than one read per missing file: $(calls)"
OUT=$(gate "$BB"); grep -q '^SKIP no-change' <<<"$OUT" && ! grep -q restored <<<"$OUT" && ok || bad "B1: next tick on box B '$OUT'"
# B2 — the full-sweep clock continues across boxes: old epoch => daily sweep
SAVED=$(row "$P"); setrow "$P" "${SAVED%% *} 1000"; BB2=$(box BB2)
OUT=$(gate "$BB2"); [ "$OUT" = "RUN daily-sweep" ] && ok || bad "B2: an expired epoch from the row must still RUN daily-sweep: '$OUT'"
[ "$(cat "$BB2/state/$P.gate-meta" 2>/dev/null)" = 1000 ] && ok || bad "B2: the row's old epoch was not the one restored"
setrow "$P" "$SAVED"
# B3 — the board moved by one comment: nothing restored, today's answer
board 4; BB3=$(box BB3)
OUT=$(gate "$BB3"); [ "$OUT" = "RUN no-gate-state" ] && ok || bad "B3: a changed board on a moved box must RUN no-gate-state: '$OUT'"
[ ! -e "$BB3/state/$P.gate.json" ] && ok || bad "B3: a gate.json was written on a hash mismatch"

# ══ C — the failure counter follows the project ══════════════════════════════
reset_ledger
CA=$(box CA)
printf 'BOARD-X' > "$CA/state/$P.gate.pending"; RC=1 in_rt "$CA" rt_gate_fail_consume
printf 'BOARD-X' > "$CA/state/$P.gate.pending"; RC=1 in_rt "$CA" rt_gate_fail_consume
SX=$(printf 'BOARD-X' | sha256sum | cut -c1-16)
[ "$(row "$P fail")" = "$SX 2" ] && ok || bad "C1: two failures on box A wrote row '$(row "$P fail")', want '$SX 2'"
CB=$(box CB); printf 'BOARD-X' > "$CB/state/$P.gate.pending"
RC=1 in_rt "$CB" rt_gate_fail_consume
[ "$(cat "$CB/state/$P.gate.json" 2>/dev/null)" = BOARD-X ] && ok || bad "C1: box B's 3rd failure did not consume at cap 3"
grep -q "triage-fail-consume:$P" "$CB/alerts.txt" 2>/dev/null && ok || bad "C1: no alert at the cap on box B"
[ ! -e "$CB/state/$P.gate.fail" ] && [ "$(row "$P fail")" = cleared ] && ok || bad "C1: at the cap the row must read cleared: '$(row "$P fail")'"
[ "$(row "$P" | cut -d' ' -f1)" = "$(sha "$CB/state/$P.gate.json")" ] && ok || bad "C1: consume at the cap did not mirror the gate row"
# C2 — a different pending fingerprint on the new box restarts at 1
setrow "$P fail" "$SX 2"; CC=$(box CC); printf 'BOARD-Y' > "$CC/state/$P.gate.pending"
RC=1 in_rt "$CC" rt_gate_fail_consume
[ "$(sed -n 2p "$CC/state/$P.gate.fail" 2>/dev/null)" = 1 ] && [ ! -e "$CC/state/$P.gate.json" ] && ok \
  || bad "C2: a new fingerprint must restart at 1: $(tr '\n' ' ' < "$CC/state/$P.gate.fail" 2>/dev/null)"
# C3 — the rc=0 launch path clears the row; a later box starts at 1
setrow "$P fail" "$SX 2"; CD=$(box CD); printf 'BOARD-X' > "$CD/state/$P.gate.pending"
lock_run_unheld_stub='lock_run_unheld() { return 0; }; LANE_TICK() { :; }'
( eval "$lock_run_unheld_stub"; PROMPT_TEXT=p EFFECTIVE_GROK_EFFORT= TRIAGE_APPEND= TRIAGE_MODEL=m GATE_DECISION="RUN x" SCOPE_N=0
  in_rt "$CD" rt_launch ) >/dev/null 2>&1
[ "$(row "$P fail")" = cleared ] && ok || bad "C3: a successful launch left the fail row '$(row "$P fail")'"
CE=$(box CE); printf 'BOARD-X' > "$CE/state/$P.gate.pending"; RC=1 in_rt "$CE" rt_gate_fail_consume
[ "$(sed -n 2p "$CE/state/$P.gate.fail" 2>/dev/null)" = 1 ] && ok || bad "C3: after a cleared row a failure must start at 1"

# ══ D — a re-armed ticket is not skipped by a moved box ══════════════════════
reset_ledger; board 2
DA=$(box DA)
gate "$DA" "$P" --seed >/dev/null
( HARNESS="$DA"; . "$DIR/bin/lib/triage-shards-lib.sh"; triage_shard_rearm "$DA" "$P" 7 1 ) >/dev/null 2>&1
jq -e '[.issues[] | .number] | index(7) | not' "$DA/state/$P.gate.json" >/dev/null 2>&1 && ok || bad "D1: setup: the re-arm did not drop #7"
DB=$(box DB)
OUT=$(gate "$DB"); [ "$OUT" = "RUN no-gate-state" ] && ok || bad "D1: a moved box skipped a ticket box A had re-armed: '$OUT'"

# ══ E — adversarial negatives: none of these may SKIP ════════════════════════
reset_ledger; board 2
EA=$(box EA); gate "$EA" "$P" --seed >/dev/null
GOOD=$(row "$P"); [ -n "$GOOD" ] || bad "E: setup: no row"
# E1 flag off: today's answer, zero ledger calls
: > "$TGL_TEST_LEDGER/calls"; E1=$(box E1 off); date +%s > "$E1/state/$P.gate-meta"
OUT=$(gate "$E1"); [ "$OUT" = "RUN no-gate-state" ] && ok || bad "E1: flag off answered '$OUT'"
[ ! -s "$TGL_TEST_LEDGER/calls" ] && ok || bad "E1: flag off made ledger calls: $(calls)"
# E1b flag off on a fresh box: the daily sweep, exactly as today
OUT=$(gate "$(box E1b off)"); [ "$OUT" = "RUN daily-sweep" ] && ok || bad "E1b: flag off fresh box answered '$OUT'"
# E2 local gate.json present: the row is never consulted
: > "$TGL_TEST_LEDGER/calls"; E2=$(box E2); date +%s > "$E2/state/$P.gate-meta"; printf '{"issues":[]}' > "$E2/state/$P.gate.json"
OUT=$(gate "$E2"); grep -q '^RUN board-changed' <<<"$OUT" && ok || bad "E2: local gate differing from the board answered '$OUT'"
! grep -q '^GET' "$TGL_TEST_LEDGER/calls" && ok || bad "E2: the row was read with local files present: $(calls)"
# E3 read outage: today's answers
: > "$TGL_TEST_LEDGER/getfail"
E3=$(box E3); date +%s > "$E3/state/$P.gate-meta"
OUT=$(gate "$E3"); [ "$OUT" = "RUN no-gate-state" ] && ok || bad "E3: GET rc 1 answered '$OUT'"
OUT=$(gate "$(box E3b)"); [ "$OUT" = "RUN daily-sweep" ] && ok || bad "E3b: GET rc 1 on a fresh box answered '$OUT'"
rm -f "$TGL_TEST_LEDGER/getfail"
# E3c malformed row through the real gate
setrow "$P" "abc 12"; E3c=$(box E3c); date +%s > "$E3c/state/$P.gate-meta"
OUT=$(gate "$E3c"); [ "$OUT" = "RUN no-gate-state" ] && ok || bad "E3c: a malformed row answered '$OUT'"
setrow "$P" "$GOOD"
# E4 write outage: the gate is still consumed locally, rc 0
: > "$TGL_TEST_LEDGER/putfail"; E4=$(box E4); printf 'BOARD-Z' > "$E4/state/$P.gate.pending"
in_rt "$E4" rt_gate_consume; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$E4/state/$P.gate.json" 2>/dev/null)" = BOARD-Z ] && ok || bad "E4: PUT rc 1 broke the local consume (rc $rc)"
[ "$(row "$P")" = "$GOOD" ] && ok || bad "E4: a failed PUT changed the row"
rm -f "$TGL_TEST_LEDGER/putfail"
# E5 another project's row never hydrates this one
E5=$(box E5); date +%s > "$E5/state/${P}2.gate-meta"
OUT=$(gate "$E5" "${P}2"); [ "$OUT" = "RUN no-gate-state" ] && ok || bad "E5: ${P}2 was restored from ${P}'s row: '$OUT'"
[ ! -e "$E5/state/${P}2.gate.json" ] && ok || bad "E5: ${P}2 gate.json written"

echo "triage-gate-ledger.bh-2318: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
