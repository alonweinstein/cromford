#!/bin/bash
# tests/failover-drill-contract.bh-2746-test.sh — the contract slice of the
# failover drill (BH-2746, parent #402): the shared seams in
# bin/lib/failover-drill-common.sh, the stubs in
# bin/lib/failover-drill-proofs.sh and the shape of bin/lib/failover-drill-demote.sh.
#
# Sources the REAL libraries from a scratch harness root. fd_api_get runs
# through the REAL bin/jobs-client.sh + bin/lib/jobs/req.sh; only curl is
# stubbed (it records its argv and answers $STUB_BODY / $STUB_CODE / $STUB_RC),
# and ssh is a stub reached through the FAILOVER_DRILL_SSH seam.
#
# Run from anywhere: tests/failover-drill-contract.bh-2746-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: got [$2] want [$3]"; fi; }

H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/flags" "$H/env" "$H/state" "$T/fakebin"
for f in "$DIR/bin/lib/failover-drill-common.sh" "$DIR/bin/lib/failover-drill-proofs.sh" \
         "$DIR/bin/lib/failover-drill-demote.sh" "$DIR/bin/lib/env-path.sh"; do
  cp "$f" "$H/bin/lib/" || { echo "FAIL: missing $f"; exit 1; }
done
cp "$DIR/bin/jobs-client.sh" "$H/bin/" || { echo "FAIL: missing bin/jobs-client.sh"; exit 1; }
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/" || { echo "FAIL: missing bin/lib/jobs"; exit 1; }
: > "$H/env/global.env"
echo testbox > "$H/state/box-name"

cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_DIR/curl.calls"
[ "${STUB_RC:-0}" = 0 ] || exit "$STUB_RC"
printf '%s\n%s' "${STUB_BODY:-}" "${STUB_CODE:-200}"
EOF
cat > "$T/fakebin/ssh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_DIR/ssh.calls"
exit "${SSH_STUB_RC:-0}"
EOF
chmod +x "$T/fakebin/curl" "$T/fakebin/ssh"
export STUB_DIR="$T" PATH="$T/fakebin:$PATH" HARNESS="$H"
LIBS="failover-drill-common failover-drill-proofs failover-drill-demote"

# --- C1: each lib parses, sources silently under set -u, and all three chain --
for f in $LIBS; do
  bash -n "$H/bin/lib/$f.sh"; eq "C1 bash -n $f" "$?" 0
done
for f in $LIBS; do
  out=$(bash -u -c ". '$H/bin/lib/$f.sh'" 2>&1); rc=$?
  if [ "$rc" = 0 ] && [ -z "$out" ]; then ok; else bad "C1 inert $f: rc=$rc out=[$out]"; fi
done
out=$(bash -u -c ". '$H/bin/lib/failover-drill-common.sh' && . '$H/bin/lib/failover-drill-proofs.sh' && . '$H/bin/lib/failover-drill-demote.sh'" 2>&1); rc=$?
if [ "$rc" = 0 ] && [ -z "$out" ]; then ok; else bad "C1 chain: rc=$rc out=[$out]"; fi

# shellcheck source=bin/lib/failover-drill-common.sh
. "$H/bin/lib/failover-drill-common.sh" || exit 1
# shellcheck source=bin/lib/failover-drill-proofs.sh
. "$H/bin/lib/failover-drill-proofs.sh" || exit 1
# shellcheck source=bin/lib/failover-drill-demote.sh
. "$H/bin/lib/failover-drill-demote.sh" || exit 1

# --- C2: every contract function is defined; the flag path is exact ----------
for fn in fd_now fd_iso fd_ssh fd_api_get fd_alert fd_proof_set fd_proof_line \
          fd_proof_poll_commands fd_proof_chat fd_proof_pool fd_proof_ledger \
          fd_promote_back fd_standby_quiet; do
  if declare -F "$fn" >/dev/null; then ok; else bad "C2 $fn not defined"; fi
done
eq "C2b FD_RENEW_PAUSE_FLAG" "${FD_RENEW_PAUSE_FLAG:-<unset>}" "flags/hub-lease-renew-paused"

# --- C3: fd_proof_line prints the exact line; an unset proof under set -u -----
fd_proof_set 3 OK x
eq "C3 line" "$(fd_proof_line 3 pool)" "PROOF 3 pool: OK — x"
out=$(bash -u -c ". '$H/bin/lib/failover-drill-common.sh'; fd_proof_line 7 x" 2>&1); rc=$?
eq "C3 unset rc" "$rc" 0
eq "C3 unset line" "$out" "PROOF 7 x: UNPROVEN — not run"

# --- C4: unknown verdict coerced to FAIL; a non-integer n is refused ----------
fd_proof_set 1 MAYBE y
eq "C4 coerced" "${PROOF_1_VERDICT:-}" FAIL
eq "C4 detail" "${PROOF_1_DETAIL:-}" y
fd_proof_set 2 UNPROVEN z; eq "C4 UNPROVEN kept" "${PROOF_2_VERDICT:-}" UNPROVEN
fd_proof_set 'x;y' OK z 2>/dev/null; eq "C4 bad n rc" "$?" 2
fd_proof_line 'x;y' n >/dev/null 2>&1; eq "C4 bad n line rc" "$?" 2

# --- C5: fd_now honors FAILOVER_DRILL_NOW, refuses a non-integer -------------
NOW=1700000000
eq "C5 pinned" "$(FAILOVER_DRILL_NOW=$NOW fd_now)" "$NOW"
out=$(FAILOVER_DRILL_NOW=abc fd_now); rc=$?
eq "C5 abc rc" "$rc" 1; eq "C5 abc out" "$out" ""
out=$(unset FAILOVER_DRILL_NOW; fd_now)
case "$out" in ''|*[!0-9]*) bad "C5 clock not an integer: [$out]" ;; *) ok ;; esac

# --- C6: fd_iso -------------------------------------------------------------
eq "C6 epoch 0" "$(fd_iso 0)" "1970-01-01T00:00:00Z"
eq "C6 pinned" "$(fd_iso "$NOW")" "2023-11-14T22:13:20Z"
out=$(fd_iso ""); eq "C6 empty rc" "$?" 1; eq "C6 empty out" "$out" ""
fd_iso abc >/dev/null; eq "C6 abc rc" "$?" 1

# --- C7: fd_api_get through the real jobs client, curl stubbed ---------------
export HARNESS_SECRET=s JOBS_URL=http://stub JOBS_RETRIES=0 JOBS_ALERT=0
api() { # api <label> <want-rc: 0|nonzero> <want-out>
  local out rc
  rm -f "$T/curl.calls"
  out=$(fd_api_get /fd/probe); rc=$?
  if [ "$2" = 0 ]; then eq "$1 rc" "$rc" 0; else [ "$rc" != 0 ] && ok || bad "$1: rc 0, want non-zero"; fi
  eq "$1 out" "$out" "$3"
  # One request per call: count GETs, not lines (the -w argument carries a newline).
  local calls=0; [ -f "$T/curl.calls" ] && calls=$(grep -c -- "-X GET" "$T/curl.calls")
  eq "$1 one GET" "$calls" 1
  case "$(cat "$T/curl.calls" 2>/dev/null)" in *"-X GET"*"http://stub/fd/probe"*) ok ;; *) bad "$1: GET http://stub/fd/probe not recorded" ;; esac
}
STUB_CODE=200 STUB_BODY='' api "C7a empty 200" nonzero ""
STUB_CODE=200 STUB_BODY='{"a":1}' api "C7b 200" 0 '{"a":1}'
STUB_CODE=500 STUB_BODY='{"error":"x"}' api "C7c 500" nonzero ""
STUB_RC=7 api "C7d unreachable" nonzero ""
STUB_CODE=404 STUB_BODY='' api "C7e 404" nonzero ""
# The jobs client is loaded in a subshell: the caller's shell gains no verbs.
if declare -F _jobs_req >/dev/null; then bad "C7 _jobs_req leaked into the caller"; else ok; fi

# --- C8: fd_ssh seam ----------------------------------------------------------
export FAILOVER_DRILL_SSH="$T/fakebin/ssh"
rm -f "$T/ssh.calls"
fd_ssh "" true; eq "C8a empty ip rc" "$?" 2
[ -e "$T/ssh.calls" ] && bad "C8a ssh stub was called" || ok
fd_ssh 10.0.0.1 echo hi; eq "C8b rc" "$?" 0
eq "C8b argv" "$(cat "$T/ssh.calls" 2>/dev/null)" "root@10.0.0.1 echo hi"
SSH_STUB_RC=5 fd_ssh 10.0.0.1 false; eq "C8c ssh rc verbatim" "$?" 5

# --- C9: the proofs, offline (BH-2747 filled the stubs) ----------------------
unset PROOF_1_VERDICT PROOF_2_VERDICT PROOF_3_VERDICT PROOF_4_VERDICT
CONSOLE_URL= JOBS_URL= FAILOVER_DRILL_POOL_PROJECT= fd_proof_poll_commands r 1.2.3.4; eq "C9 poll rc" "$?" 0
CONSOLE_URL= JOBS_URL= FAILOVER_DRILL_POOL_PROJECT= fd_proof_chat r 1.2.3.4;          eq "C9 chat rc" "$?" 0
CONSOLE_URL= JOBS_URL= FAILOVER_DRILL_POOL_PROJECT= fd_proof_pool r;                  eq "C9 pool rc" "$?" 0
CONSOLE_URL= JOBS_URL= FAILOVER_DRILL_POOL_PROJECT= fd_proof_ledger r hub sb 1 2 60;  eq "C9 ledger rc" "$?" 0
for n in 1 2 3 4; do
  v="PROOF_${n}_VERDICT"; d="PROOF_${n}_DETAIL"
  eq "C9 proof $n verdict" "${!v:-<unset>}" UNPROVEN
  case "${!d:-}" in ""|"not implemented") bad "C9 proof $n detail: [${!d:-}]" ;; *) ok ;; esac
done

# --- C10: the demote functions keep their contract shape ---------------------
# BH-2748 filled the stubs; tests/failover-drill-demote.bh-2748-test.sh pins the
# behaviour. These two calls touch no network: an empty hub or ip stops first.
unset FD_DEMOTE_DETAIL FD_DEMOTE_VERDICT FD_DEMOTE_UNOBSERVABLE FD_T_BACK
rm -f "$T/ssh.calls" "$T/curl.calls"
fd_promote_back r ""; eq "C10 promote_back rc" "$?" 1
[ -n "${FD_DEMOTE_DETAIL:-}" ] && ok || bad "C10 promote_back detail empty"
eq "C10 no FD_T_BACK" "${FD_T_BACK:-<unset>}" "<unset>"
unset FD_DEMOTE_DETAIL
fd_standby_quiet s "" 0; eq "C10 standby_quiet rc" "$?" 1
eq "C10 verdict" "${FD_DEMOTE_VERDICT:-<unset>}" UNPROVEN
[ -n "${FD_DEMOTE_DETAIL:-}" ] && ok || bad "C10 standby_quiet detail empty"
eq "C10 unobservable set" "${FD_DEMOTE_UNOBSERVABLE-<unset>}" ""
[ -e "$T/ssh.calls" ] || [ -e "$T/curl.calls" ] && bad "C10 a demote call reached ssh or curl" || ok

# --- C11: fd_alert appends one tagged UTC line --------------------------------
: > "$H/logs/ALERTS.log"
fd_alert "hello"
eq "C11 one line" "$(wc -l < "$H/logs/ALERTS.log")" 1
if [[ "$(cat "$H/logs/ALERTS.log")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z\ failover-drill:\ hello$ ]]; then ok
else bad "C11 line shape: [$(cat "$H/logs/ALERTS.log")]"; fi

echo "failover-drill-contract.bh-2746: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
