#!/bin/bash
# tests/pool-account-reset-cooldown-test.sh — a pool account that ran out is
# parked until the vendor says it comes back, and the ticket's pin to it goes
# (2026-09-23 pool loop).
#
# A weekly limit does not reset in six hours. The fixed ACCOUNT_COOLDOWN_SECS
# window put an exhausted account back in the pool's rank long before it could
# serve, and the ticket's sticky pin steered its next launch straight back to
# it. Pinned here, against the real bin/lib/pool-account.sh + bin/account-pick.sh:
#   1  a reset 3 days off: the stamp is (reset - window), account_cooling says
#      cooling, and the file's mtime is that same epoch, so quota-poll's mtime
#      sweep (find -mmin +2*window) does not collect it early
#   2  a reset in the past, and one beyond ACCOUNT_RESET_MAX_S, are not
#      believed: the normal "now" stamp is written
#   3  no reset at all: the normal stamp, exactly as before
#   4  pool_account_unpin drops a pin naming THIS account and keeps any other
#
# The file anchors wall-clock time in $NOW; every fixture timestamp is derived
# from that one value so the suite does not flake on calendar drift.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
NOW=$(date -u +%s)
WIN=21600

mkdir -p "$T/bin/lib" "$T/env/accounts.d" "$T/state/quota" "$T/logs" "$T/flags" "$T/fly"
for f in account-pick.sh auth-fingerprint.sh; do cp "$DIR/bin/$f" "$T/bin/$f"; chmod +x "$T/bin/$f"; done
cp "$DIR/bin/lib/pool-account.sh" "$T/bin/lib/pool-account.sh"
[ -r "$DIR/bin/lib/env-path.sh" ] && cp "$DIR/bin/lib/env-path.sh" "$T/bin/lib/env-path.sh"
LIB="$T/bin/lib/pool-account.sh"
STAMPF="$T/state/quota/cooldown/claude/max3"

libcall() { # libcall <extra-env...> -- <function> [args...]
  local envs=(); while [ "${1:-}" != "--" ]; do envs+=("$1"); shift; done; shift
  env HARNESS="$T" QUOTA_DIR="$T/state/quota" ACCOUNT_COOLDOWN_SECS="$WIN" "${envs[@]}" \
    bash -c '. "$0"; "$@"' "$LIB" "$@" 2>/dev/null
}
cooling() { libcall -- account_cooling claude max3; }
stamp() { cat "$STAMPF" 2>/dev/null || echo none; }
near_now() { local s; s=$(stamp); case "$s" in ''|*[!0-9]*) return 1 ;; esac; [ "$s" -ge "$NOW" ] && [ "$s" -le $((NOW + 60)) ]; }
clear_cool() { rm -rf "$T/state/quota/cooldown"; }

# ── 1. cooled until the reset ──────────────────────────────────────────────
clear_cool
RESET=$((NOW + 3*86400))
libcall -- pool_account_cooldown max3 pool-project-5-BH-1016 "$RESET"
[ "$(stamp)" = "$((RESET - WIN))" ] && ok || bad "1: stamp should be reset-window ($((RESET - WIN))), got $(stamp)"
cooling && ok || bad "1: account_cooling does not see the account as cooling"
MT=$(stat -c %Y "$STAMPF" 2>/dev/null || echo none)
[ "$MT" = "$((RESET - WIN))" ] && ok || bad "1: the stamp's mtime should be the stamp epoch, got $MT"
# quota-poll.sh's own sweep, verbatim in shape: delete stamps older than 2x the window.
find "$T/state/quota/cooldown" -type f -mmin "+$(( WIN / 30 ))" -delete 2>/dev/null
[ -f "$STAMPF" ] && ok || bad "1: quota-poll's mtime sweep collected a cooldown that runs for days yet"

# ── 2. resets that are not believed ────────────────────────────────────────
clear_cool
libcall -- pool_account_cooldown max3 why "$((NOW - 3600))"
near_now && ok || bad "2: a past reset must write the normal stamp, got $(stamp)"
clear_cool
libcall ACCOUNT_RESET_MAX_S=86400 -- pool_account_cooldown max3 why "$((NOW + 3*86400))"
near_now && ok || bad "2: a reset past ACCOUNT_RESET_MAX_S must write the normal stamp, got $(stamp)"
clear_cool
libcall -- pool_account_cooldown max3 why "soon"
near_now && ok || bad "2: a non-numeric reset must write the normal stamp, got $(stamp)"

# ── 3. no reset: exactly the old behaviour ─────────────────────────────────
clear_cool
libcall -- pool_account_cooldown max3 why
near_now && ok || bad "3: no reset must write the normal stamp, got $(stamp)"
cooling && ok || bad "3: the normal stamp does not read as cooling"

# ── 4. unpin ───────────────────────────────────────────────────────────────
mkdir -p "$T/state/quota/pins"
echo max3 > "$T/state/quota/pins/project-5-BH-1016"
echo max5 > "$T/state/quota/pins/project-5-BH-1017"
libcall -- pool_account_unpin project-5 BH-1016 max3
[ -e "$T/state/quota/pins/project-5-BH-1016" ] && bad "4: the pin to the exhausted account was not dropped" || ok
libcall -- pool_account_unpin project-5 BH-1017 max3
[ "$(cat "$T/state/quota/pins/project-5-BH-1017" 2>/dev/null)" = max5 ] && ok \
  || bad "4: a pin naming a DIFFERENT account was removed"

echo "pool-account-reset-cooldown: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
