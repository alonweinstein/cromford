#!/bin/bash
# tests/harden-state-test.sh — acceptance test for bin/harden-state.sh
#
# MUTATION CHECK (D1): to verify that A2 genuinely exercises the immutable flag,
# temporarily comment out the `chattr +i` line in bin/harden-state.sh and rerun
# this test. The A2 immutable-defense assertions must fail.
#
# Run from anywhere: tests/harden-state-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

HS="$DIR/bin/harden-state.sh"
H="$T/harness"

has_i() { lsattr -d "$1" 2>/dev/null | awk '{print $1}' | grep -q 'i'; }
has_a() { lsattr -d "$1" 2>/dev/null | awk '{print $1}' | grep -q 'a'; }

# ---------- A0: chattr probe + early rc 2 when unavailable ----------
probe=$(mktemp)
if ! chattr +i "$probe" 2>/dev/null; then
  rm -f "$probe"
  OUT=$("$HS" 2>&1); RC=$?
  [ "$RC" -eq 2 ] && ok || bad "A0 script returns rc 2 when chattr unavailable (got $RC)"
  [ -n "$OUT" ] && ok || bad "A0 script emits stderr when chattr unavailable"
  echo "SKIP: chattr unsupported here (rc=$RC)"
  echo "harden-state-test: $PASS pass, $FAIL fail (SKIPPED)"
  exit 0
fi
chattr -i "$probe" 2>/dev/null || true
rm -f "$probe"

# ---------- Fixture: 5 env + 3 ssh + 8 ledgers = 16 targets ----------
mkdir -p "$H/env/accounts.d" "$H/env/tokens.d" "$H/logs" "$H/locks" "$H/ssh"
printf 'GLOBAL=1\n' > "$H/env/global.env"
printf 'ACCT=1\n'   > "$H/env/accounts.d/primary.env"
printf 'TOKEN=1\n'  > "$H/env/tokens.d/api.token"
printf 'PEM=1\n'    > "$H/env/github-app.pem"
printf 'DOT=1\n'    > "$H/env/.watchdog-secret"
ln -s /etc/hostname "$H/env/link"
touch "$H/ssh/id_ed25519" "$H/ssh/id_ed25519.pub" "$H/ssh/authorized_keys"
for name in cost.csv ALERTS.log harden-state.log alerts-state.log agent-rules.log findings.log medic.log blocked-resolver.log; do
  touch "$H/logs/$name"
done

# ---------- A1: arm-all hardens every target ----------
OUT=$(HARNESS="$H" HARDEN_SSH_DIR="$H/ssh" "$HS"); RC=$?
[ "$RC" -eq 0 ] && ok || bad "A1 arm-all rc 0 (got $RC)"
# The plan text says "5 + 3 + 8 = 13", but the real total is 16.
[ "$OUT" = "hardened=16/16 changed=16" ] && ok || bad "A1 arm-all output (got: $OUT)"

for f in "$H/env/global.env" "$H/env/accounts.d/primary.env" "$H/env/tokens.d/api.token" \
         "$H/env/github-app.pem" "$H/env/.watchdog-secret"; do
  has_i "$f" && ok || bad "A1 env file $f missing immutable flag"
done
has_i "$H/env/link" && bad "A1 symlink env/link must NOT be flagged" || ok
for f in "$H/ssh/id_ed25519" "$H/ssh/id_ed25519.pub" "$H/ssh/authorized_keys"; do
  has_i "$f" && ok || bad "A1 ssh file $f missing immutable flag"
done
for name in cost.csv ALERTS.log harden-state.log alerts-state.log agent-rules.log findings.log medic.log blocked-resolver.log; do
  has_a "$H/logs/$name" && ok || bad "A1 ledger $name missing append-only flag"
done
[ "$(stat -c '%a' "$H/env/global.env")" = "600" ] && ok || bad "A1 env mode not 600"

# ---------- A2: immutable defense ----------
rm -f "$H/env/global.env" 2>/dev/null; RC=$?
[ "$RC" -ne 0 ] && ok || bad "A2 rm of immutable env file should fail"
[ -f "$H/env/global.env" ] && ok || bad "A2 immutable env file must survive"
[ "$(cat "$H/env/global.env")" = "GLOBAL=1" ] && ok || bad "A2 immutable env file content unchanged"
scratch_rm "$H/env" 2>/dev/null; RC=$?
[ "$RC" -ne 0 ] && ok || bad "A2 rm -rf env dir should fail"
[ -d "$H/env" ] && ok || bad "A2 env dir must survive"
[ -f "$H/env/global.env" ] && ok || bad "A2 env file still present after rm -rf"

# ---------- A3: append-only ledger behavior ----------
before=$(wc -l < "$H/logs/cost.csv")
printf 'x\n' >> "$H/logs/cost.csv"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "A3 append to ledger should succeed"
after=$(wc -l < "$H/logs/cost.csv")
[ "$((after - before))" -eq 1 ] && ok || bad "A3 ledger line count +1"
if ( : > "$H/logs/cost.csv" ) 2>/dev/null; then RC=0; else RC=$?; fi
[ "$RC" -ne 0 ] && ok || bad "A3 truncate ledger should fail"
[ "$(wc -l < "$H/logs/cost.csv")" = "$after" ] && ok || bad "A3 ledger count unchanged after truncate attempt"
printf 'other\n' > "$T/other"
mv "$T/other" "$H/logs/cost.csv" 2>/dev/null; RC=$?
[ "$RC" -ne 0 ] && ok || bad "A3 replace ledger should fail"
[ "$(wc -l < "$H/logs/cost.csv")" = "$after" ] && ok || bad "A3 ledger count unchanged after replace attempt"

# ---------- A4: release / rearm cycle ----------
HARNESS="$H" HARDEN_SSH_DIR="$H/ssh" "$HS" --release "$H/env/global.env"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "A4 release rc 0"
printf 'NEW=1\n' > "$H/env/global.env"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "A4 write after release should succeed"
[ "$(cat "$H/env/global.env")" = "NEW=1" ] && ok || bad "A4 content after write"
HARNESS="$H" HARDEN_SSH_DIR="$H/ssh" "$HS" --rearm "$H/env/global.env"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "A4 rearm rc 0"
has_i "$H/env/global.env" && ok || bad "A4 rearm restores immutable flag"
rm -f "$H/env/global.env" 2>/dev/null; RC=$?
[ "$RC" -ne 0 ] && ok || bad "A4 rm after rearm should fail"
[ -f "$H/env/global.env" ] && ok || bad "A4 file survives after rearm"

# ---------- A5: idempotent arm-all ----------
log_before=$(wc -l < "$H/logs/harden-state.log")
OUT=$(HARNESS="$H" HARDEN_SSH_DIR="$H/ssh" "$HS"); RC=$?
[ "$RC" -eq 0 ] && ok || bad "A5 second arm-all rc 0"
[ "$OUT" = "hardened=16/16 changed=0" ] && ok || bad "A5 second arm-all output (got: $OUT)"
log_after=$(wc -l < "$H/logs/harden-state.log")
[ "$log_before" = "$log_after" ] && ok || bad "A5 log must not grow when changed=0"

# ---------- A10: negatives ----------
mkdir -p "$H/bin"
touch "$H/bin/x"
HARNESS="$H" HARDEN_SSH_DIR="$H/ssh" "$HS" --release /etc/passwd >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] && ok || bad "A10 release /etc/passwd rc 2"
HARNESS="$H" HARDEN_SSH_DIR="$H/ssh" "$HS" --release "$H/env/../bin/x" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] && ok || bad "A10 release env/../bin/x rc 2"
touch "$H/logs/merge-sweep.log"
HARNESS="$H" HARDEN_SSH_DIR="$H/ssh" "$HS" --rearm "$H/logs/merge-sweep.log" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] && ok || bad "A10 rearm merge-sweep.log rc 2"
has_a "$H/logs/merge-sweep.log" && bad "A10 merge-sweep.log must not be flagged" || ok
HARNESS="$H" HARDEN_SSH_DIR="$H/ssh" "$HS" --release "$H/env" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] && ok || bad "A10 release env directory rc 2"
HARNESS="$H" HARDEN_SSH_DIR="$H/ssh" "$HS" --release "$H/logs/absent.csv" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok || bad "A10 release missing ledger rc 0"
[ ! -e "$H/logs/absent.csv" ] && ok || bad "A10 absent.csv must not be created"
has_i /etc/hostname && bad "A10 /etc/hostname must remain unflagged" || ok
has_a /etc/hostname && bad "A10 /etc/hostname must remain unflagged" || ok

echo "harden-state-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
