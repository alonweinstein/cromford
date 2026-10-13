#!/bin/bash
# tests/account-cooldown-vendor.bh-940-test.sh — a cooldown belongs to ONE
# vendor's account, not to a NAME every vendor shares.
#
# THE INCIDENT (2026-09-18). codex's `default` account ran out of usage credits.
# bin/agent-call.sh stamped state/quota/cooldown/default, bin/account-pick.sh
# read state/quota/cooldown/default for EVERY vendor, and so the box's perfectly
# healthy claude `default` credentials were refused for six hours: every claude
# pick answered rc 2, every review lane logged `no_headroom` and descended,
# while state/quota/default.json still said `ok`. One name, five vendors, one
# file — the key was missing the only field that made it mean anything.
#
# So the key is `state/quota/cooldown/<vendor>/<account>` and the three places
# that touch it move together. This suite drives the real scripts against a
# scratch $HARNESS and asserts on ARTIFACTS — files under $T/state and lines in
# $T/logs — never on source text.
#
# Sections:
#   A  isolation: a codex cooldown never routes claude, and the reverse
#   B  a legacy unscoped file is swept to .legacy/ after ONE log row, never read
#   C  the writer (bin/agent-call.sh, driven) names the vendor it cooled
#   D  the write stays inside the account-exhausted|auth branch
#   E  the Fly pool's writer and reader moved with it (bin/lib/pool-account.sh)
#   F  bin/quota-status.sh shows every vendor's cooldown for an account
#   G  `quota-status.sh --clear-cooldown <vendor> <account>` — the operator lever
#   H  expiry, on the scoped path
#
# Run from anywhere: tests/account-cooldown-vendor.bh-940-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1510.1: agent-call reads its ladders from model_routes; this worker-less box carries the resolver's cache of #1507's table.
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$T" testproj
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# The clock is read ONCE and every stamp below is derived from it, so no case
# can straddle a second boundary and no case picks its own red day.
NOW=$(date -u +%s)
WINDOW=21600          # the ACCOUNT_COOLDOWN_SECS default this suite pins against

# Recognisable fake secrets: if one of these reaches an operator surface, the
# feature is leaking.
TOKP="sk-ant-oat01-FIXTURE-PARENT-token"
TOKPOOL="sk-ant-oat01-FIXTURE-POOL-do-not-ship"
TOKMASTER="sk-ant-oat01-FIXTURE-MASTER-token"

mkdir -p "$T/bin/lib" "$T/fakebin" "$T/env/accounts.d" "$T/env/tokens.d" \
         "$T/state/quota" "$T/logs" "$T/flags" "$T/locks" "$T/bundle" "$T/fly"
mkdir -p "$T/.claude-a" "$T/.claude-b" "$T/.claude-c" "$T/.codex-d" "$T/.codex"
echo '{}' > "$T/.codex/auth.json"
printf 'claude 4\ncodex 4\n' > "$T/fly/account-capacity.conf"

# ---------- the harness under test -------------------------------------------
for f in account-pick.sh quota-status.sh auth-fingerprint.sh; do
  cp "$DIR/bin/$f" "$T/bin/$f"; chmod +x "$T/bin/$f"
done
cp "$DIR/bin/lib/pool-account.sh" "$T/bin/lib/pool-account.sh"
PICK="$T/bin/account-pick.sh"
LIB="$T/bin/lib/pool-account.sh"

# ---------- fakes ------------------------------------------------------------
# The fake claude reports which credential dir it was handed (never the value)
# and fails with the vendor's own exhaustion text when CREDITS_LIST names it.
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
M=""
for a in "$@"; do case "$a" in claude-*) M="$a" ;; esac; done
printf 'claude|%s|%s\n' "${CLAUDE_CONFIG_DIR:-NONE}" "$M" >> "$ORDER_SINK"
if [ -n "${CREDITS_LIST:-}" ] && grep -qxF "${CLAUDE_CONFIG_DIR:-default}" "$CREDITS_LIST" 2>/dev/null; then
  echo "${CREDITS_TEXT:-Claude AI: out of usage credits for this account}" >&2
  exit 1
fi
printf '{"result":"ok","usage":{"input_tokens":10,"output_tokens":2},"total_cost_usd":0.01}\n'
EOF
cat > "$T/fakebin/codex" <<'EOF'
#!/bin/bash
echo "codex|${CODEX_HOME:-NONE}|-" >> "$ORDER_SINK"
echo "model: gpt-6-astra" >&2
[ -n "${CODEX_STDERR:-}" ] && echo "$CODEX_STDERR" >&2
exit "${CODEX_RC:-0}"
EOF
cat > "$T/fakebin/grok" <<'EOF'
#!/bin/bash
echo 'grok|-|-' >> "$ORDER_SINK"
echo "grok answered"
EOF
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
printf '#!/bin/bash\necho subscription\n' > "$T/bin/billing-mode.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"
printf '#!/bin/bash\necho "test rules"\n' > "$T/bin/sync-agent-rules.sh"
printf '#!/bin/bash\necho "1 2 3 4"\n' > "$T/bin/codex-usage.sh"
chmod +x "$T/fakebin/"* "$T/bin/"*.sh
echo '{}' > "$T/empty-catalog.json"

# ---------- fixtures ---------------------------------------------------------
reg() { cat > "$T/env/accounts.d/$1.env"; chmod 600 "$T/env/accounts.d/$1.env"; }
clear_reg()  { rm -f "$T/env/accounts.d"/*.env 2>/dev/null; }
clear_cool() { rm -rf "$T/state/quota/cooldown"; }
clear_logs() { : > "$T/logs/account-routing.log"; : > "$T/logs/failovers.log"; }

# every regular file anywhere under cooldown/, including .legacy/
cool_count() { find "$T/state/quota/cooldown" -type f 2>/dev/null | grep -c '' ; }
vendor_count() { find "$T/state/quota/cooldown/$1" -type f 2>/dev/null | grep -c '' ; }

stamp() { # stamp <vendor> <account> [age-secs]
  mkdir -p "$T/state/quota/cooldown/$1"
  echo $(( NOW - ${3:-0} )) > "$T/state/quota/cooldown/$1/$2"
}
stamp_legacy() { # stamp_legacy <name> [age-secs] — the OLD unscoped key
  mkdir -p "$T/state/quota/cooldown"
  echo $(( NOW - ${2:-0} )) > "$T/state/quota/cooldown/$1"
}

accounts_abd() { # a,b on claude (b wins on priority), d on codex
  clear_reg
  reg a <<EOF
ACCOUNT_NAME=a
ACCOUNT_VENDOR=claude
ACCOUNT_PRIORITY=20
CLAUDE_CONFIG_DIR=$T/.claude-a
EOF
  reg b <<EOF
ACCOUNT_NAME=b
ACCOUNT_VENDOR=claude
ACCOUNT_PRIORITY=10
CLAUDE_CONFIG_DIR=$T/.claude-b
EOF
  reg d <<EOF
ACCOUNT_NAME=d
ACCOUNT_VENDOR=codex
CODEX_HOME=$T/.codex-d
EOF
}

pick() { # pick <extra-env...> -- <stage> <vendor> <model> ; echoes stdout, sets PRC
  local envs=(); while [ "${1:-}" != "--" ]; do envs+=("$1"); shift; done; shift
  PICK_OUT=$(env HARNESS="$T" HOME="$T" ACCOUNTS_DIR="$T/env/accounts.d" \
    "${envs[@]+"${envs[@]}"}" bash "$PICK" "$@" 2>/dev/null); PRC=$?
  printf '%s\n' "$PICK_OUT"
}
pname() { pick "$@" | sed -n 's/^name=//p'; }

# run_call <extra-env...> — drives the REAL bin/agent-call.sh (D2: the writer is
# exercised through its production entry point, not through a sourced seam).
run_call() {
  : > "$T/order"
  ( export ORDER_SINK="$T/order" PATH="$T/fakebin:$PATH" \
           HARNESS="$T" HOME="$T" ACCOUNTS_DIR="$T/env/accounts.d" \
           LADDER_BACKOFF_SECS=0 LADDER_TIER2_GROK=1 \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" \
           AUTH_ACCOUNTS_CATALOG="$T/empty-catalog.json" \
           AUTH_ACCOUNTS_LOCAL="$T/state/auth-accounts.local.json" \
           RUNNER_EVAL=claude
    "$@" bash "$DIR/bin/agent-call.sh" eval testproj claude-fable-5-1 60 "$T/out.txt" "hello" \
      >/dev/null 2>&1 )
  echo $?
}

qs() { # qs <args...> — bin/quota-status.sh against the scratch box, sets QRC
  QS_OUT=$(env HARNESS="$T" HOME="$T" ACCOUNTS_DIR="$T/env/accounts.d" \
    bash "$T/bin/quota-status.sh" "$@" 2>&1); QRC=$?
  printf '%s\n' "$QS_OUT"
}

# =============================================================================
# A. ISOLATION — a cooldown on one vendor's `default` never touches another's
# =============================================================================
clear_reg; clear_cool; clear_logs
stamp codex default
pick -- review claude claude-fable-5-1 >/dev/null
[ "$(sed -n 's/^name=//p' <<<"$PICK_OUT")" = default ] && [ "$PRC" = 0 ] \
  && ok || bad "A: a codex cooldown refused the claude default (rc=$PRC, out='$PICK_OUT')"
pick -- review claude claude-opus-5 >/dev/null
[ "$(sed -n 's/^name=//p' <<<"$PICK_OUT")" = default ] && [ "$PRC" = 0 ] \
  && ok || bad "A: a codex cooldown refused the claude default on opus (rc=$PRC)"
pick -- execute codex gpt-6-astra >/dev/null
[ "$PRC" = 2 ] && ok || bad "A: the codex cooldown did not exclude the codex default (rc=$PRC)"

clear_cool
stamp claude default
pick -- execute codex gpt-6-astra >/dev/null
[ "$(sed -n 's/^name=//p' <<<"$PICK_OUT")" = default ] && [ "$PRC" = 0 ] \
  && ok || bad "A: a claude cooldown refused the codex default (rc=$PRC)"
pick -- review claude claude-fable-5-1 >/dev/null
[ "$PRC" = 2 ] && ok || bad "A: the claude cooldown did not exclude the claude default (rc=$PRC)"

accounts_abd; clear_cool
stamp claude b
[ "$(pname -- eval claude claude-fable-5-1)" = a ] \
  && ok || bad "A: a cooling claude account was still picked"
[ "$(pname -- execute codex gpt-6-astra)" = d ] \
  && ok || bad "A: a claude cooldown reached the codex registry account"

# =============================================================================
# B. THE LEGACY UNSCOPED FILE — swept once, logged once, never read
# =============================================================================
clear_reg; clear_cool; clear_logs
stamp_legacy default
stamp_legacy claude          # an account literally named after a vendor
pick -- review claude claude-fable-5-1 >/dev/null
[ "$(sed -n 's/^name=//p' <<<"$PICK_OUT")" = default ] && [ "$PRC" = 0 ] \
  && ok || bad "B: the legacy unscoped cooldown was still applied to claude (rc=$PRC)"
[ -f "$T/state/quota/cooldown/.legacy/default" ] && [ -f "$T/state/quota/cooldown/.legacy/claude" ] \
  && ok || bad "B: the legacy files were not moved under .legacy/: $(ls -A "$T/state/quota/cooldown" 2>/dev/null | paste -sd,)"
[ ! -e "$T/state/quota/cooldown/default" ] \
  && ok || bad "B: the unscoped cooldown file is still where the reader used to look"
[ "$(grep -c ',default,legacy_cooldown_ignored$' "$T/logs/account-routing.log")" = 1 ] \
  && ok || bad "B: expected exactly one legacy_cooldown_ignored row for 'default', got $(grep -c ',default,legacy_cooldown_ignored$' "$T/logs/account-routing.log")"
[ "$(grep -c ',claude,legacy_cooldown_ignored$' "$T/logs/account-routing.log")" = 1 ] \
  && ok || bad "B: expected exactly one legacy_cooldown_ignored row for 'claude', got $(grep -c ',claude,legacy_cooldown_ignored$' "$T/logs/account-routing.log")"
pick -- review claude claude-fable-5-1 >/dev/null
[ "$(grep -c legacy_cooldown_ignored "$T/logs/account-routing.log")" = 2 ] \
  && ok || bad "B: a second process logged the sweep again ($(grep -c legacy_cooldown_ignored "$T/logs/account-routing.log") rows)"

# =============================================================================
# C. THE WRITER NAMES ITS VENDOR — driven through bin/agent-call.sh
# =============================================================================
accounts_abd; clear_cool; clear_logs
RC=$(run_call env RUNNER_EVAL=codex ACCOUNT_ROUTING=1 CODEX_RC=1 \
     CODEX_STDERR="stream error: usage limit reached" CLAUDE_CODE_OAUTH_TOKEN="$TOKP")
[ -f "$T/state/quota/cooldown/codex/d" ] \
  && ok || bad "C: a codex exhaustion did not cool codex/d (tree: $(find "$T/state/quota/cooldown" 2>/dev/null | paste -sd,))"
[ ! -e "$T/state/quota/cooldown/d" ] \
  && ok || bad "C: the writer still wrote the unscoped key"
[ "$(vendor_count claude)" = 0 ] \
  && ok || bad "C: a codex exhaustion left a file under cooldown/claude/"
[ "$(pname -- review claude claude-fable-5-1)" = b ] \
  && ok || bad "C: claude routing was refused after a codex exhaustion"
# The ticket's second acceptance line, through the lane and not just the picker:
# with only a codex stamp on the box, a claude call completes and NOTHING logs
# the phantom no_headroom that took the hub down for six hours.
: > "$T/logs/account-routing.log"
RC=$(run_call env ACCOUNT_ROUTING=1 CLAUDE_CODE_OAUTH_TOKEN="$TOKP")
[ "$RC" = 0 ] && ok || bad "C: a claude call failed while only codex was cooling (rc=$RC)"
grep -q '^claude|' "$T/order" \
  && ok || bad "C: the claude lane never ran: $(paste -sd, "$T/order")"
[ "$(grep -c ',no_headroom$' "$T/logs/account-routing.log")" = 0 ] \
  && ok || bad "C: a codex cooldown still logs no_headroom for claude: $(grep ',no_headroom$' "$T/logs/account-routing.log" | paste -sd';')"
grep -q 'no claude account with quota headroom' "$T/logs/failovers.log" \
  && bad "C: the claude lane reported no headroom after a CODEX exhaustion" || ok

clear_cool; clear_logs
printf '%s\n' "$T/.claude-b" > "$T/credits"
RC=$(run_call env ACCOUNT_ROUTING=1 CREDITS_LIST="$T/credits" CLAUDE_CODE_OAUTH_TOKEN="$TOKP")
[ "$RC" = 0 ] && ok || bad "C: the rotation after a claude exhaustion did not recover the stage (rc=$RC)"
[ -f "$T/state/quota/cooldown/claude/b" ] \
  && ok || bad "C: a claude exhaustion did not cool claude/b"
[ "$(vendor_count codex)" = 0 ] \
  && ok || bad "C: a claude exhaustion left a file under cooldown/codex/"
[ -d "$T/state/quota/cooldown/claude" ] \
  && ok || bad "C: cooldown/claude is not a directory"
grep -q 'class=account-exhausted(quota)' "$T/logs/failovers.log" \
  && ok || bad "C: the exhaustion class left the failovers.log line: $(tail -1 "$T/logs/failovers.log")"
grep -q 'account claude/b cooled down' "$T/logs/failovers.log" \
  && ok || bad "C: the ladder note does not name the vendor it cooled: $(grep 'cooled down' "$T/logs/failovers.log" | tail -1)"
rm -f "$T/credits"

# =============================================================================
# D. THE WRITE STAYS INSIDE THE account-exhausted|auth BRANCH
# =============================================================================
accounts_abd; clear_cool; clear_logs
RC=$(run_call env RUNNER_EVAL=codex ACCOUNT_ROUTING=1 CODEX_RC=1 \
     CODEX_STDERR="boom: the model could not do the job" CLAUDE_CODE_OAUTH_TOKEN="$TOKP")
[ "$(cool_count)" = 0 ] \
  && ok || bad "D: a real failure cooled an account down ($(find "$T/state/quota/cooldown" -type f 2>/dev/null | paste -sd,))"
grep -q 'class=real-failure' "$T/logs/failovers.log" \
  && ok || bad "D: the codex failure was not classified real-failure: $(tail -1 "$T/logs/failovers.log")"

clear_cool; clear_logs
RC=$(run_call env RUNNER_EVAL=codex ACCOUNT_ROUTING=1 CODEX_RC=1 \
     CODEX_STDERR="HTTP 401 unauthorized" CLAUDE_CODE_OAUTH_TOKEN="$TOKP")
[ -f "$T/state/quota/cooldown/codex/d" ] \
  && ok || bad "D: a 401 on codex did not cool codex/d"
[ "$(vendor_count claude)" = 0 ] \
  && ok || bad "D: a codex auth failure left a file under cooldown/claude/"

# =============================================================================
# E. THE FLY POOL — its writer and its reader moved with the rest
# =============================================================================
accounts_abd; clear_cool; clear_logs
for A in a b; do
  printf 'CLAUDE_CODE_OAUTH_TOKEN=%s-%s\n' "$TOKPOOL" "$A" > "$T/env/tokens.d/$A-setup-token.env"
  chmod 600 "$T/env/tokens.d/$A-setup-token.env"
  jq -n --arg a "$A" --arg t "$(date -u -d "@$(( NOW - 60 ))" '+%Y-%m-%dT%H:%M:%SZ')" \
    '{account:$a,vendor:"claude",status:"unreadable",source:"none",polled_at:$t,
      five_hour:null,seven_day:null,per_model:{}}' > "$T/state/quota/$A.json"
done
mkbundle() {
  printf 'CONSOLE_URL=https://console.test\nCLAUDE_CODE_OAUTH_TOKEN=%s\nGH_TOKEN=gh-fixture\nRUNNER_EXECUTE=claude\n' \
    "$TOKMASTER" > "$T/bundle/global.env"
  chmod 600 "$T/bundle/global.env"
}
lease() { # lease <ticket-key> <machine-id> — a key of its own per case, because
          # the pool pins a build to the account that served it
  env HARNESS="$T" bash -c '. "$1"; . "$2"; pool_account_lease proj "$3" "$4" "$5"' \
    _ "$PICK" "$LIB" "$1" "$T/bundle/global.env" "$2" 2>/dev/null
}
lname() { sed -n 's/.*\bname=\([^ ]*\).*/\1/p' <<<"$1"; }

env HARNESS="$T" bash -c '. "$1"; . "$2"; pool_account_cooldown b pool-x' _ "$PICK" "$LIB" >/dev/null 2>&1
[ -f "$T/state/quota/cooldown/claude/b" ] \
  && ok || bad "E: the pool reap did not write the vendor-scoped key"
[ ! -e "$T/state/quota/cooldown/b" ] \
  && ok || bad "E: the pool reap still writes the unscoped key"
[ "$(grep -c ',b,cooldown:pool-x$' "$T/logs/account-routing.log")" = 1 ] \
  && ok || bad "E: the pool cooldown row left the routing log"
mkbundle
[ "$(lname "$(lease K-940a mun0000000001)")" = a ] \
  && ok || bad "E: the pool leased the account its own reap had just cooled"

clear_cool
env HARNESS="$T" bash -c '. "$1"; pool_account_cooldown b pool-y' _ "$LIB" >/dev/null 2>&1
[ -f "$T/state/quota/cooldown/claude/b" ] \
  && ok || bad "E: the lib sourced WITHOUT the picker wrote a different path"

# The pool never cools `default`: the pool leases NAMED accounts, and the
# box-wide credentials are not one of them. That guard predates BH-940 and the
# vendor directory must not have given it a new place to write.
clear_cool
env HARNESS="$T" bash -c '. "$1"; . "$2"; pool_account_cooldown default x' _ "$PICK" "$LIB" >/dev/null 2>&1
[ "$(cool_count)" = 0 ] \
  && ok || bad "E: the pool cooled 'default' down ($(find "$T/state/quota/cooldown" -type f 2>/dev/null | paste -sd,))"

clear_cool; stamp codex b
mkbundle
[ "$(lname "$(lease K-940b mun0000000002)")" = b ] \
  && ok || bad "E: a codex cooldown dropped a claude account from the pool"
rm -f "$T/env/tokens.d"/*.env "$T/state/quota/a.json" "$T/state/quota/b.json"
rm -rf "$T/state/quota/leases"

# =============================================================================
# F. quota-status SHOWS EVERY VENDOR'S COOLDOWN FOR AN ACCOUNT
# =============================================================================
accounts_abd; clear_cool; clear_logs
reg c <<EOF
ACCOUNT_NAME=c
ACCOUNT_VENDOR=claude
ACCOUNT_PRIORITY=30
CLAUDE_CONFIG_DIR=$T/.claude-c
EOF
stamp codex default
stamp claude c 60
STATUS=$(qs)
grep -q ' cooldown: default cx to ' <<<"$STATUS" \
  && ok || bad "F: the default row does not show its CODEX cooldown: $STATUS"
grep -q ' cooldown: c cl to ' <<<"$STATUS" \
  && ok || bad "F: the claude cooldown on c is not rendered: $STATUS"
WIDE=$(awk 'length($0) > 40 {print length($0)": "$0}' <<<"$STATUS")
[ -z "$WIDE" ] && ok || bad "F: the table is wider than 40 columns:
$WIDE"
grep -qE 'sk-ant|FIXTURE' <<<"$STATUS" && bad "F: quota-status printed a secret" || ok
J=$(qs --json)
jq -e '.[] | select(.account=="default") | .cooldowns.codex | type == "string"' >/dev/null 2>&1 <<<"$J" \
  && ok || bad "F: --json has no cooldowns.codex for default: $J"
jq -e '.[] | select(.account=="default") | .cooldown_until == null' >/dev/null 2>&1 <<<"$J" \
  && ok || bad "F: cooldown_until on the claude-vendor default row is not null while only codex is cooling"
jq -e '.[] | select(.account=="c") | .cooldown_until | type == "string"' >/dev/null 2>&1 <<<"$J" \
  && ok || bad "F: cooldown_until is missing on a cooling claude account"
jq -e '.[] | select(.account=="c") | .cooldowns.claude | type == "string"' >/dev/null 2>&1 <<<"$J" \
  && ok || bad "F: cooldowns.claude is missing on a cooling claude account"

# =============================================================================
# G. THE OPERATOR LEVER — --clear-cooldown <vendor> <account>
# =============================================================================
clear_cool; clear_logs
stamp codex default; stamp codex d; stamp claude c
qs --clear-cooldown codex default >/dev/null
[ "$QRC" = 0 ] && ok || bad "G: --clear-cooldown exited $QRC"
grep -q '^cleared cooldown codex/default (stamped 20[0-9][0-9]-.*would have run to [0-9][0-9]:[0-9][0-9]Z)$' <<<"$QS_OUT" \
  && ok || bad "G: the lever did not say what it cleared: $QS_OUT"
[ ! -e "$T/state/quota/cooldown/codex/default" ] \
  && ok || bad "G: the cooldown file survived --clear-cooldown"
[ "$(grep -c ',default,cooldown_cleared:codex$' "$T/logs/account-routing.log")" = 1 ] \
  && ok || bad "G: the clear was not recorded in account-routing.log"
[ "$(grep -c 'cooldown codex/default cleared by operator' "$T/logs/failovers.log")" = 1 ] \
  && ok || bad "G: the clear was not recorded in failovers.log"
[ "$(pname -- execute codex gpt-6-astra)" = default ] \
  && ok || bad "G: the picker still refuses the cleared codex default"
# Nothing to clear is rc 1 and says so — and it logs NOTHING, because a
# `cooldown_cleared` row for a clear that did not happen is a lie the next
# operator reads back out of the log.
: > "$T/logs/account-routing.log"; : > "$T/logs/failovers.log"
qs --clear-cooldown codex default >/dev/null
[ "$QRC" = 1 ] && grep -q '^no cooldown for codex/default$' <<<"$QS_OUT" \
  && ok || bad "G: clearing an absent cooldown is not rc 1 + 'no cooldown' (rc=$QRC, out=$QS_OUT)"
[ ! -s "$T/logs/account-routing.log" ] && [ ! -s "$T/logs/failovers.log" ] \
  && ok || bad "G: a clear that removed nothing still logged: $(cat "$T/logs/account-routing.log" "$T/logs/failovers.log")"
# An unreadable stamp is still a file the picker walks past, so the lever
# removes it and says the stamp could not be read.
mkdir -p "$T/state/quota/cooldown/codex"; echo 'garbage' > "$T/state/quota/cooldown/codex/default"
qs --clear-cooldown codex default >/dev/null
[ "$QRC" = 0 ] && [ ! -e "$T/state/quota/cooldown/codex/default" ] \
  && grep -q 'unreadable' <<<"$QS_OUT" \
  && ok || bad "G: an unreadable stamp was not cleared (rc=$QRC, out=$QS_OUT)"
qs --clear-cooldown bogus default >/dev/null
[ "$QRC" = 2 ] && ok || bad "G: an unknown vendor exited $QRC, not 2"
qs --clear-cooldown claude 'Bad Name' >/dev/null
[ "$QRC" = 2 ] && ok || bad "G: an invalid account name exited $QRC, not 2"
qs --clear-cooldown claude >/dev/null
[ "$QRC" = 2 ] && ok || bad "G: a missing account argument exited $QRC, not 2"
# The account name becomes a path segment under state/quota/cooldown/, so a
# traversal is refused as a NAME before anything is removed.
qs --clear-cooldown codex '../claude/c' >/dev/null
[ "$QRC" = 2 ] && ok || bad "G: a traversing account name exited $QRC, not 2"
qs --clear-cooldown codex '..' >/dev/null
[ "$QRC" = 2 ] && ok || bad "G: '..' as an account name exited $QRC, not 2"
[ -f "$T/state/quota/cooldown/claude/c" ] \
  && ok || bad "G: the lever removed a cooldown it was not asked about"

# The vendor list quota-status.sh walks is the picker's own; a name in it the
# picker cannot answer for would render a cooldown nobody can ever write.
for V in $(env HARNESS="$T" bash -c '. "$1"; printf "%s" "$ACCOUNT_VENDORS"' _ "$PICK"); do
  env HARNESS="$T" bash -c '. "$1"; _acct_vendor_vars "$2" >/dev/null' _ "$PICK" "$V" \
    || bad "F: ACCOUNT_VENDORS names '$V', which _acct_vendor_vars does not know"
done
ok

# =============================================================================
# H. EXPIRY, ON THE SCOPED PATH
# =============================================================================
accounts_abd; clear_cool; clear_logs
stamp claude b $(( 2 * WINDOW ))
[ "$(pname -- eval claude claude-fable-5-1)" = b ] \
  && ok || bad "H: an EXPIRED scoped cooldown still excluded b"
stamp claude b 5
[ "$(pname -- eval claude claude-fable-5-1)" = a ] \
  && ok || bad "H: a 5s-old scoped stamp did not exclude b"
[ "$(pname ACCOUNT_COOLDOWN_SECS=1 -- eval claude claude-fable-5-1)" = b ] \
  && ok || bad "H: ACCOUNT_COOLDOWN_SECS=1 did not shorten the window on the scoped path"

echo "account-cooldown-vendor.bh-940-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
