#!/bin/bash
# tests/remediation-hook-test.sh — bin/beat.sh's pre-emptive remediation hook.
#
# The hook exists to stop four mechanically self-clearing alert classes from
# reaching a phone. Its ONE non-negotiable property is the opposite one: a
# handler must never be able to swallow an alert it did not prove settled. So
# most of what follows is failure cases — missing handler, crash, timeout,
# non-zero exit, kill switch — each asserting the alert still lands in the
# quarantine file exactly as it does today.
#
# Everything runs against a tmp harness (HARNESS=$T, commit 667b3c2's lesson):
# these assertions must never write the real ALERTS.log or the real quarantine
# file, and the last check in this file proves they didn't.
# Run from anywhere: tests/remediation-hook-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SRC="$DIR/bin/beat.sh"
mkdir -p "$T/bin/remediations" "$T/logs" "$T/state" "$T/flags" "$T/env" "$T/fakebin"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required by this test"; exit 1; }

# Real-file tripwire: snapshot the live artifacts BEFORE anything runs.
REALQ=/root/harness/state/alert-quarantine.jsonl
REALA=/root/harness/logs/ALERTS.log
snap() { [ -f "$1" ] && stat -c '%Y %s' "$1" || echo absent; }
Q0=$(snap "$REALQ"); A0=$(snap "$REALA")

cp "$SRC" "$T/bin/beat.sh"
# `timeout 60` is beat.sh's bound on a handler. Shrink it to 2s here so the
# timeout case is a REAL SIGTERM rather than a mocked exit code, without making
# the suite take a minute.
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
shift              # drop beat.sh's 60
exec /usr/bin/timeout 2 "$@"
EOF
chmod +x "$T/fakebin/timeout"

Q="$T/state/alert-quarantine.jsonl"
RLOG="$T/logs/remediation.log"

handler() { # handler <name> <body>
  printf '#!/bin/bash\n%s\n' "$2" > "$T/bin/remediations/$1.sh"
  chmod +x "$T/bin/remediations/$1.sh"
}

payload() { # payload <akey> [extra-json-fragment]
  jq -nc --arg k "$1" '{kind:"fleet_alert",project:"x-os",akey:$k,line:"a line about \($k)"}'
}

fire() { # fire <payload-json> — run beat.sh against the tmp harness
  HARNESS="$T" PATH="$T/fakebin:$PATH" bash "$T/bin/beat.sh" "$1"
}

reset() { : > "$Q"; : > "$RLOG"; rm -f "$T/state/remediation-attempts.tsv"; rm -f "$T/flags/remediation-disabled"; }

quarantined() { grep -qF "\"akey\":\"$1\"" "$Q" 2>/dev/null; }
logged()      { grep -qE "	$1	.*	$2" "$RLOG" 2>/dev/null; }

# ---------- 0. beat.sh never fails its caller, whatever a handler does -------
reset
handler kaboom 'exit 7'
fire "$(payload 'kaboom:1')" ; RC=$?
[ "$RC" -eq 0 ] && ok || bad "beat.sh returned rc=$RC — it must never fail its caller"

# ---------- 1. exit 0 suppresses ---------------------------------------------
reset
handler settled 'echo "machine is gone"; exit 0'
fire "$(payload 'settled:m1')"
if quarantined 'settled:m1'; then bad "exit 0 did not suppress — alert was quarantined"
else ok; fi
logged 'settled:m1' 'REMEDIATED' && ok || bad "exit 0 not logged as REMEDIATED: $(cat "$RLOG")"
grep -q 'machine is gone' "$RLOG" && ok || bad "handler's own summary line missing from remediation.log"

# ---------- 2. exit 10 suppresses, as a TERMINAL state -----------------------
reset
handler terminal 'echo "RESULT=BUILD_DEFERRED"; exit 10'
fire "$(payload 'terminal:b1')"
if quarantined 'terminal:b1'; then bad "exit 10 did not suppress"
else ok; fi
logged 'terminal:b1' 'TERMINAL' && ok || bad "exit 10 not logged as TERMINAL: $(cat "$RLOG")"

# ---------- 3. exit 1 still emits --------------------------------------------
reset
handler unsure 'echo "not provably gone"; exit 1'
fire "$(payload 'unsure:m2')"
quarantined 'unsure:m2' && ok || bad "exit 1 swallowed the alert — fail-open is broken"
logged 'unsure:m2' 'FAILOPEN' && ok || bad "exit 1 not logged as FAILOPEN"

# ---------- 4. missing handler still emits (and spends no throttle budget) ---
reset
fire "$(payload 'nohandler:z')"
quarantined 'nohandler:z' && ok || bad "namespace with no handler was suppressed"
[ ! -s "$T/state/remediation-attempts.tsv" ] && ok \
  || bad "a namespace with no handler burned a throttle claim: $(cat "$T/state/remediation-attempts.tsv" 2>/dev/null)"

# ---------- 5. a crashing handler still emits --------------------------------
reset
handler crash 'kill -9 $$'
fire "$(payload 'crash:c1')"
quarantined 'crash:c1' && ok || bad "a handler killed mid-run suppressed the alert"

# a handler that is not executable is not a handler
reset
printf '#!/bin/bash\nexit 0\n' > "$T/bin/remediations/noexec.sh"; chmod 644 "$T/bin/remediations/noexec.sh"
fire "$(payload 'noexec:1')"
quarantined 'noexec:1' && ok || bad "a non-executable handler file suppressed the alert"

# ---------- 6. a hanging handler still emits (real SIGTERM at the bound) -----
reset
handler slow 'sleep 30; exit 0'   # determinism: ok the hang IS the fixture — beat.sh's timeout must kill it
fire "$(payload 'slow:s1')"
quarantined 'slow:s1' && ok || bad "a handler that ran past the timeout suppressed the alert"
logged 'slow:s1' 'FAILOPEN-timeout' && ok || bad "timeout not logged as FAILOPEN-timeout: $(cat "$RLOG")"
# and the bound in the shipped source is the 60s the contract promises
grep -q 'timeout 60 "$handler"' "$SRC" && ok || bad "beat.sh no longer bounds handlers at timeout 60"

# ---------- 7. throttle: one attempt per akey per 6h window ------------------
reset
handler counted 'echo run >> '"$T"'/COUNT; exit 1'
: > "$T/COUNT"
fire "$(payload 'counted:k1')"
fire "$(payload 'counted:k1')"
fire "$(payload 'counted:k1')"
N=$(wc -l < "$T/COUNT")
[ "$N" -eq 1 ] && ok || bad "throttle let $N attempts through inside the window (expected 1)"
[ "$(grep -c 'counted:k1' "$Q")" -eq 3 ] && ok \
  || bad "throttled repeats must still take the normal path (quarantined $(grep -c 'counted:k1' "$Q") of 3)"

# a DIFFERENT key in the same window is not throttled
fire "$(payload 'counted:k2')"
[ "$(wc -l < "$T/COUNT")" -eq 2 ] && ok || bad "throttle is keyed on the namespace, not the akey"

# once the window has passed, the key gets another attempt
OLD=$(( $(date -u +%s) - 21601 ))
awk -F'\t' -v o="$OLD" 'BEGIN{OFS="\t"} {print o,$2}' "$T/state/remediation-attempts.tsv" > "$T/s.tmp"
mv "$T/s.tmp" "$T/state/remediation-attempts.tsv"
fire "$(payload 'counted:k1')"
[ "$(wc -l < "$T/COUNT")" -eq 3 ] && ok || bad "an akey never got a second attempt after the 6h window"

# ---------- 8. kill switch bypasses the whole hook ---------------------------
reset
handler killme 'echo "would have suppressed"; exit 0'
touch "$T/flags/remediation-disabled"
fire "$(payload 'killme:1')"
quarantined 'killme:1' && ok || bad "flags/remediation-disabled did not bypass the hook"
[ ! -s "$RLOG" ] && ok || bad "kill switch still ran a handler: $(cat "$RLOG")"
rm -f "$T/flags/remediation-disabled"

# ---------- 9. dispatch: most specific first, then the namespace -------------
reset
handler ns 'echo generic; exit 0'
handler ns-sub 'echo specific; exit 0'
fire "$(payload 'ns:sub:tail')"
grep -q 'ns-sub.sh' "$RLOG" && ok || bad "two-field akey did not prefer ns-sub.sh: $(cat "$RLOG")"
reset
fire "$(payload 'ns:other:tail')"
grep -q '	ns.sh	' "$RLOG" && ok || bad "unmatched second field did not fall back to ns.sh: $(cat "$RLOG")"

# an akey field that is not [A-Za-z0-9_-] can never name a file
reset
mkdir -p "$T/evil"
printf '#!/bin/bash\ntouch %s/PWNED\nexit 0\n' "$T" > "$T/evil/x.sh"; chmod +x "$T/evil/x.sh"
fire "$(payload '../../evil/x:1')"
[ ! -f "$T/PWNED" ] && ok || bad "a traversal akey executed a file outside bin/remediations"
quarantined '../../evil/x:1' && ok || bad "a rejected akey must still take the normal path"

# ---------- 10. beats the hook must not touch --------------------------------
reset
handler settled2 'exit 0'
# already triaged: an escalation a human lane decided to send
P=$(jq -nc '{kind:"fleet_alert",project:"x-os",triaged:true,akey:"settled2:a",line:"l"}')
OUT=$(HARNESS="$T" PATH="$T/fakebin:$PATH" bash "$T/bin/beat.sh" "$P" 2>&1)
[ ! -s "$RLOG" ] && ok || bad "a triaged:true escalation was run through remediation: $(cat "$RLOG")"
# a retraction: remediating it would suppress the notice that it cleared
reset
P=$(jq -nc '{kind:"fleet_alert",project:"x-os",resolved:true,akey:"settled2:b",line:"RESOLVED"}')
fire "$P"
[ ! -s "$RLOG" ] && ok || bad "a resolved:true retraction was run through remediation: $(cat "$RLOG")"

# ---------- 11. the shipped handlers are read-only probes --------------------
# The contract a handler cannot be trusted to keep by intention alone: it runs
# unattended, on a box that can merge and deploy, to decide that nobody needs to
# be told. Anything that writes to the world is a review-blocker here.
DANGER='gh pr merge|gh pr close|gh pr comment|gh api -X (POST|PATCH|PUT|DELETE)|git push|prisma (db push|migrate)|flyctl machine (destroy|stop|start)|machines\.dev.*-X (POST|DELETE)|curl [^|]*-X (POST|PUT|PATCH|DELETE)|/api/board|apply-migrations'
for h in "$DIR"/bin/remediations/*.sh; do
  HITS=$(grep -nE "$DANGER" "$h" || true)
  [ -z "$HITS" ] && ok || bad "$(basename "$h") performs a write action: $HITS"
done
# and each one announces its exit codes to the next reader
for h in "$DIR"/bin/remediations/*.sh; do
  grep -q 'READ-ONLY' "$h" && ok || bad "$(basename "$h") does not state its read-only contract"
done

# ---------- 12. the four shipped handlers, on fixtures -----------------------
# The hook's contract is proven above with stand-ins. These prove the handlers
# actually shipped make the right call — and, more importantly, DON'T make the
# wrong one: each class has a case that must still page.
HB="$DIR/bin/remediations"
mkdir -p "$T/h/bin" "$T/h/builds" "$T/h/flags" "$T/h/logs"
cp "$DIR/bin/fleet-conf.sh" "$T/h/bin/"
cp "$DIR/fleet.conf" "$T/h/fleet.conf"
run_h() { HARNESS="$T/h" PATH="$T/fakebin2:$PATH" bash "$HB/$1.sh" "$2" "${3:-}" >/dev/null 2>&1; echo $?; }
# 0 and 10 BOTH suppress, so "must page" is neither of them — asserting != 0
# alone would call a wrongly-terminal verdict a pass.
pages() { [ "$1" != 0 ] && [ "$1" != 10 ]; }
mkdir -p "$T/fakebin2"

# -- hungmachine: gone -> 0, alive/unknown -> non-zero
cat > "$T/h/bin/fly-machine-state.sh" <<'EOF'
#!/bin/bash
cat "$HARNESS/FLYSTATE" 2>/dev/null || { echo unknown; exit 1; }
EOF
chmod +x "$T/h/bin/fly-machine-state.sh"
HLINE='pool machine 2862174f059658 spawned 933m ago, never reaped ([pool/project-3] spawned)'
for CASE in "destroyed 0" "stopped 0" "purged 0" "started 1" "unknown 1"; do
  set -- $CASE
  echo "$1" > "$T/h/FLYSTATE"
  RC=$(run_h health-hungmachine 'health:hungmachine:2862174f059658' "$HLINE")
  if [ "$2" = 0 ]; then [ "$RC" -eq 0 ] && ok || bad "hungmachine: Fly state=$1 should exit 0 (got $RC)"
  else pages "$RC" && ok || bad "hungmachine: Fly state=$1 must page (got $RC)"; fi
done
# no project anywhere to attribute the machine to: cannot ask Fly, so it pages
RC=$(run_h health-hungmachine 'health:hungmachine:2862174f059658' 'pool machine spawned')
pages "$RC" && ok || bad "hungmachine suppressed without ever reaching Fly"

# -- stalepr: every PR settled -> 0, one still open -> non-zero
cat > "$T/fakebin2/gh" <<'EOF'
#!/bin/bash
for a; do case "$a" in \#*|[0-9]*) N="${a#\#}";; esac; done
grep -E "^$N " "$HARNESS/PRSTATE" 2>/dev/null | awk '{print $2}' | grep . || exit 1
EOF
chmod +x "$T/fakebin2/gh"
printf '229 MERGED\n247 CLOSED\n256 OPEN\n' > "$T/h/PRSTATE"
RC=$(run_h health-stalepr 'health:stalepr:project-3' 'project-3: harness PR(s) #229,#247 open >12h awaiting merge')
[ "$RC" -eq 0 ] && ok || bad "stalepr: all-settled PR list should exit 0"
RC=$(run_h health-stalepr 'health:stalepr:project-3' 'project-3: harness PR(s) #229,#256 open >12h awaiting merge')
pages "$RC" && ok || bad "stalepr: a still-OPEN PR must page"
RC=$(run_h health-stalepr 'health:stalepr:project-3' 'project-3: harness PR(s) #229,#999 open >12h')
pages "$RC" && ok || bad "stalepr: an unreadable PR state must page, not be assumed settled"
RC=$(run_h health-stalepr 'health:stalepr:project-3' 'project-3: something with no PR reference')
pages "$RC" && ok || bad "stalepr: a line naming no PR must page"

# -- uncommented: terminal end states -> 10, anything still owed -> non-zero
mkdir -p "$T/h/builds/x-os-A" "$T/h/builds/pool-x-os-B"
printf 'BUILD_DEFERRED all 3 slots busy\n' > "$T/h/builds/x-os-A/RESULT"
printf 'PR_CREATED https://github.com/o/r/pull/1\n' > "$T/h/builds/pool-x-os-B/RESULT"
touch -d '3 hours ago' "$T/h/builds/x-os-A/RESULT" "$T/h/builds/pool-x-os-B/RESULT"
RC=$(run_h health-uncommented 'health:uncommented:x-os:2')
pages "$RC" && ok || bad "uncommented: a PR_CREATED still owed a close-out must page"
touch "$T/h/builds/pool-x-os-B/COMMENTED"
RC=$(run_h health-uncommented 'health:uncommented:x-os:1')
[ "$RC" -eq 10 ] && ok || bad "uncommented: an original BUILD_DEFERRED is a terminal end state (expect 10)"
echo 1 > "$T/h/builds/x-os-A/resume-attempts"
RC=$(run_h health-uncommented 'health:uncommented:x-os:1')
pages "$RC" && ok || bad "uncommented: a deferral resume-dead-builds will retry is NOT terminal"
rm -f "$T/h/builds/x-os-A/resume-attempts"
printf 'BUILD_REFUSED context drift\n' > "$T/h/builds/x-os-A/RESULT"
touch -d '3 hours ago' "$T/h/builds/x-os-A/RESULT"
RC=$(run_h health-uncommented 'health:uncommented:x-os:1')
pages "$RC" && ok || bad "uncommented: BUILD_REFUSED with no pool-halt brake must page"
touch "$T/h/flags/pool-halt-x-os"
RC=$(run_h health-uncommented 'health:uncommented:x-os:1')
[ "$RC" -eq 10 ] && ok || bad "uncommented: BUILD_REFUSED already braked by pool-halt is terminal (expect 10)"
touch "$T/h/builds/x-os-A/COMMENTED"
RC=$(run_h health-uncommented 'health:uncommented:x-os:0')
pages "$RC" && ok || bad "uncommented: nothing left to judge must page, not suppress"

# -- hb-unreach: reachable on re-probe -> 0, still down -> non-zero
printf '#!/bin/bash\nexit "$(cat '"$T"'/SSHRC)"\n' > "$T/fakebin2/ssh"; chmod +x "$T/fakebin2/ssh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin2/timeout"; chmod +x "$T/fakebin2/timeout"
export REM_REPROBE_SLEEP=0   # the handler's 15s pause, collapsed for the suite
echo 0 > "$T/SSHRC"
RC=$(run_h hb-unreach 'hb-unreach:box-small:2026082519')
[ "$RC" -eq 0 ] && ok || bad "hb-unreach: a box that answers the re-probe should exit 0"
echo 255 > "$T/SSHRC"
RC=$(run_h hb-unreach 'hb-unreach:box-small:2026082519')
pages "$RC" && ok || bad "hb-unreach: a box still down on re-probe must page"
RC=$(run_h hb-unreach 'hb-unreach')
pages "$RC" && ok || bad "hb-unreach: an akey with no box must page"

# ---------- 13. the real harness was never touched ---------------------------
[ "$Q0" = "$(snap "$REALQ")" ] && ok || bad "THIS TEST WROTE THE REAL QUARANTINE FILE ($REALQ)"
[ "$A0" = "$(snap "$REALA")" ] && ok || bad "THIS TEST WROTE THE REAL ALERTS.log ($REALA)"

echo "remediation-hook-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
