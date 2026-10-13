#!/bin/bash
# tests/triage-skip-evidence.bh-5125-test.sh — BH-5125 items 1 and 2.
# A triage `skip`/`defer` whose reason claims a fix, round, build or rebuild is
# in progress must name its evidence, or it is not honoured: the real
# bin/decision-log.sh (the harvester both triage paths call) runs
# bin/lib/triage-skip-evidence.sh's tse_audit, which writes a `gate=audit …
# :: handoff ::` line to logs/decisions.log and ONE deduped ALERTS line.
#   C1–C3  the triage contract (catalog/agent-contracts/triage-system-append.txt)
#   E1–E12 the audit, driven through bin/decision-log.sh in a scratch harness
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
export HARNESS_TEST_SANDBOX=1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

CONTRACT="$DIR/catalog/agent-contracts/triage-system-append.txt"
TSE_LIB="$DIR/bin/lib/triage-skip-evidence.sh"
[ -f "$TSE_LIB" ] && ok "the lib exists at bin/lib/triage-skip-evidence.sh" || bad "no $TSE_LIB"

# ── C: the contract ───────────────────────────────────────────────────────
DIRL=$(grep '^DIRECTION:' "$CONTRACT" 2>/dev/null)
[ -n "$DIRL" ] && [[ $DIRL == *'Taken by:'* ]] && [[ $DIRL == *'[human-fix]'* ]] && [[ ${DIRL,,} == *'never infer'* ]] \
  && ok "C1: a DIRECTION: paragraph names Taken by:, [human-fix] and 'never infer'" \
  || bad "C1: DIRECTION: paragraph missing or incomplete: '$DIRL'"
EVL=$(grep '^EVIDENCE:' "$CONTRACT" 2>/dev/null)
[ -n "$EVL" ] && [[ $EVL == *'[evidence: lock '* ]] && [[ $EVL == *'[evidence: pid '* ]] \
  && [[ $EVL == *'[evidence: job '* ]] && [[ $EVL == *'[evidence: hold:human-fix]'* ]] \
  && ok "C2: an EVIDENCE: paragraph names all four tag forms" \
  || bad "C2: EVIDENCE: paragraph missing or incomplete: '$EVL'"
DDL=$(grep '^BUILD DEDUPE:' "$CONTRACT" 2>/dev/null)
grep -qF "skip :: already building [evidence: lock /root/harness/locks/build-key-" <<<"$DDL" \
  && ok "C3: the BUILD DEDUPE example carries the lock evidence tag" \
  || bad "C3: BUILD DEDUPE example has no lock evidence tag"

# ── E: the audit through the real harvester ───────────────────────────────
H="$T/h"
mkdir -p "$H/logs" "$H/locks" "$H/state"
scratch_install_closure bin/decision-log.sh "$H" >/dev/null \
  || { bad "scratch_install_closure bin/decision-log.sh failed"; echo "triage-skip-evidence.bh-5125: $PASS passed, $FAIL failed"; exit 1; }
# The ALERTS line goes through bin/alert-line.sh, which the audit EXECUTES, so
# it is installed by name (with whatever it sources).
scratch_install_closure bin/alert-line.sh "$H" >/dev/null \
  || { bad "scratch_install_closure bin/alert-line.sh failed"; echo "triage-skip-evidence.bh-5125: $PASS passed, $FAIL failed"; exit 1; }
[ -f "$H/bin/lib/triage-skip-evidence.sh" ] && ok "the closure of bin/decision-log.sh carries the lib" \
  || bad "the closure of bin/decision-log.sh does not carry bin/lib/triage-skip-evidence.sh"
DLOG="$H/logs/decisions.log"; ALERTS="$H/logs/ALERTS.log"
N=0
# run <payload...> — one session-out file of DECISION lines through the harvester.
run() {
  N=$((N+1)); local f="$T/out$N.txt" l rc
  : > "$f"; for l in "$@"; do printf 'DECISION: %s\n' "$l" >> "$f"; done
  HARNESS="$H" "$H/bin/decision-log.sh" p board-changed full "$f"; rc=$?
  [ "$rc" = 0 ] || bad "decision-log.sh rc $rc on run $N"
}
reset() { scratch_rm "$H/state/triage-skip-evidence"; : > "$DLOG"; : > "$ALERTS"; }
audits() { grep -c "gate=audit ${1:-}.* :: handoff :: " "$DLOG" 2>/dev/null; }
alerts() { grep -c "${1:-.}" "$ALERTS" 2>/dev/null; }

INC='fix round for the lead BLOCK on open PR #5067 is already in progress (orchestrator/operator)'

# E1: the incident line.
reset; run "BH-5022 :: skip :: $INC"
grep -qF "[p] gate=board-changed scope=full BH-5022 :: skip :: $INC" "$DLOG" \
  && ok "E1: the harvested line is written as today" || bad "E1: harvest missing: $(cat "$DLOG")"
[ "$(audits BH-5022)" = 1 ] && grep -q 'gate=audit BH-5022 :: handoff :: skip claimed work in progress with no evidence (no evidence tag) — bin/blocked-resolver.sh owns it' "$DLOG" \
  && ok "E1: one gate=audit handoff line" || bad "E1: audit line wrong: $(cat "$DLOG")"
[ "$(alerts)" = 1 ] && grep -q 'BH-5022' "$ALERTS" && grep -q 'bin/blocked-resolver.sh' "$ALERTS" && grep -qF "$INC" "$ALERTS" \
  && ok "E1: exactly one ALERTS line naming BH-5022, the resolver and the reason" || bad "E1: ALERTS wrong: $(cat "$ALERTS")"

# E2: same line again → still one ALERTS line, two audit lines.
run "BH-5022 :: skip :: $INC"
[ "$(audits BH-5022)" = 2 ] && ok "E2: the audit line is written every tick" || bad "E2: audits=$(audits BH-5022)"
[ "$(alerts)" = 1 ] && ok "E2: the ALERTS line is deduped" || bad "E2: alerts=$(alerts): $(cat "$ALERTS")"

# E3: a changed reason for the same key → a second ALERTS line.
run "BH-5022 :: skip :: a fix round is in progress on it under the operator's 03:33Z narrowing comment"
[ "$(alerts)" = 2 ] && ok "E3: a changed claim alerts again" || bad "E3: alerts=$(alerts)"

# E4: a held lock is evidence.
reset
LOCK="$H/locks/build-key-p-BH-1.lock"; : > "$LOCK"
flock "$LOCK" sleep 30 & HOLDER=$!
for _ in $(seq 1 50); do ( exec 8<"$LOCK"; flock -n 8 ) 2>/dev/null || break; sleep 0.1; done
run "BH-1 :: skip :: already building [evidence: lock $LOCK]"
[ "$(audits)" = 0 ] && [ "$(alerts)" = 0 ] && ok "E4: a held lock is honoured (no audit, no ALERTS)" \
  || bad "E4: audits=$(audits) alerts=$(alerts): $(cat "$DLOG")"
# flock's child sleep inherits the lock fd, so the child goes first.
pkill -P "$HOLDER" 2>/dev/null; kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
for _ in $(seq 1 50); do ( exec 8<"$LOCK"; flock -n 8 ) 2>/dev/null && break; sleep 0.1; done

# E5: the same tag, lock not held.
reset; run "BH-1 :: skip :: already building [evidence: lock $LOCK]"
[ "$(audits BH-1)" = 1 ] && grep -q '(lock not held)' "$DLOG" && [ "$(alerts)" = 1 ] \
  && ok "E5: an unheld lock is not evidence (lock not held)" || bad "E5: $(cat "$DLOG")"
reset; run "BH-1 :: skip :: already building [evidence: lock $H/locks/nope.lock]"
[ "$(audits BH-1)" = 1 ] && grep -q '(lock not held)' "$DLOG" && ok "E5b: a missing lock file is not held" || bad "E5b: $(cat "$DLOG")"

# E6: paths outside locks/.
reset; run "BH-2 :: skip :: already building [evidence: lock /etc/passwd]" \
           "BH-3 :: skip :: already building [evidence: lock $H/locks/../x]" \
           "BH-4 :: skip :: already building [evidence: lock locks/build-key-p-BH-4.lock]"
[ "$(grep -c '(lock outside locks/)' "$DLOG")" = 3 ] && ok "E6: /etc/passwd, a .. path and a relative path are lock outside locks/" \
  || bad "E6: $(cat "$DLOG")"

# E7: pids.
reset; sleep 30 & LIVE=$!
run "BH-5 :: skip :: rebuild under way [evidence: pid $LIVE]"
[ "$(audits)" = 0 ] && ok "E7: a live pid is honoured" || bad "E7: live pid audited: $(cat "$DLOG")"
kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null
reset; run "BH-5 :: skip :: rebuild under way [evidence: pid 999999]" "BH-6 :: skip :: rebuild under way [evidence: pid abc]"
[ "$(grep -c '(pid not running)' "$DLOG")" = 2 ] && ok "E7: a dead pid and a non-numeric pid are audited (pid not running)" \
  || bad "E7: $(cat "$DLOG")"

# E8: named evidence.
reset; run "BH-7 :: skip :: already building [evidence: job build-p-BH-1-123]" \
           "BH-8 :: defer :: the operator is fixing it by hand [evidence: hold:human-fix]"
[ "$(audits)" = 0 ] && [ "$(alerts)" = 0 ] && ok "E8: job and hold:human-fix tags are honoured" || bad "E8: $(cat "$DLOG")"

# E9: the nine negatives are never flagged.
reset
NEG=( 'waiting on client answer to fee question' 'PR #12 open, awaiting merge' 'Blocked-by #40 still open'
      'HOLD on the ticket' 'nothing new since last tick' 'lead review requested, verdict pending'
      'build finished, PR_CREATED closed out' 'already shipped in #88' 'dup of BH-12' )
i=0; for r in "${NEG[@]}"; do i=$((i+1)); run "NEG-$i :: skip :: $r"; done
[ "$(audits)" = 0 ] && [ "$(alerts)" = 0 ] && ok "E9: none of the nine negatives is audited" || bad "E9: $(grep 'gate=audit' "$DLOG")"

# E10: the six positives are all flagged when untagged.
reset
POS=( "$INC" "a fix round is in progress on it under the operator's 03:33Z narrowing comment" 'the operator is fixing it by hand'
      'already building' 'rebuild under way' 'someone is on it' )
i=0; for r in "${POS[@]}"; do i=$((i+1)); run "POS-$i :: skip :: $r"; done
for i in 1 2 3 4 5 6; do
  [ "$(audits "POS-$i")" = 1 ] && ok "E10: positive $i '${POS[$((i-1))]}' is audited" || bad "E10: positive $i not audited"
done
[ "$(alerts)" = 6 ] && ok "E10: one ALERTS line per positive" || bad "E10: alerts=$(alerts)"

# E11: only skip and defer are audited.
reset; run "BH-9 :: launch :: rebuild under way, already building" "BH-10 :: comment :: someone is on it" \
           "BH-11 :: escalate :: a fix round is in progress"
[ "$(audits)" = 0 ] && ok "E11: launch/comment/escalate are never audited" || bad "E11: $(grep 'gate=audit' "$DLOG")"
reset; run "BH-12 :: defer :: someone is on it"
[ "$(audits BH-12)" = 1 ] && ok "E11: defer is audited" || bad "E11: defer not audited"

# E12: the lib absent → harvest unchanged, no audit, rc 0.
reset; mv "$H/bin/lib/triage-skip-evidence.sh" "$T/tse.away"
run "BH-5022 :: skip :: $INC"
grep -qF "BH-5022 :: skip :: $INC" "$DLOG" && [ "$(audits)" = 0 ] && [ "$(alerts)" = 0 ] \
  && ok "E12: with the lib removed the harvest is unchanged and nothing is audited" || bad "E12: $(cat "$DLOG")"
mv "$T/tse.away" "$H/bin/lib/triage-skip-evidence.sh"

# E13: the lib alone fails open with no root.
OUTE="$T/out-noroot.txt"; printf 'DECISION: BH-1 :: skip :: already building\n' > "$OUTE"
( unset HARNESS H; . "$TSE_LIB" && tse_audit p "$OUTE" ); rc=$?
[ "$rc" = 0 ] && ok "E13: tse_audit with no root returns 0" || bad "E13: rc $rc"
( HARNESS="$H"; . "$TSE_LIB" && tse_audit p "$T/does-not-exist" ); rc=$?
[ "$rc" = 0 ] && ok "E13: tse_audit on a missing file returns 0" || bad "E13: rc $rc"

echo "triage-skip-evidence.bh-5125: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
