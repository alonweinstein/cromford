#!/bin/bash
# tests/cooldown-max.bh-1853-test.sh — a cooldown stamp never moves backwards
# (BH-1853, #1850 follow-up 3b).
#
# A reset-dated stamp (state/quota/cooldown/claude/<acct> = reset - window,
# future-dated, mtime to match) says "this account is out until the vendor's
# weekly reset". Every writer used to overwrite the file unconditionally, so the
# next ordinary 6 h stamp for the same account replaced a week-long cooldown
# with `now` and the account came back into the rank days early. Every writer
# now keeps the later of the existing stamp and its own. Pinned against the
# real scripts, asserting on stamp values and mtimes:
#   C1  pool_account_cooldown: a reset stamp survives a later no-reset write,
#       and still reads as cooling 7 h on (and an earlier reset does not lower it)
#   C2  an expired old stamp is replaced by the standard write
#   C3  account_cooldown_stamp (bin/account-pick.sh) does not lower a future stamp
#   C4  account_cooldown_stamp_short does not lower a future stamp, and still
#       writes over an older one
#   C5  ac_cooldown_write, extracted by name from bin/agent-call.sh, keeps the
#       later of the two and writes when the new stamp is later
#   C6  a skipped write leaves the file's mtime untouched
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
PICK="$T/bin/account-pick.sh"
CD="$T/state/quota/cooldown/claude"
STAMPF="$CD/max3"

libcall() { # libcall <extra-env...> -- <function> [args...]
  local envs=(); while [ "${1:-}" != "--" ]; do envs+=("$1"); shift; done; shift
  env HARNESS="$T" QUOTA_DIR="$T/state/quota" ACCOUNT_COOLDOWN_SECS="$WIN" "${envs[@]}" \
    bash -c '. "$0"; "$@"' "$LIB" "$@" 2>/dev/null
}
pickcall() { # pickcall <function> [args...] — the picker sourced, not executed
  # $0 must not be the picker itself, or its BASH_SOURCE guard runs main.
  env HARNESS="$T" QUOTA_DIR="$T/state/quota" ACCOUNT_COOLDOWN_SECS="$WIN" \
    bash -c 'p="$1"; shift; . "$p"; "$@"' pickcall "$PICK" "$@" 2>/dev/null
}
stamp() { cat "$STAMPF" 2>/dev/null || echo none; }
mtime() { stat -c %Y "$1" 2>/dev/null || echo none; }
near_now() { local s; s=$(stamp); case "$s" in ''|*[!0-9]*) return 1 ;; esac; [ "$s" -ge "$NOW" ] && [ "$s" -le $((NOW + 60)) ]; }
clear_cool() { rm -rf "$T/state/quota/cooldown"; }
put() { mkdir -p "$CD"; printf '%s\n' "$1" > "$STAMPF"; }
# account_cooling's own arithmetic, at an arbitrary "now".
cooling_at() { local s; s=$(stamp); case "$s" in ''|*[!0-9]*) return 1 ;; esac; [ $(( $1 - s )) -lt "$WIN" ]; }

# ── C1. a reset stamp survives a later no-reset write ──────────────────────
clear_cool
RESET=$((NOW + 7*86400))
libcall -- pool_account_cooldown max3 why "$RESET"
[ "$(stamp)" = "$((RESET - WIN))" ] && ok || bad "C1: fixture: the reset write should stamp reset-window ($((RESET - WIN))), got $(stamp)"
libcall -- pool_account_cooldown max3 why
[ "$(stamp)" = "$((RESET - WIN))" ] && ok \
  || bad "C1: a no-reset write lowered the week-long reset stamp $((RESET - WIN)) to $(stamp)"
cooling_at $((NOW + 7*3600)) && ok || bad "C1: 7 h on, the account no longer reads as cooling (stamp $(stamp))"
# An EARLIER reset is a lower stamp: it must not shorten the later one either.
libcall -- pool_account_cooldown max3 why "$((NOW + 3*86400))"
[ "$(stamp)" = "$((RESET - WIN))" ] && ok \
  || bad "C1: an earlier reset lowered the stamp from $((RESET - WIN)) to $(stamp)"
# And a LATER reset still moves it forward.
RESET2=$((NOW + 7*86400 + 3600))
libcall -- pool_account_cooldown max3 why "$RESET2"
[ "$(stamp)" = "$((RESET2 - WIN))" ] && ok || bad "C1: a later reset did not move the stamp forward, got $(stamp)"
[ "$(mtime "$STAMPF")" = "$((RESET2 - WIN))" ] && ok || bad "C1: the forward reset write did not set the mtime, got $(mtime "$STAMPF")"

# ── C2. an expired old stamp is replaced ───────────────────────────────────
clear_cool; put $((NOW - 30000))
libcall -- pool_account_cooldown max3 why
near_now && ok || bad "C2: an expired stamp was not replaced by the standard write, got $(stamp)"
clear_cool; put "garbage"
libcall -- pool_account_cooldown max3 why
near_now && ok || bad "C2: a non-numeric stamp was not replaced (it counts as 0), got $(stamp)"
clear_cool
libcall -- pool_account_cooldown max3 why
near_now && ok || bad "C2: no stamp at all: the standard write did not land, got $(stamp)"

# ── C3. account_cooldown_stamp ─────────────────────────────────────────────
FUT=$((NOW + 86400))
clear_cool; put "$FUT"
pickcall account_cooldown_stamp claude max3; rc=$?
[ "$(stamp)" = "$FUT" ] && ok || bad "C3: account_cooldown_stamp lowered a future stamp $FUT to $(stamp)"
[ "$rc" = 0 ] && ok || bad "C3: account_cooldown_stamp must stay rc 0 when it skips, got $rc"
clear_cool; put $((NOW - 30000))
pickcall account_cooldown_stamp claude max3
near_now && ok || bad "C3: account_cooldown_stamp did not replace an older stamp, got $(stamp)"

# ── C4. account_cooldown_stamp_short ───────────────────────────────────────
clear_cool; put "$FUT"
pickcall account_cooldown_stamp_short claude max3 900
[ "$(stamp)" = "$FUT" ] && ok || bad "C4: account_cooldown_stamp_short lowered a future stamp $FUT to $(stamp)"
clear_cool; put $((NOW - 30000))
pickcall account_cooldown_stamp_short claude max3 900
S=$(stamp); EXP=$((NOW - (WIN - 900)))
case "$S" in ''|*[!0-9]*) S=0 ;; esac
[ "$S" -ge "$EXP" ] && [ "$S" -le $((EXP + 60)) ] && ok \
  || bad "C4: the short stamp did not replace an older one (want ~$EXP, got $(stamp))"

# ── C5. ac_cooldown_write from bin/agent-call.sh ───────────────────────────
FN=$(awk '/^ac_cooldown_write\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$DIR/bin/agent-call.sh")
if [ -z "$FN" ]; then
  bad "C5: bin/agent-call.sh defines no top-level ac_cooldown_write() — its inline cooldown writes cannot keep the later stamp"
  bad "C6: ac_cooldown_write missing — the mtime of a skipped write cannot be checked"
else
  printf '%s\n' "$FN" > "$T/acw.sh"
  acw() { bash -c '. "$0"; ac_cooldown_write "$@"' "$T/acw.sh" "$@" 2>/dev/null; }
  AF="$T/state/quota/cooldown/codex/default"
  mkdir -p "${AF%/*}"; printf '%s\n' "$FUT" > "$AF"
  acw "$AF" "$NOW"
  [ "$(cat "$AF")" = "$FUT" ] && ok || bad "C5: ac_cooldown_write lowered $FUT to $(cat "$AF")"
  acw "$AF" $((FUT + 10))
  [ "$(cat "$AF")" = "$((FUT + 10))" ] && ok || bad "C5: ac_cooldown_write did not write a later stamp, got $(cat "$AF")"
  printf 'x\n' > "$AF"; acw "$AF" "$NOW"
  [ "$(cat "$AF")" = "$NOW" ] && ok || bad "C5: a non-numeric old stamp counts as 0, got $(cat "$AF")"
  rm -f "$AF"; acw "$AF" "$NOW"
  [ "$(cat "$AF" 2>/dev/null)" = "$NOW" ] && ok || bad "C5: no old stamp: the write did not land"

  # ── C6 (agent-call half). a skipped write keeps the mtime ─────────────────
  printf '%s\n' "$FUT" > "$AF"; touch -d "@$FUT" "$AF"
  acw "$AF" "$NOW"
  [ "$(mtime "$AF")" = "$FUT" ] && ok || bad "C6: ac_cooldown_write's skipped write moved the mtime from $FUT to $(mtime "$AF")"
fi

# ── C6. a skipped write leaves the mtime untouched ─────────────────────────
clear_cool
libcall -- pool_account_cooldown max3 why "$RESET"
libcall -- pool_account_cooldown max3 why
[ "$(mtime "$STAMPF")" = "$((RESET - WIN))" ] && ok \
  || bad "C6: pool_account_cooldown's skipped write moved the mtime from $((RESET - WIN)) to $(mtime "$STAMPF")"
pickcall account_cooldown_stamp claude max3
pickcall account_cooldown_stamp_short claude max3 900
[ "$(mtime "$STAMPF")" = "$((RESET - WIN))" ] && ok \
  || bad "C6: the picker's skipped writes moved the mtime from $((RESET - WIN)) to $(mtime "$STAMPF")"
# quota-poll.sh's sweep, in shape: the future mtime keeps the stamp alive.
find "$T/state/quota/cooldown" -type f -mmin "+$(( WIN / 30 ))" -delete 2>/dev/null
[ "$(stamp)" = "$((RESET - WIN))" ] && ok || bad "C6: quota-poll's mtime sweep collected the reset stamp"

echo "cooldown-max.bh-1853: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
