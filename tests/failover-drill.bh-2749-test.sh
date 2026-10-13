#!/bin/bash
# tests/failover-drill.bh-2749-test.sh — the drill script of the failover drill
# (BH-2749, parent #402): args, lock, preflight refusals, spend guard, the
# renew/ping pause and the wait for the watchdog promote, the old-hub demote
# check, the proof and promote-back calls, the finalizer, the report, the
# marker and the beat.
#
# Runs the REAL bin/failover-drill.sh with the REAL
# bin/lib/failover-drill-common.sh, bin/jobs-client.sh and bin/lib/jobs/ in a
# scratch harness root. The suite writes its OWN
# bin/lib/failover-drill-proofs.sh and bin/lib/failover-drill-demote.sh whose
# functions log to $T/seq.log and take their verdicts from env knobs, so the
# orchestration is tested apart from the sibling slices (#2747, #2748).
# Stubbed: curl (plays the jobs worker), ssh, sleep and date (a fake clock in
# $T/clock: `date -u +%s` reads it and ticks one second, sleep adds its
# argument, so no test waits on the wall clock), bin/hub-lease.sh,
# bin/fleet-conf.sh and bin/beat.sh.
#
# Run from anywhere: tests/failover-drill.bh-2749-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: got [$2] want [$3]"; fi; }

H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/state" "$H/flags" "$H/env" "$H/locks" "$T/fakebin"
cp "$DIR/bin/failover-drill.sh" "$H/bin/" || { echo "FAIL: missing bin/failover-drill.sh"; exit 1; }
for f in failover-drill-common env-path hub-box; do
  cp "$DIR/bin/lib/$f.sh" "$H/bin/lib/" || { echo "FAIL: missing bin/lib/$f.sh"; exit 1; }
done
cp "$DIR/bin/jobs-client.sh" "$H/bin/" || { echo "FAIL: missing bin/jobs-client.sh"; exit 1; }
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/" || { echo "FAIL: missing bin/lib/jobs"; exit 1; }
printf 'HARNESS_SECRET=s\nJOBS_URL=http://stub\nJOBS_RETRIES=0\nJOBS_ALERT=0\n' > "$H/env/global.env"

# Test-local proofs: log name + args, note whether the poll-commands flag was
# up while the proof ran, and take the verdict from PROOF_<n>_STUB (default OK).
cat > "$H/bin/lib/failover-drill-proofs.sh" <<'EOF'
_stub_proof() {
  local n=$1 name=$2; shift 2
  local f=off; [ -e "$HARNESS/flags/lane-off-poll-commands" ] && f=on
  local pz=off; [ -e "$HARNESS/flags/hub-lease-renew-paused" ] || [ -e "$HARNESS/flags/lane-off-watchdog-ping" ] && pz=on
  printf '%s %s pcflag=%s pause=%s\n' "$name" "$*" "$f" "$pz" >> "$STUB_DIR/seq.log"
  local v="PROOF_${n}_STUB"
  fd_proof_set "$n" "${!v:-OK}" "stub $name"
}
fd_proof_poll_commands() { _stub_proof 1 proof_poll_commands "$@"; }
fd_proof_chat()          { _stub_proof 2 proof_chat "$@"; }
fd_proof_pool()          { _stub_proof 3 proof_pool "$@"; }
fd_proof_ledger()        { _stub_proof 4 proof_ledger "$@"; }
EOF
cat > "$H/bin/lib/failover-drill-demote.sh" <<'EOF'
fd_promote_back() {
  printf 'promote_back %s\n' "$*" >> "$STUB_DIR/seq.log"
  if [ "${PROMOTE_BACK_RC:-0}" = 0 ]; then FD_T_BACK=$(fd_now); return 0; fi
  FD_DEMOTE_DETAIL="stub refused"; return 1
}
fd_standby_quiet() {
  printf 'standby_quiet %s\n' "$*" >> "$STUB_DIR/seq.log"
  FD_DEMOTE_VERDICT=${QUIET_STUB:-OK}; FD_DEMOTE_DETAIL="stub quiet"; FD_DEMOTE_UNOBSERVABLE="lane-x"
  [ "$FD_DEMOTE_VERDICT" = OK ]
}
EOF

# hub-lease.sh check: rc per call from LEASE_CHECK_SEQ (the last one repeats).
cat > "$H/bin/hub-lease.sh" <<'EOF'
#!/bin/bash
printf 'hub_lease %s\n' "$*" >> "$STUB_DIR/seq.log"
n=$(cat "$STUB_DIR/lease.n" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$STUB_DIR/lease.n"
read -r -a s <<< "${LEASE_CHECK_SEQ:-0 1}"
i=$((n-1)); [ "$i" -lt "${#s[@]}" ] || i=$((${#s[@]}-1))
exit "${s[$i]}"
EOF
cat > "$H/bin/fleet-conf.sh" <<'EOF'
#!/bin/bash
case "$1" in
  --standby) printf '%s' "${STANDBY_LINES-sb-box box-hub id1
}" ;;
  --tailnet-ip-of-box) [ -n "${SB_IP-10.0.0.13}" ] || exit 1; echo "${SB_IP-10.0.0.13}" ;;
  *) exit 1 ;;
esac
EOF
# beat.sh: records the beat and whether the marker and its report already exist.
cat > "$H/bin/beat.sh" <<'EOF'
#!/bin/bash
m=no r=no mk="$HARNESS/state/failover-drill-last.json"
[ -s "$mk" ] && m=yes && rp=$(jq -r '.report' "$mk") && [ -s "$rp" ] && r=yes
printf 'BEAT marker=%s report=%s %s\n' "$m" "$r" "$1" >> "$STUB_DIR/seq.log"
EOF

# curl playing the jobs worker. The recovery answer for the n-th GET is word n
# of RECOVERY_SEQ (the last one repeats), or $T/recovery.override when present.
# Words: <holder>:<epoch>, FAIL (transport error), EMPTY (200, no body), NULL.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_DIR/curl.calls"
url=""; for a in "$@"; do case "$a" in http*) url=$a ;; esac; done
p=${url#http://stub}
case "$p" in
  /api/settings/hub.promote_enabled)
    printf '{"setting":{"key":"hub.promote_enabled","value":"%s"}}\n200' "${PROMOTE_ENABLED-1}" ;;
  /api/hub/recovery)
    n=$(cat "$STUB_DIR/rec.n" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$STUB_DIR/rec.n"
    read -r -a s <<< "${RECOVERY_SEQ:-box-hub:5}"
    i=$((n-1)); [ "$i" -lt "${#s[@]}" ] || i=$((${#s[@]}-1))
    w=${s[$i]}; [ -s "$STUB_DIR/recovery.override" ] && w=$(cat "$STUB_DIR/recovery.override")
    pf=ABSENT; [ -f "$HARNESS/flags/hub-lease-renew-paused" ] && pf=$(cat "$HARNESS/flags/hub-lease-renew-paused")
    wp=no; [ -e "$HARNESS/flags/lane-off-watchdog-ping" ] && wp=yes
    printf 'recovery %s %s pause=%s ping=%s\n' "$n" "$w" "$pf" "$wp" >> "$STUB_DIR/seq.log"
    [ "${DELETE_PAUSE_AT:-}" = "$n" ] && rm -f "$HARNESS/flags/hub-lease-renew-paused"
    case "$w" in
      FAIL) exit 7 ;;
      EMPTY) printf '\n200' ;;
      NULL) printf '{"lease":null,"recent_changes":[]}\n200' ;;
      *) h=${w%%:*} e=${w#*:}
         printf '{"lease":{"holder":"%s","epoch":%s},"recent_changes":[{"action":"renew","after_holder":"%s","after_epoch":%s,"actor":"hub","at":"x"},{"action":"promote","after_holder":"%s","after_epoch":%s,"actor":"watchdog","at":"2026-09-27T01:02:03Z"}]}\n200' \
           "$h" "$e" "$h" "$e" "$h" "$e" ;;
    esac ;;
  *) printf '{}\n404' ;;
esac
EOF
cat > "$T/fakebin/ssh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_DIR/ssh.calls"
exit "${SSH_RC:-0}"
EOF
# sleep: adds its argument to the fake clock. On call SLEEP_BLOCK_AT it marks
# itself blocked and waits on the fifo, so a signal can land mid-wait.
cat > "$T/fakebin/sleep" <<'EOF'
#!/bin/bash
n=$(cat "$STUB_DIR/sleep.n" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$STUB_DIR/sleep.n"
[ -n "${CLOCK_FROZEN:-}" ] || echo $(( $(cat "$STUB_DIR/clock") + ${1%%.*} )) > "$STUB_DIR/clock"
if [ "${SLEEP_BLOCK_AT:-}" = "$n" ]; then : > "$STUB_DIR/sleep.blocked"; read -r _ < "$STUB_DIR/fifo"; fi
exit 0
EOF
# date: `-u +%s` is the fake clock (ticking one second per read); anything else
# is the real date (fd_iso renders a given epoch, it never reads the clock).
cat > "$T/fakebin/date" <<'EOF'
#!/bin/bash
if [ "$*" = "-u +%s" ]; then c=$(cat "$STUB_DIR/clock"); [ -n "${CLOCK_FROZEN:-}" ] || echo $((c+1)) > "$STUB_DIR/clock"; echo "$c"; exit 0; fi
exec /bin/date "$@"
EOF
chmod +x "$H/bin/"*.sh "$T/fakebin/"*
mkfifo "$T/fifo"

# One captured anchor: 2026-09-27T00:00:00Z. Every run starts its clock here.
ANCHOR=1790467200
DAY=2026-09-27
RD="$H/state/failover-drill"
MARK="$H/state/failover-drill-last.json"
SEQ="$T/seq.log"
ALERTS="$H/logs/ALERTS.log"
LOCK="$H/locks/failover-drill.lock"
KNOBS="FAILOVER_DRILL_PROMOTE_DEADLINE_S FAILOVER_DRILL_POLL_S FAILOVER_DRILL_DEMOTE_SETTLE_S FAILOVER_DRILL_MIN_INTERVAL_H"

reset() {
  local p
  for p in "$SEQ" "$T"/curl.calls "$T"/ssh.calls "$T"/*.n "$T/sleep.blocked" "$T/recovery.override" \
           "$MARK" "$ALERTS" "$H/logs/failover-drill.log" "$RD" "$H/flags" "$H/state/box-name"; do
    scratch_rm "$p" || exit 1
  done
  mkdir -p "$H/flags"
  : > "$H/flags/failover-drill-ok"
  echo box-hub > "$H/state/box-name"
  echo "$ANCHOR" > "$T/clock"
  # shellcheck disable=SC2086
  unset $KNOBS RECOVERY_SEQ LEASE_CHECK_SEQ STANDBY_LINES SB_IP SSH_RC PROMOTE_ENABLED PROMOTE_BACK_RC QUIET_STUB \
        PROOF_1_STUB PROOF_2_STUB PROOF_3_STUB PROOF_4_STUB DELETE_PAUSE_AT SLEEP_BLOCK_AT CLOCK_FROZEN
  export FAILOVER_DRILL_PROMOTE_DEADLINE_S=300 FAILOVER_DRILL_POLL_S=30 FAILOVER_DRILL_DEMOTE_SETTLE_S=90
  export RECOVERY_SEQ="box-hub:5 box-hub:5 sb-box:6"
}
# timeout: an unbounded wait loop is a failed case, not a hung suite.
drill() { HARNESS="$H" STUB_DIR="$T" PATH="$T/fakebin:$PATH" timeout 60 bash "$H/bin/failover-drill.sh" "$@" >"$T/out" 2>"$T/err"; }
cnt()  { [ -f "$2" ] || { echo 0; return 0; }; grep -cE "$1" "$2"; return 0; }
nrec() { cnt '^recovery ' "$SEQ"; }
lno()  { grep -nE "$1" "$SEQ" 2>/dev/null | head -1 | cut -d: -f1; }
mk()   { jq -r "$1" "$MARK" 2>/dev/null; }
rep()  { cat "$(mk .report)" 2>/dev/null; }
tl()   { rep | awk -F' *\\| *' -v k="$1" '$2==k {print $3}'; }   # timeline cell of stage k
flags_left() { find "$H/flags" -type f ! -name failover-drill-ok | wc -l | tr -d ' '; }
before() { local a b; a=$(lno "$2"); b=$(lno "$3"); if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then ok; else bad "$1: [$2]@${a:-none} not before [$3]@${b:-none}"; fi; }
refused() { # refused <label> — the shape every refusal shares
  eq "$1 rc" "$rc" 3
  eq "$1 stderr lines" "$(wc -l < "$T/err" | tr -d ' ')" 1
  grep -q '^failover drill refused: ' "$T/err" && ok || bad "$1 stderr=[$(cat "$T/err")]"
  eq "$1 ALERTS lines" "$(cnt ' failover-drill: refused: ' "$ALERTS")" 1
  eq "$1 flags written" "$(flags_left)" 0
  [ -e "$H/flags/failover-drill-ok" ] && ok || bad "$1 ok-flag was consumed"
  [ -e "$MARK" ] && bad "$1 wrote a marker" || ok
  eq "$1 beats" "$(cnt '^BEAT ' "$SEQ")" 0
}

# --- A: arguments and lock ---------------------------------------------------
reset; drill --bogus; rc=$?
eq "A1 rc" "$rc" 2; grep -q '^usage: bin/failover-drill.sh' "$T/err" && ok || bad "A1 no usage: [$(cat "$T/err")]"
reset; drill --report-dir; eq "A2 rc" "$?" 2
reset; drill --help; eq "A4 help rc" "$?" 0
grep -q 'exit codes' "$T/out" && ok || bad "A4 help does not print the header"
reset
exec 8>"$LOCK"; flock -n 8 || bad "A3 test could not take the lock"
drill; rc=$?
exec 8>&-
eq "A3 rc" "$rc" 0; eq "A3 out" "$(cat "$T/out")" "already running"
[ -e "$SEQ" ] && bad "A3 did work under a held lock" || ok

# --- R: refusals -------------------------------------------------------------
reset; rm -f "$H/flags/failover-drill-ok"; drill; rc=$?
eq "R1 rc" "$rc" 3; grep -q 'flags/failover-drill-ok' "$T/err" && ok || bad "R1 err=[$(cat "$T/err")]"
eq "R1 flags" "$(find "$H/flags" -type f | wc -l | tr -d ' ')" 0
[ -e "$T/curl.calls" ] && bad "R1 made a curl call" || ok
eq "R1 ALERTS" "$(cnt ' failover-drill: refused: ' "$ALERTS")" 1
reset; echo other-box > "$H/state/box-name"; drill; rc=$?; refused R2
grep -q 'this box (other-box) is not the hub (box-hub)' "$T/err" && ok || bad "R2 err=[$(cat "$T/err")]"
reset; export STANDBY_LINES=""; drill; rc=$?; refused R3a
grep -q 'need exactly one standby for box-hub, found 0' "$T/err" && ok || bad "R3a err=[$(cat "$T/err")]"
reset; export STANDBY_LINES=$'a box-hub 1\nb box-hub 2\nc other-hub 3\n'; drill; rc=$?; refused R3b
grep -q 'found 2' "$T/err" && ok || bad "R3b err=[$(cat "$T/err")]"
reset; export SB_IP=""; drill; rc=$?; refused R4
[ -e "$T/ssh.calls" ] && bad "R4 ssh was called" || ok
reset; export PROMOTE_ENABLED=0; drill; rc=$?; refused R5
grep -q 'hub.promote_enabled' "$T/err" && ok || bad "R5 err=[$(cat "$T/err")]"
reset; export FAILOVER_DRILL_PROMOTE_DEADLINE_S=1740; drill; rc=$?; refused R5b
grep -q 'FAILOVER_DRILL_PROMOTE_DEADLINE_S.*1740' "$T/err" && ok || bad "R5b err=[$(cat "$T/err")]"
[ -e "$T/curl.calls" ] && bad "R5b made a call" || ok
reset; export FAILOVER_DRILL_POLL_S=abc; drill; rc=$?; refused R5c
reset; export SSH_RC=255; drill; rc=$?; refused R7
reset; export LEASE_CHECK_SEQ=1; drill; rc=$?; refused R8
reset; export RECOVERY_SEQ=FAIL; drill; rc=$?; refused R9
grep -q 'cannot read the start epoch' "$T/err" && ok || bad "R9 err=[$(cat "$T/err")]"
reset; export RECOVERY_SEQ=NULL; drill; rc=$?; refused R9b

# R6: the spend guard, before any call; --force goes past it.
reset
printf '{"ts":%s,"verdict":"PASS","detail":"x","report":"r"}\n' $((ANCHOR-3600)) > "$MARK"
before_mark=$(cat "$MARK")
drill; rc=$?
eq "R6 rc" "$rc" 0
grep -q 'newer than 24h; --force to run anyway' "$T/out" && ok || bad "R6 out=[$(cat "$T/out")]"
[ -e "$T/curl.calls" ] || [ -e "$T/ssh.calls" ] && bad "R6 made a call" || ok
eq "R6 marker unchanged" "$(cat "$MARK")" "$before_mark"
eq "R6 flags" "$(flags_left)" 0
drill --force; rc=$?
[ -s "$T/curl.calls" ] && ok || bad "R6 --force made no call"
eq "R6 --force rc" "$rc" 0

# --- P1 / V1: the whole happy path -------------------------------------------
reset; export DELETE_PAUSE_AT=2; drill; rc=$?   # GET 1 is the preflight read; 2 and 3 are waits
eq "P1 rc" "$rc" 0
eq "P1 verdict" "$(mk .verdict)" PASS
eq "V1 proof lines" "$(rep | grep -c '^PROOF [1-4] ')" 4
rep | grep -q '^Verdict: PASS$' && ok || bad "V1 no 'Verdict: PASS'"
eq "V1 default report path" "$(mk .report)" "$RD/FAILOVER-DRILL-$DAY.md"
eq "V1 marker ts" "$(mk .ts)" "$ANCHOR"
eq "V1 beats" "$(cnt '^BEAT ' "$SEQ")" 1
grep -q 'marker=yes report=yes .*"verdict":"PASS"' <(grep '^BEAT ' "$SEQ") && ok || bad "V1 beat=[$(grep '^BEAT ' "$SEQ")]"
eq "V1 log lines" "$(cnt " fd-20260927T000000Z PASS " "$H/logs/failover-drill.log")" 1
[ -e "$H/flags/failover-drill-ok" ] && ok || bad "V1 ok-flag consumed"
eq "P1 flags left" "$(flags_left)" 0
[ -e "$ALERTS" ] && bad "P1 ALERTS=[$(cat "$ALERTS")]" || ok
tp=$(tl t_pause); tr=$(tl t_promote); tu=$(tl t_unpause)
if [ -n "$tp" ] && [ -n "$tr" ] && [ -n "$tu" ] && [[ "$tp" < "$tr" ]] && [[ "$tr" < "$tu" ]]; then ok; else bad "P1 timeline pause=$tp promote=$tr unpause=$tu"; fi
rep | grep -q 'hub_lease_changes: actor watchdog at 2026-09-27T01:02:03Z' && ok || bad "P1 hub_lease_changes row not in the report"
rep | grep -q 'unobservable: lane-x' && ok || bad "P1 unobservable not reported"
# The pause flag: deadline = t_pause clock + DEADLINE + 120; re-asserted after the stub removed it.
pf=$(grep '^recovery 2 ' "$SEQ" | sed 's/.* pause=\([^ ]*\) .*/\1/')
[[ "$pf" =~ ^[0-9]+$ ]] && [ "$pf" -ge $((ANCHOR+300+120)) ] && [ "$pf" -le $((ANCHOR+300+120+20)) ] && ok || bad "P1 pause flag content [$pf]"
eq "P1 pause re-asserted" "$(grep '^recovery 3 ' "$SEQ" | sed 's/.* pause=\([^ ]*\) .*/\1/')" "$pf"
grep -q '^recovery 2 .* ping=yes' "$SEQ" && ok || bad "P1 watchdog-ping lane not off during the wait"
before "P1 order" '^proof_poll_commands ' '^proof_chat '
before "P1 order" '^proof_chat ' '^proof_pool '
before "P1 order" '^proof_pool ' '^promote_back '
before "P1 order" '^promote_back ' '^proof_ledger '
before "P1 order" '^proof_ledger ' '^standby_quiet '
before "P1 order" '^standby_quiet ' '^BEAT '
eq "P1 poll-commands off during proofs" "$(cnt 'pcflag=on' "$SEQ")" 4
eq "P1 pause flags gone once promoted" "$(cnt '^proof_.* pause=off$' "$SEQ")" 4
eq "P1 promote_back args" "$(grep '^promote_back ' "$SEQ")" "promote_back fd-20260927T000000Z box-hub"
eq "P1 proof_poll_commands args" "$(grep '^proof_poll_commands ' "$SEQ" | cut -d' ' -f2-3)" "fd-20260927T000000Z 10.0.0.13"
lg=$(grep '^proof_ledger ' "$SEQ" | cut -d' ' -f2-7)
read -r _ lhub lsb lprom lback lsettle <<< "$lg"
eq "P1 ledger hub/standby/settle" "$lhub $lsb $lsettle" "box-hub sb-box 90"
[[ "$lprom" =~ ^[0-9]+$ ]] && [[ "$lback" =~ ^[0-9]+$ ]] && [ "$lprom" -lt "$lback" ] && ok || bad "P1 ledger window [$lprom,$lback]"
eq "P1 ledger t_promote = report t_promote" "$(TZ=UTC printf '%(%Y-%m-%dT%H:%M:%SZ)T' "${lprom:-0}")" "$tr"

# --- V2 / V3: verdicts -------------------------------------------------------
reset; export PROOF_3_STUB=UNPROVEN; drill; rc=$?
eq "V2 rc" "$rc" 1; rep | grep -q '^Verdict: INCOMPLETE$' && ok || bad "V2 not INCOMPLETE"; eq "V2 marker" "$(mk .verdict)" INCOMPLETE
reset; export PROOF_2_STUB=FAIL PROOF_3_STUB=UNPROVEN; drill; rc=$?
eq "V3 rc" "$rc" 1; rep | grep -q '^Verdict: FAIL$' && ok || bad "V3 not FAIL"
reset; export QUIET_STUB=UNPROVEN; drill; rc=$?
eq "V3b quiet UNPROVEN rc" "$rc" 1; eq "V3b verdict" "$(mk .verdict)" INCOMPLETE

# --- V4: a report is never overwritten ---------------------------------------
reset; mkdir -p "$RD"; printf 'earlier run\n' > "$RD/FAILOVER-DRILL-$DAY.md"
drill; rc=$?
eq "V4 old report kept" "$(cat "$RD/FAILOVER-DRILL-$DAY.md")" "earlier run"
eq "V4 suffixed report" "$(mk .report)" "$RD/FAILOVER-DRILL-$DAY-000000Z.md"
[ -s "$RD/FAILOVER-DRILL-$DAY-000000Z.md" ] && ok || bad "V4 suffixed report missing"
reset; mkdir -p "$T/rd"; drill --report-dir "$T/rd"; rc=$?
eq "V4b --report-dir" "$(mk .report)" "$T/rd/FAILOVER-DRILL-$DAY.md"

# --- P2: never promoted ------------------------------------------------------
reset; export RECOVERY_SEQ="box-hub:5"; drill; rc=$?
eq "P2 rc" "$rc" 1; eq "P2 verdict" "$(mk .verdict)" FAIL
mk .detail | grep -q 'watchdog never promoted within 300s (is KV cfg:failover=on' && ok || bad "P2 detail=[$(mk .detail)]"
eq "P2 flags" "$(flags_left)" 0
n=$(nrec); [ "$n" -le $((300/30+2)) ] && [ "$n" -ge 3 ] && ok || bad "P2 recovery GETs=$n"
eq "P2 no proofs" "$(cnt '^(proof_|promote_back)' "$SEQ")" 0
rep | grep -q '^Verdict: FAIL$' && ok || bad "P2 report verdict"

# P2b: a clock that never moves still ends the wait, on the poll count alone.
reset; export RECOVERY_SEQ="box-hub:5" CLOCK_FROZEN=1; drill; rc=$?; unset CLOCK_FROZEN
eq "P2b rc" "$rc" 1; mk .detail | grep -q 'cfg:failover' && ok || bad "P2b detail=[$(mk .detail)]"
n=$(nrec); [ "$n" -le $((300/30+3)) ] && ok || bad "P2b recovery GETs=$n with a frozen clock"

# --- N: adversarial promote negatives ----------------------------------------
reset; export RECOVERY_SEQ="box-hub:5 other-box:6"; drill; rc=$?
eq "N1 rc" "$rc" 1; mk .detail | grep -q 'promoted to other-box, not the declared standby sb-box' && ok || bad "N1 detail=[$(mk .detail)]"
eq "N1 no promote_back" "$(cnt '^promote_back' "$SEQ")" 0
eq "N1 one ALERTS line" "$(cnt 'other-box' "$ALERTS")" 1
eq "N1 no stopped-with" "$(cnt 'stopped with' "$ALERTS")" 0
reset; export RECOVERY_SEQ="box-hub:5 box-hub:6"; drill; rc=$?
eq "N2 rc" "$rc" 1; mk .detail | grep -q 'cfg:failover' && ok || bad "N2 detail=[$(mk .detail)]"
eq "N2 no proofs" "$(cnt '^(proof_|promote_back)' "$SEQ")" 0
reset; export RECOVERY_SEQ="box-hub:5 sb-box:5"; drill; rc=$?
eq "N2b stale standby row rc" "$rc" 1; eq "N2b no proofs" "$(cnt '^proof_' "$SEQ")" 0
reset; export LEASE_CHECK_SEQ=0; drill; rc=$?
eq "N3 rc" "$rc" 1; eq "N3 detail" "$(mk .detail)" "old hub still believes it holds the lease"
eq "N3 no proofs" "$(cnt '^(proof_|promote_back)' "$SEQ")" 0
eq "N3 stopped-with" "$(cnt 'stopped with sb-box holding the lease at epoch 6; to fail back run: bin/hub-lease.sh promote --holder box-hub --override-live-lease' "$ALERTS")" 1
eq "N3 flags" "$(flags_left)" 0
# N4: a failed read, an empty body, a null lease and a null epoch are never a
# promote; only GET 6 (the standby at a moved epoch) is. 1 preflight + 5 waits,
# and no finalizer read because the promote-back succeeded.
reset; export RECOVERY_SEQ="box-hub:5 FAIL EMPTY NULL box-hub:null sb-box:6"; drill; rc=$?
eq "N4 rc" "$rc" 0; eq "N4 recovery GETs" "$(nrec)" 6
before "N4 promote only after GET 6" '^recovery 6 ' '^proof_poll_commands '

# --- D1: promote-back fails ---------------------------------------------------
reset; export PROMOTE_BACK_RC=1; drill; rc=$?
eq "D1 rc" "$rc" 1; eq "D1 verdict" "$(mk .verdict)" FAIL
eq "D1 no ledger/quiet" "$(cnt '^(proof_ledger|standby_quiet)' "$SEQ")" 0
rep | grep -q 'promote-back failed: stub refused' && ok || bad "D1 report lacks promote-back failed"
rep | grep -q '^PROOF 4 ledger: UNPROVEN — no promote-back$' && ok || bad "D1 proof 4 line"

# --- P3: TERM mid-wait, lease still on the hub, then on the standby ----------
p3() { # p3 <label> <override-or-empty>
  reset; export SLEEP_BLOCK_AT=2 RECOVERY_SEQ=box-hub:5
  HARNESS="$H" STUB_DIR="$T" PATH="$T/fakebin:$PATH" bash "$H/bin/failover-drill.sh" >"$T/out" 2>"$T/err" &
  local pid=$! i=0
  while [ ! -e "$T/sleep.blocked" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i+1)); done
  [ -e "$T/sleep.blocked" ] || bad "$1 drill never reached the wait"
  [ -n "$2" ] && echo "$2" > "$T/recovery.override"
  kill -TERM "$pid" 2>/dev/null
  [ -e "$T/sleep.blocked" ] && echo go > "$T/fifo"   # only a blocked stub is a reader
  wait "$pid"; rc=$?
  eq "$1 rc" "$rc" 1
  eq "$1 flags removed" "$(flags_left)" 0
  eq "$1 no promote_back" "$(cnt '^promote_back' "$SEQ")" 0
  eq "$1 verdict" "$(mk .verdict)" FAIL; eq "$1 detail" "$(mk .detail)" "interrupted by TERM"
  eq "$1 beats" "$(cnt '^BEAT marker=yes report=yes ' "$SEQ")" 1
}
p3 P3a ""
eq "P3a no stopped-with" "$(cnt 'stopped with' "$ALERTS")" 0
p3 P3b "sb-box:6"
eq "P3b one stopped-with" "$(cnt 'stopped with sb-box holding the lease at epoch 6' "$ALERTS")" 1

echo "failover-drill.bh-2749: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
