#!/bin/bash
# tests/account-pick.bh-1456-test.sh — AN ACCOUNT IN OVERAGE HAS HEADROOM.
#
# BH-1456. bin/account-pick.sh's account_reading_class applied the weekly
# threshold (ACCOUNT_WEEK_MAX, 90) to any `ok` poll, with no read of the
# endpoint's `extra_usage` object. So an account billing EXTRA USAGE — overage
# on, spend limit not reached, serving every request fine — came back `capped`
# the moment its subscription week crossed 90%, and both pickers parked it. On
# the hub that is the one account every stage bills to.
#
# The classifier is the ONE reading both pickers share (account_headroom here,
# _pa_metered in bin/lib/pool-account.sh), so the fix goes there and the pool
# inherits it. It now prints THREE fields, `class|rank_pct|detail`, because a
# refusal an operator cannot attribute is a refusal nobody debugs: `capped`
# alone meant five different things.
#
# THE NEGATIVES ARE THE POINT. Overage that is enabled but LIMIT-REACHED, or
# disabled by Anthropic (`disabled_reason`) or by the user (`user_disabled`),
# must still refuse — that refusal on 2026-09-18/19 was correct and this change
# must not spend it away. `extra_usage: null` (no reading) must behave exactly
# as it did before, and `is_enabled: false` must never read as overage.
#
#   a   weekly 100 + overage on, not limited  -> metered|84|overage, headroom 0
#   a2  the same at extra pct 98              -> capped|98|extra_cap (ACCOUNT_EXTRA_MAX)
#   b   spend_limit_reached: true             -> capped|100|spend_limit + a
#                                               drop:capped:spend_limit routing row
#   b2  disabled_reason set / user_disabled   -> capped|…|disabled
#   c   extra_usage: null                     -> capped|…|week, unchanged
#   c2  is_enabled:false, not limited         -> capped|…|week (flags are not overage)
#   d   a STALE poll with overage on          -> stale, and --overage-ok rc 1
#   e   the pool ranks the overage account through _pa_metered/pool_account_lease
#   f   bin/agent-call.sh's cooldown block: short stamp + WARN excerpt for an
#       overage account, the full window for anything else
#   g   bin/quota-status.sh surfaces the extra columns in --json and the table
#
# Run from anywhere: tests/account-pick.bh-1456-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/bin/lib" "$T/env/accounts.d" "$T/env/tokens.d" "$T/state/quota" \
         "$T/logs" "$T/flags" "$T/fly" "$T/bundle"
for f in account-pick.sh quota-status.sh auth-fingerprint.sh; do
  cp "$DIR/bin/$f" "$T/bin/$f"; chmod +x "$T/bin/$f"
done
cp "$DIR/bin/lib/pool-account.sh" "$T/bin/lib/pool-account.sh"
LIB="$T/bin/lib/pool-account.sh"
PICK="$T/bin/account-pick.sh"
printf 'claude 4\ncodex 4\n' > "$T/fly/account-capacity.conf"

# ONE clock read for the whole suite: every fixture's polled_at is derived from
# it, so no case can straddle a second boundary.
NOW=$(date -u +%s)
iso() { date -u -d "@$(( NOW - ${1:-60} ))" '+%Y-%m-%dT%H:%M:%SZ'; }

# The file bin/quota-poll.sh writes, with an extra_usage object in the shape
# normalize() now emits. `-` for a field means json null.
xquota() { # <account> <status> <age> <5h> <week> <enabled> <slr> <reason> <userdis> <xpct>
  local a="$1" st="$2" age="$3" five="$4" week="$5" en="$6" slr="$7" rsn="$8" ud="$9" xp="${10}"
  local xj
  if [ "$en" = "-" ]; then xj=null
  else
    xj=$(jq -nc --argjson e "$en" --argjson s "$slr" --argjson u "$ud" \
             --arg r "$rsn" --argjson p "$xp" \
             '{is_enabled:$e, spend_limit_reached:$s,
               disabled_reason:(if $r=="" then null else $r end),
               user_disabled:$u, monthly_limit:null, used_credits:null, pct:$p}')
  fi
  jq -n --arg a "$a" --arg s "$st" --arg t "$(iso "$age")" \
        --argjson five "$five" --argjson week "$week" --argjson x "$xj" \
    '{account:$a,vendor:"claude",status:$s,source:"oauth-usage",polled_at:$t,
      five_hour:(if $five==null then null else {pct:$five} end),
      seven_day:(if $week==null then null else {pct:$week} end),
      per_model:{}, extra_usage:$x}' > "$T/state/quota/$a.json"
}

cls() { # <account> -> the classifier's raw line
  env HARNESS="$T" bash -c '. "$1"; account_reading_class "$2" claude-fable-5-1' x "$PICK" "$1"
}
headroom_rc() { # <account> -> rc
  env HARNESS="$T" bash -c '. "$1"; account_headroom "$2" claude-fable-5-1 >/dev/null; echo $?' x "$PICK" "$1"
}

# =============================================================================
# a. WEEKLY 100 WITH OVERAGE ON -> metered, ranked on the EXTRA pct
# =============================================================================
xquota ov ok 60 0 100 true false "" false 84
C=$(cls ov)
[ "$C" = "metered|84|overage" ] \
  && ok || bad "a: weekly 100 with overage on classed '$C', expected metered|84|overage"
[ "$(headroom_rc ov)" = 0 ] \
  && ok || bad "a: account_headroom refused an account that is serving in overage"

# =============================================================================
# a2. …until the overage meter itself is at the cap
# =============================================================================
xquota ovmax ok 60 0 100 true false "" false 98
C=$(cls ovmax)
[ "$C" = "capped|98|extra_cap" ] \
  && ok || bad "a2: extra pct 98 classed '$C', expected capped|98|extra_cap"
[ "$(headroom_rc ovmax)" = 1 ] \
  && ok || bad "a2: an account over ACCOUNT_EXTRA_MAX must have no headroom"
# and the cap is a knob, not a constant
C=$(env ACCOUNT_EXTRA_MAX=99 HARNESS="$T" bash -c '. "$1"; account_reading_class ovmax claude-fable-5-1' x "$PICK")
[ "$C" = "metered|98|overage" ] \
  && ok || bad "a2: ACCOUNT_EXTRA_MAX=99 did not move the cap (got '$C')"

# =============================================================================
# b. SPEND LIMIT REACHED STILL REFUSES, and the routing log says WHY
# =============================================================================
xquota slr ok 60 100 100 true true "" false 100
C=$(cls slr)
[ "$C" = "capped|100|spend_limit" ] \
  && ok || bad "b: spend_limit_reached classed '$C', expected capped|100|spend_limit"
[ "$(headroom_rc slr)" = 1 ] \
  && ok || bad "b: an account at its spend limit must have no headroom"
# through the production entry point: account-pick.sh EXECUTED, the way
# bin/agent-call.sh:1288 and bin/lib/orc-account.sh:57 call it.
printf 'ACCOUNT_NAME=slr\nACCOUNT_VENDOR=claude\nACCOUNT_ENABLED=1\nACCOUNT_PRIORITY=10\nCLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-FIXTURE-slr\n' \
  > "$T/env/accounts.d/slr.env"; chmod 600 "$T/env/accounts.d/slr.env"
rm -f "$T/logs/account-routing.log"
env HARNESS="$T" HOME="$T" ACCOUNTS_DIR="$T/env/accounts.d" \
  bash "$PICK" execute claude claude-fable-5-1 >/dev/null 2>&1
grep -q 'drop:capped:spend_limit' "$T/logs/account-routing.log" 2>/dev/null \
  && ok || bad "b: no drop:capped:spend_limit row in account-routing.log: $(cat "$T/logs/account-routing.log" 2>/dev/null)"
rm -f "$T/env/accounts.d/slr.env"

# =============================================================================
# b2. DISABLED — by Anthropic, or by the user — refuses too
# =============================================================================
xquota dis ok 60 0 100 true false "payment_failed" false 10
C=$(cls dis)
[ "$C" = "capped|0|disabled" ] \
  && ok || bad "b2: disabled_reason classed '$C', expected capped|0|disabled"
xquota udis ok 60 0 100 true false "" true 10
C=$(cls udis)
[ "$C" = "capped|0|disabled" ] \
  && ok || bad "b2: user_disabled classed '$C', expected capped|0|disabled"

# =============================================================================
# c. NO READING AT ALL behaves exactly as it did before this change
# =============================================================================
xquota plain ok 60 0 100 - - "" - -
C=$(cls plain)
[ "$C" = "capped|0|week" ] \
  && ok || bad "c: extra_usage null classed '$C', expected capped|0|week"
[ "$(headroom_rc plain)" = 1 ] && ok || bad "c: a null reading changed headroom"
# under every threshold, still metered, with an empty detail
xquota fine ok 60 5 5 - - "" - -
C=$(cls fine)
[ "$C" = "metered|5|" ] \
  && ok || bad "c: a healthy account classed '$C', expected metered|5|"
# the 5h and per-model thresholds still name themselves
xquota hot ok 60 99 5 - - "" - -
[ "$(cls hot)" = "capped|99|5h" ] \
  && ok || bad "c: the 5h threshold classed '$(cls hot)', expected capped|99|5h"

# =============================================================================
# c2. THE FLAGS ARE NOT OVERAGE. is_enabled:false must not read as "on".
# =============================================================================
xquota off ok 60 0 100 false false "" false 0
C=$(cls off)
[ "$C" = "capped|0|week" ] \
  && ok || bad "c2: is_enabled:false classed '$C' — an off toggle read as overage, expected capped|0|week"

# =============================================================================
# d. A STALE POLL IS STILL STALE, overage or not — and --overage-ok says no
# =============================================================================
xquota old ok 20000 0 100 true false "" false 84
C=$(cls old)
[ "${C%%|*}" = stale ] \
  && ok || bad "d: a poll aged past the window classed '$C', expected stale"
env HARNESS="$T" bash "$PICK" --overage-ok old >/dev/null 2>&1
[ "$?" = 1 ] && ok || bad "d: --overage-ok said yes on a stale reading"
env HARNESS="$T" bash "$PICK" --overage-ok ov >/dev/null 2>&1
[ "$?" = 0 ] && ok || bad "d: --overage-ok said no on a fresh overage account"
env HARNESS="$T" bash "$PICK" --overage-ok slr >/dev/null 2>&1
[ "$?" = 1 ] && ok || bad "d: --overage-ok said yes on a spend-limited account"
env HARNESS="$T" bash "$PICK" --overage-ok plain >/dev/null 2>&1
[ "$?" = 1 ] && ok || bad "d: --overage-ok said yes on an account with no extra_usage reading"

# =============================================================================
# e. THE POOL INHERITS IT — _pa_metered and a real pool_account_lease
# =============================================================================
printf 'ACCOUNT_NAME=pv\nACCOUNT_VENDOR=claude\nACCOUNT_ENABLED=1\nACCOUNT_PRIORITY=20\nACCOUNT_LABEL=pv@fixture.test\nCLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-FIXTURE-do-not-ship-pv\n' \
  > "$T/env/accounts.d/pv.env"
printf 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-FIXTURE-do-not-ship-pv\n' > "$T/env/tokens.d/pv-setup-token.env"
chmod 600 "$T/env/accounts.d/pv.env" "$T/env/tokens.d/pv-setup-token.env"
xquota pv ok 60 0 100 true false "" false 84
printf 'CONSOLE_URL=https://console.test\nCLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-FIXTURE-MASTER\nGH_TOKEN=gh-fixture\nRUNNER_EXECUTE=claude\n' \
  > "$T/bundle/global.env"; chmod 600 "$T/bundle/global.env"
M=$(env HARNESS="$T" bash -c '. "$1"; _pa_metered pv claude-fable-5-1; echo " rc=$?"' x "$LIB")
[ "$M" = "84 rc=0" ] \
  && ok || bad "e: _pa_metered on an overage account answered '$M', expected '84 rc=0'"
OUT=$(env HARNESS="$T" ACCOUNTS_DIR="$T/env/accounts.d" bash -c \
  '. "$0"; pool_account_lease "$@"' "$LIB" proj BH-1456 "$T/bundle/global.env" mun0000000001 2>/dev/null)
[ "$(sed -n 's/.*\bname=\([^ ]*\).*/\1/p' <<<"$OUT")" = pv ] \
  && ok || bad "e: the pool did not lease the overage account: $OUT"
# and the drop class carries its detail when it IS a refusal
xquota pv ok 60 100 100 true true "" false 100
M=$(env HARNESS="$T" bash -c '. "$1"; _pa_metered pv claude-fable-5-1; echo " rc=$?"' x "$LIB")
[ "$M" = "capped:spend_limit rc=1" ] \
  && ok || bad "e: _pa_metered's drop class answered '$M', expected 'capped:spend_limit rc=1'"
# the aggregated reason must still resolve to all_capped, not a class per detail
R=$(env HARNESS="$T" bash -c '. "$1"; _pa_saturated_reason "$(printf "capped:spend_limit\ncapped:extra_cap\n")"' x "$LIB")
[ "$R" = all_capped ] \
  && ok || bad "e: _pa_saturated_reason answered '$R' for two capped details, expected all_capped"
rm -f "$T/env/accounts.d/pv.env" "$T/env/tokens.d/pv-setup-token.env" "$T/state/quota/pv.json"
rm -rf "$T/state/quota/leases" "$T/state/quota/pins"

# =============================================================================
# f. THE LADDER'S COOLDOWN ARM: short window + a WARN excerpt for overage
#    The production block, extracted verbatim from bin/agent-call.sh by its
#    `# >>> overage cooldown (BH-1456)` markers — so deleting the production
#    call site fails this case (D2/D3).
# =============================================================================
awk '/# >>> overage cooldown \(BH-1456\)/{f=1;next} /# <<< overage cooldown/{exit} f' \
  "$DIR/bin/agent-call.sh" > "$T/cool.body"
[ -s "$T/cool.body" ] \
  && ok || bad "f: could not extract the '# >>> overage cooldown (BH-1456)' block from bin/agent-call.sh"
cat > "$T/cool.sh" <<'EOF'
#!/bin/bash
set -uo pipefail
HARNESS="$T_DIR"
ladder_note() { printf '%s\n' "$2" >> "$NOTE_SINK"; }
ladder_scan_file() { printf '%s\n' "$SCAN_FILE"; }
runner=claude
acct="$ACCT"
LADDER_CLASS=account-exhausted
EOF
# BH-1853: the block writes its stamps through agent-call's own top-level helper.
awk '/^ac_cooldown_write\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$DIR/bin/agent-call.sh" >> "$T/cool.sh"
cat "$T/cool.body" >> "$T/cool.sh"
printf 'Claude AI: out of usage credits for this account\n' > "$T/scan.txt"
runcool() { # <account> -> prints the stamp age in seconds
  rm -rf "$T/state/quota/cooldown"; : > "$T/notes.txt"
  env T_DIR="$T" HARNESS="$T" ACCT="$1" NOTE_SINK="$T/notes.txt" \
      SCAN_FILE="$T/scan.txt" bash "$T/cool.sh" >/dev/null 2>&1
  local f="$T/state/quota/cooldown/claude/$1" at
  at=$(cat "$f" 2>/dev/null); case "${at:-}" in ''|*[!0-9]*) echo MISSING; return ;; esac
  echo $(( $(date -u +%s) - at ))
}
# An overage account is BACKDATED so it comes back in ~15 minutes rather than 6
# hours: the window is (ACCOUNT_COOLDOWN_SECS - ACCOUNT_OVERAGE_COOLDOWN_SECS)
# in the past. Every existing reader (account_cooling, cooldowns_json, the
# quota-poll sweep) is untouched by construction.
A=$(runcool ov)
case "$A" in MISSING) bad "f: no cooldown stamp was written for the overage account" ;;
  *) [ "$A" -ge 20000 ] && [ "$A" -le 20800 ] \
       && ok || bad "f: the overage stamp is ${A}s in the past, expected ~20700 (21600-900)" ;;
esac
grep -q 'WARN overage account ov refused' "$T/notes.txt" \
  && ok || bad "f: no WARN line naming the overage account: $(cat "$T/notes.txt")"
grep -q 'out of usage credits' "$T/notes.txt" \
  && ok || bad "f: the WARN line carries no excerpt of what the runner actually said"
# a normal account keeps the full window: the stamp is NOW, not backdated
A=$(runcool plain)
case "$A" in MISSING) bad "f: no cooldown stamp for a non-overage account" ;;
  *) [ "$A" -le 30 ] \
       && ok || bad "f: a non-overage account was backdated ${A}s — the 6h window must stand" ;;
esac
grep -q 'WARN overage account' "$T/notes.txt" \
  && bad "f: a non-overage account got the overage WARN line" || ok
# a spend-limited account is NOT overage-ok, so it keeps the long window too
A=$(runcool slr)
case "$A" in MISSING) bad "f: no cooldown stamp for the spend-limited account" ;;
  *) [ "$A" -le 30 ] \
       && ok || bad "f: a spend-limited account got the short window (${A}s backdated) — that refusal must stand" ;;
esac

# =============================================================================
# g. bin/quota-status.sh SURFACES IT — the operator screen, --json and table
# =============================================================================
printf 'ACCOUNT_NAME=ov\nACCOUNT_VENDOR=claude\nACCOUNT_ENABLED=1\nACCOUNT_PRIORITY=10\nACCOUNT_LABEL=ov@fixture.test\nCLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-FIXTURE-ov\n' \
  > "$T/env/accounts.d/ov.env"
printf 'ACCOUNT_NAME=plain\nACCOUNT_VENDOR=claude\nACCOUNT_ENABLED=1\nACCOUNT_PRIORITY=20\nCLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-FIXTURE-plain\n' \
  > "$T/env/accounts.d/plain.env"
chmod 600 "$T/env/accounts.d/ov.env" "$T/env/accounts.d/plain.env"
QS() { env HARNESS="$T" HOME="$T" ACCOUNTS_DIR="$T/env/accounts.d" bash "$T/bin/quota-status.sh" "$@" 2>/dev/null; }
J=$(QS --json)
[ "$(jq -r '.[]|select(.account=="ov")|.extra_usage.is_enabled' <<<"$J" 2>/dev/null)" = true ] \
  && ok || bad "g: quota-status --json does not carry extra_usage for the overage account"
[ "$(jq -r '.[]|select(.account=="plain")|.extra_usage' <<<"$J" 2>/dev/null)" = null ] \
  && ok || bad "g: quota-status --json should report extra_usage null for an account with no reading"
TXT=$(QS)
grep -q '^ extra: on 84%' <<<"$TXT" \
  && ok || bad "g: the table has no ' extra:' line for the overage account: $TXT"
[ "$(grep -c '^ extra:' <<<"$TXT")" = 1 ] \
  && ok || bad "g: expected exactly one ' extra:' line (only accounts with a reading get one), got $(grep -c '^ extra:' <<<"$TXT")"

echo "account-pick.bh-1456-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
