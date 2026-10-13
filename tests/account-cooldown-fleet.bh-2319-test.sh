#!/bin/bash
# tests/account-cooldown-fleet.bh-2319-test.sh — BH-2355 (BH-2319.2): an
# account cooldown is a FLEET fact, not a box fact.
#
# Before this, box A got a 429 on claude account `a`, stamped
# state/quota/cooldown/claude/a on its own disk, and box B's picker handed `a`
# straight back out, because B only ever read B's files. Now every writer puts
# a row through the seam (bin/lib/fleet-cooldown.sh) AFTER its file write, the
# reader ORs the fleet row with the local file, and quota-status clears both
# sides and shows a fleet-only cooldown.
#
# Two simulated boxes, $T/a and $T/b, each with its own HARNESS / QUOTA_DIR /
# ACCOUNTS_DIR and its own copy of the scripts. They share ONE fleet through
# FLEET_COOLDOWN_STORE=$T/fleet.tsv (the seam's file backend). Assertions are on
# store rows, pick output and printed lines, never on source text.
#
# Cases:
#   1  A stamps -> row (until = stamp+window); B's REAL picker skips `a`
#   1b the _short stamp lands as a short until
#   1c a fleet-only cooldown is never written back to B's file
#   2  a codex row does not cool claude
#   3  no store (worker stub, rc 2): B not cooled, A still cooled by its file
#   3b an expired row does not cool
#   4  --clear-cooldown clears both sides, suffixes, rc 0 / 1 / 2
#   4b the status table shows a fleet-only cooldown once, and not a local one
#   5  pool_account_cooldown puts the reset-derived until
#   6  orc_account_refuse puts a row
#   7  mutation: without the fleet-or line, case 1's pick goes red
#
# Run from anywhere: tests/account-cooldown-fleet.bh-2319-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

WINDOW=21600          # the ACCOUNT_COOLDOWN_SECS default this suite pins against
STORE="$T/fleet.tsv"
unset FLEET_COOLDOWN_DB FLEET_COOLDOWN_STORE ACCOUNT_COOLDOWN_SECS MODEL_COOLDOWN_SECS \
      QUOTA_DIR ACCOUNTS_DIR ACCOUNT_ROUTING_LOG

mkbox() { # mkbox <dir>
  local h=$1 f
  mkdir -p "$h/bin/lib" "$h/env/accounts.d" "$h/state/quota" "$h/logs" "$h/.claude-a" "$h/.claude-b" "$h/.codex-c"
  for f in account-pick.sh quota-status.sh; do cp "$DIR/bin/$f" "$h/bin/$f"; chmod +x "$h/bin/$f"; done
  for f in env-path.sh pool-account.sh orc-account.sh fleet-cooldown.sh; do cp "$DIR/bin/lib/$f" "$h/bin/lib/$f"; done
  # a wins on priority, so a pick that answers `b` means `a` was skipped.
  printf 'ACCOUNT_NAME=a\nACCOUNT_VENDOR=claude\nACCOUNT_PRIORITY=10\nCLAUDE_CONFIG_DIR=%s/.claude-a\n' "$h" > "$h/env/accounts.d/a.env"
  printf 'ACCOUNT_NAME=b\nACCOUNT_VENDOR=claude\nACCOUNT_PRIORITY=20\nCLAUDE_CONFIG_DIR=%s/.claude-b\n' "$h" > "$h/env/accounts.d/b.env"
  printf 'ACCOUNT_NAME=c\nACCOUNT_VENDOR=codex\nCODEX_HOME=%s/.codex-c\n' "$h" > "$h/env/accounts.d/c.env"
  chmod 600 "$h/env/accounts.d/"*.env
}
mkbox "$T/a"; mkbox "$T/b"

# on <box> <cmd...> — run with that box's env and the shared fleet store.
on() {
  local h="$T/$1"; shift
  env HARNESS="$h" HOME="$h" ACCOUNTS_DIR="$h/env/accounts.d" QUOTA_DIR="$h/state/quota" \
      FLEET_COOLDOWN_STORE="$STORE" "$@"
}
# lib <box> <shell snippet> — source that box's account-pick.sh and run the snippet.
lib() {
  local b=$1; shift
  on "$b" bash -c '. "$HARNESS/bin/account-pick.sh"; '"$1"
}
pickname() { # pickname <box> [picker path] — the name the REAL CLI picks for claude
  on "$1" bash "${2:-$T/$1/bin/account-pick.sh}" eval claude claude-fable-5-1 2>/dev/null | sed -n 's/^name=//p'
}
row() { # row <kind> <vendor> <subject> -> the store row, empty when none
  awk -F'\t' -v k="$1" -v v="$2" -v s="$3" '$1==k && $2==v && $3==s' "$STORE" 2>/dev/null
}
until_of() { row "$@" | cut -f4; }
reset_all() { rm -f "$STORE"; rm -rf "$T/a/state/quota/cooldown" "$T/b/state/quota/cooldown"; }
near() { # near <got> <want> <slack>
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ $(( $1 - $2 )) -le "$3" ] && [ $(( $2 - $1 )) -le "$3" ]
}

# =============================================================================
# 1. A stamps, the fleet row lands, B's picker skips `a`
# =============================================================================
reset_all
[ "$(pickname b)" = a ] && ok || bad "1 precondition: B does not pick a when nothing is cooling"
lib a 'account_cooldown_stamp claude a'
AT=$(cat "$T/a/state/quota/cooldown/claude/a" 2>/dev/null)
U=$(until_of account claude a)
[ -n "$AT" ] && [ "$U" = "$(( AT + WINDOW ))" ] \
  && ok || bad "1: row until '$U' is not stamp '$AT' + $WINDOW (row: $(row account claude a))"
lib b 'account_cooling claude a'; RC=$?
[ "$RC" = 0 ] && ok || bad "1: B account_cooling claude a gave rc $RC, not 0"
P1=$(pickname b)
[ "$P1" = b ] && ok || bad "1: B's picker gave '$P1', not b (a is fleet-cooled)"
lib b 'account_cooling claude b'; RC=$?
[ "$RC" = 1 ] && ok || bad "1: another account's row cooled b (rc $RC)"
# 1c: the reader only reads.
[ ! -e "$T/b/state/quota/cooldown/claude/a" ] \
  && ok || bad "1c: B wrote a fleet-only cooldown back into its own file"

# 1b: the backdated short stamp lands as a short until.
reset_all
NOW=$(date -u +%s)
lib a 'account_cooldown_stamp_short claude a 600'
U=$(until_of account claude a)
near "$U" $(( NOW + 600 )) 5 && ok || bad "1b: short until '$U' is not now+600 ($(( NOW + 600 )))"

# =============================================================================
# 2. a codex row does not cool claude
# =============================================================================
reset_all
on b bash -c ". \"\$HARNESS/bin/lib/fleet-cooldown.sh\"; fcd_put account codex a $(( $(date +%s) + 3600 ))"
[ -n "$(row account codex a)" ] && ok || bad "2 precondition: codex row not written"
lib b 'account_cooling claude a'; RC=$?
[ "$RC" = 1 ] && ok || bad "2: a codex row cooled claude a (rc $RC)"
[ "$(pickname b)" = a ] && ok || bad "2: the pick refused claude a over a codex row"

# =============================================================================
# 3. no store: the worker stub answers rc 2, which is not cooling
# =============================================================================
reset_all
lib a 'account_cooldown_stamp claude a'
env HARNESS="$T/b" HOME="$T/b" ACCOUNTS_DIR="$T/b/env/accounts.d" QUOTA_DIR="$T/b/state/quota" \
  bash -c '. "$HARNESS/bin/account-pick.sh"; account_cooling claude a'; RC=$?
[ "$RC" = 1 ] && ok || bad "3: B with no store gave rc $RC, not 1"
env HARNESS="$T/a" HOME="$T/a" ACCOUNTS_DIR="$T/a/env/accounts.d" QUOTA_DIR="$T/a/state/quota" \
  bash -c '. "$HARNESS/bin/account-pick.sh"; account_cooling claude a'; RC=$?
[ "$RC" = 0 ] && ok || bad "3: A lost its file cooldown with no store (rc $RC)"
# 3b: an expired row does not cool.
reset_all
on b bash -c ". \"\$HARNESS/bin/lib/fleet-cooldown.sh\"; fcd_put account claude a $(( $(date +%s) - 10 ))"
[ -n "$(row account claude a)" ] && ok || bad "3b precondition: expired row not written"
lib b 'account_cooling claude a'; RC=$?
[ "$RC" = 1 ] && ok || bad "3b: an expired row cooled a (rc $RC)"
[ "$(pickname b)" = a ] && ok || bad "3b: the pick refused a over an expired row"

# =============================================================================
# 4. --clear-cooldown clears both sides
# =============================================================================
qs() { # qs <box> <args...> — the REAL quota-status.sh, sets QS_OUT / QRC
  local b=$1; shift
  QS_OUT=$(on "$b" bash "$T/$b/bin/quota-status.sh" "$@" 2>&1); QRC=$?
}
reset_all
lib a 'account_cooldown_stamp claude a'
qs a --clear-cooldown claude a
[ "$QRC" = 0 ] && ok || bad "4: clear exited $QRC, not 0 ($QS_OUT)"
grep -q '^cleared cooldown claude/a (.*) (fleet row cleared)$' <<<"$QS_OUT" \
  && ok || bad "4: clear output did not name both sides: $QS_OUT"
[ ! -e "$T/a/state/quota/cooldown/claude/a" ] && ok || bad "4: the file survived the clear"
on a bash -c '. "$HARNESS/bin/lib/fleet-cooldown.sh"; fcd_live account claude a'; RC=$?
[ "$RC" = 1 ] && ok || bad "4: fcd_live after the clear gave rc $RC, not 1"
qs a --clear-cooldown claude a
[ "$QRC" = 1 ] && [ "$QS_OUT" = 'no cooldown for claude/a (no fleet row)' ] \
  && ok || bad "4: a second clear was not rc 1 + 'no cooldown ... (no fleet row)' (rc=$QRC, out=$QS_OUT)"
# fleet-only: B has no file, the row is A's.
lib a 'account_cooldown_stamp claude a'
qs b --clear-cooldown claude a
[ "$QRC" = 0 ] && [ "$QS_OUT" = 'cleared the fleet cooldown for claude/a' ] \
  && ok || bad "4: a fleet-only clear was not rc 0 + 'cleared the fleet cooldown for claude/a' (rc=$QRC, out=$QS_OUT)"
[ -z "$(row account claude a)" ] && ok || bad "4: the fleet-only clear left the row"
grep -q 'cooldown claude/a cleared by operator' "$T/b/logs/failovers.log" 2>/dev/null \
  && ok || bad "4: a fleet-only clear was not logged on B"
# unreachable fleet (no store): suffix says so, rc decided by the file alone.
QS_OUT=$(env HARNESS="$T/a" HOME="$T/a" ACCOUNTS_DIR="$T/a/env/accounts.d" QUOTA_DIR="$T/a/state/quota" \
  bash "$T/a/bin/quota-status.sh" --clear-cooldown claude b 2>&1); QRC=$?
[ "$QRC" = 1 ] && [ "$QS_OUT" = 'no cooldown for claude/b (fleet not reachable)' ] \
  && ok || bad "4: an unreachable fleet was not rc 1 + '(fleet not reachable)' (rc=$QRC, out=$QS_OUT)"
qs a --clear-cooldown bogus a
[ "$QRC" = 2 ] && ok || bad "4: bad vendor exited $QRC, not 2"

# 4b: B's table shows A's cooldown once, marked fleet, and not when B has it locally.
reset_all
lib a 'account_cooldown_stamp claude a'
qs b
N=$(grep -cE '^ cooldown: a cl to [0-9]{2}:[0-9]{2}Z \(fleet, set on .+\)$' <<<"$QS_OUT")
[ "$N" = 1 ] && ok || bad "4b: $N fleet cooldown lines for a on B, not 1: $QS_OUT"
lib b 'account_cooldown_stamp claude a'
qs b
N=$(grep -c '^ cooldown: a .*(fleet' <<<"$QS_OUT")
[ "$N" = 0 ] && ok || bad "4b: a locally cooling a still got a fleet line: $QS_OUT"
grep -qE '^ cooldown: a cl to [0-9]{2}:[0-9]{2}Z$' <<<"$QS_OUT" \
  && ok || bad "4b: the local cooldown line is gone: $QS_OUT"

# =============================================================================
# 5. pool_account_cooldown puts the reset-derived until
# =============================================================================
reset_all
RESET=$(( $(date -u +%s) + 86400 ))
on a bash -c ". \"\$HARNESS/bin/lib/fleet-cooldown.sh\"; . \"\$HARNESS/bin/lib/pool-account.sh\"; pool_account_cooldown a quota $RESET"
U=$(until_of account claude a)
[ "$U" = "$RESET" ] && ok || bad "5: pool row until '$U' is not the reset $RESET"
# the picker path (account-pick.sh beside the lib, no reset) puts now+window
reset_all
NOW=$(date -u +%s)
on a bash -c '. "$HARNESS/bin/lib/pool-account.sh"; pool_account_cooldown b refusal'
U=$(until_of account claude b)
near "$U" $(( NOW + WINDOW )) 5 && ok || bad "5: pool picker-path row until '$U' is not now+$WINDOW"
# the inline fallback: a box whose bin/ has no account-pick.sh
reset_all
mkdir -p "$T/p/bin/lib" "$T/p/state/quota"
for f in env-path.sh pool-account.sh fleet-cooldown.sh; do cp "$DIR/bin/lib/$f" "$T/p/bin/lib/$f"; done
NOW=$(date -u +%s)
on p bash -c '. "$HARNESS/bin/lib/pool-account.sh"; command -v account_cooldown_stamp >/dev/null && exit 9; pool_account_cooldown b refusal'; RC=$?
U=$(until_of account claude b)
[ "$RC" = 0 ] && [ -e "$T/p/state/quota/cooldown/claude/b" ] && near "$U" $(( NOW + WINDOW )) 5 \
  && ok || bad "5: pool inline-fallback (rc $RC) row until '$U' is not now+$WINDOW, or its file is missing"

# =============================================================================
# 6. orc_account_refuse puts a row
# =============================================================================
reset_all
NOW=$(date -u +%s)
on a bash -c '. "$HARNESS/bin/lib/orc-account.sh"; orc_account_refuse a'
U=$(until_of account claude a)
near "$U" $(( NOW + WINDOW )) 5 && ok || bad "6: orc row until '$U' is not now+$WINDOW (row: $(row account claude a))"
[ -e "$T/a/state/quota/cooldown/claude/a" ] && ok || bad "6: orc_account_refuse no longer writes its file"

# =============================================================================
# 7. mutation (D1): drop the fleet-or line, case 1's pick goes red
# =============================================================================
MUT="$T/b/bin/account-pick.mutant.sh"
sed '/# fleet-or (BH-2355)/d' "$T/b/bin/account-pick.sh" > "$MUT"
if cmp -s "$MUT" "$T/b/bin/account-pick.sh"; then
  bad "7: the fleet-or marker is missing, the mutant equals the original"
else
  reset_all
  lib a 'account_cooldown_stamp claude a'
  PM=$(pickname b "$MUT")
  if [ "$PM" = a ]; then ok; echo "MUTATION: case 1 red without fleet-or"
  else bad "7: without fleet-or the pick still gave '$PM' (case 1 did not go red)"; fi
fi
rm -f "$MUT"

echo "account-cooldown-fleet: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
