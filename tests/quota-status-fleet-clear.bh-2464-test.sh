#!/bin/bash
# tests/quota-status-fleet-clear.bh-2464-test.sh — BH-2464: a fleet-only
# `quota-status.sh --clear-cooldown` says what it did.
#
# Before this, a clear that found no local file but removed the fleet row
# printed `no cooldown for claude/a (fleet row cleared)` and exited 0: one line
# that said there was nothing and that it had cleared something. Now it prints
# `cleared the fleet cooldown for claude/a`. Every other outcome is unchanged.
#
# One scratch box with its own copy of the scripts and a file-backed fleet
# (FLEET_COOLDOWN_STORE). Every case runs the REAL quota-status.sh CLI and
# asserts the printed line, the rc, the store row and failovers.log.
#
# Cases:
#   a  fleet-only row: rc 0, exactly `cleared the fleet cooldown for claude/a`,
#      row gone, operator clear logged
#   b  the fleet-only line never says `no cooldown`
#   c  nothing on either side: rc 1, `no cooldown for claude/a (no fleet row)`,
#      nothing logged
#   d  file + row: rc 0, `cleared cooldown claude/a (...) (fleet row cleared)`
#   e  no fleet store, no file: rc 1, `no cooldown for claude/a (fleet not reachable)`
#
# Run from anywhere: tests/quota-status-fleet-clear.bh-2464-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

STORE="$T/fleet.tsv"
H="$T/box"
unset FLEET_COOLDOWN_DB FLEET_COOLDOWN_STORE ACCOUNT_COOLDOWN_SECS MODEL_COOLDOWN_SECS \
      QUOTA_DIR ACCOUNTS_DIR ACCOUNT_ROUTING_LOG

mkdir -p "$H/bin/lib" "$H/env/accounts.d" "$H/state/quota" "$H/logs" "$H/.claude-a"
for f in account-pick.sh quota-status.sh; do cp "$DIR/bin/$f" "$H/bin/$f"; chmod +x "$H/bin/$f"; done
for f in env-path.sh pool-account.sh orc-account.sh fleet-cooldown.sh; do cp "$DIR/bin/lib/$f" "$H/bin/lib/$f"; done
printf 'ACCOUNT_NAME=a\nACCOUNT_VENDOR=claude\nCLAUDE_CONFIG_DIR=%s/.claude-a\n' "$H" > "$H/env/accounts.d/a.env"
chmod 600 "$H/env/accounts.d/a.env"

# on [store] <cmd...> — the box's env; the fleet store only when asked for.
on() {
  local s=""
  if [ "$1" = --store ]; then s="$STORE"; shift; fi
  env HARNESS="$H" HOME="$H" ACCOUNTS_DIR="$H/env/accounts.d" QUOTA_DIR="$H/state/quota" \
      ${s:+FLEET_COOLDOWN_STORE="$s"} "$@"
}
qs() { # qs [--store] -> QS_OUT / QRC from the REAL `--clear-cooldown claude a`
  QS_OUT=$(on "$@" bash "$H/bin/quota-status.sh" --clear-cooldown claude a 2>&1); QRC=$?
}
row() { awk -F'\t' '$1=="account" && $2=="claude" && $3=="a"' "$STORE" 2>/dev/null; }
put_row() { on --store bash -c '. "$HARNESS/bin/lib/fleet-cooldown.sh"; fcd_put account claude a '"$(( $(date +%s) + 600 ))"; }
logged() { grep -q 'cooldown claude/a cleared by operator' "$H/logs/failovers.log" 2>/dev/null; }
reset_all() { rm -f "$STORE" "$H/logs/failovers.log"; scratch_rm "$H/state/quota/cooldown"; }

# a/b: fleet-only row
reset_all; put_row
[ -n "$(row)" ] && ok || bad "a precondition: fcd_put wrote no row"
qs --store
[ "$QRC" = 0 ] && ok || bad "a: fleet-only clear exited $QRC, not 0 ($QS_OUT)"
[ "$QS_OUT" = 'cleared the fleet cooldown for claude/a' ] \
  && ok || bad "a: fleet-only clear printed '$QS_OUT', not 'cleared the fleet cooldown for claude/a'"
[ -z "$(row)" ] && ok || bad "a: the row survived the clear: $(row)"
logged && ok || bad "a: the fleet-only clear was not logged to failovers.log"
case "$QS_OUT" in *'no cooldown'*) bad "b: the fleet-only clear still says 'no cooldown': $QS_OUT" ;; *) ok ;; esac

# c: nothing on either side
reset_all
qs --store
[ "$QRC" = 1 ] && [ "$QS_OUT" = 'no cooldown for claude/a (no fleet row)' ] \
  && ok || bad "c: empty clear was not rc 1 + 'no cooldown for claude/a (no fleet row)' (rc=$QRC, out=$QS_OUT)"
logged && bad "c: a clear that cleared nothing was logged" || ok

# d: file + row
reset_all
on --store bash -c '. "$HARNESS/bin/account-pick.sh"; account_cooldown_stamp claude a'
[ -e "$H/state/quota/cooldown/claude/a" ] && [ -n "$(row)" ] && ok || bad "d precondition: stamp wrote no file or no row"
qs --store
[ "$QRC" = 0 ] && ok || bad "d: file+row clear exited $QRC, not 0 ($QS_OUT)"
grep -qx 'cleared cooldown claude/a (.*) (fleet row cleared)' <<<"$QS_OUT" \
  && ok || bad "d: file+row clear printed '$QS_OUT'"
[ ! -e "$H/state/quota/cooldown/claude/a" ] && [ -z "$(row)" ] && ok || bad "d: a side survived the clear"

# e: no fleet store, no file
reset_all
qs
[ "$QRC" = 1 ] && [ "$QS_OUT" = 'no cooldown for claude/a (fleet not reachable)' ] \
  && ok || bad "e: unreachable fleet was not rc 1 + '(fleet not reachable)' (rc=$QRC, out=$QS_OUT)"
logged && bad "e: a clear that cleared nothing was logged" || ok

echo "quota-status-fleet-clear: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
