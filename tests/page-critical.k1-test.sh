#!/bin/bash
# tests/page-critical.k1-test.sh — bin/lib/page-critical.sh, the deterministic
# CRITICAL page the K1 money breakers use instead of the LLM-triaged alert path.
#
# WHAT IT PINS:
#   1  one ALERTS.log line, and a `"triaged":true` severity-critical fleet_alert
#      beat sent BEAT_STRICT — triaged is what keeps it out of the quarantine
#      the alert-triage LLM lane reads.
#   2  dedupe: the same key inside its TTL sends nothing; a different key does.
#   3  a beat the console did not take falls through to a direct Telegram DM.
#   4  no console AND no bot token: the ALERTS line says it is the only copy.
#   5  no key or no line: nothing at all.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=$(date +%s)
mkdir -p "$T/h/bin" "$T/h/logs" "$T/h/env" "$T/stub"
cat > "$T/h/bin/beat.sh" <<'SH'
#!/bin/bash
printf '%s\t%s\n' "${BEAT_STRICT:-}" "$1" >> "$HARNESS/beats.txt"
exit "${BEAT_RC:-0}"
SH
chmod +x "$T/h/bin/beat.sh"
# The fake curl keeps what a `ps` would show (argv) apart from what only curl
# reads (its stdin config), so the token's hiding place is testable.
cat > "$T/stub/curl" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$HARNESS/curl.txt"
[ -t 0 ] || cat >> "$HARNESS/curl-stdin.txt"
SH
chmod +x "$T/stub/curl"

run() { # run <env assignments...> -- <page_critical args...>
  local envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  ( export HARNESS="$T/h" NOW="$NOW" PATH="$T/stub:$PATH" "${envs[@]}"
    unset TELEGRAM_BOT_TOKEN_UNSET
    # shellcheck source=/dev/null
    . "$DIR/bin/lib/page-critical.sh" || exit 1
    page_critical "$@" )
}
reset() { rm -f "$T/h/beats.txt" "$T/h/curl.txt" "$T/h/curl-stdin.txt" "$T/h/logs/ALERTS.log" "$T/h/state/page-critical.json"; }

# 1. the happy path: one line, one triaged critical beat, no DM
reset
run TELEGRAM_BOT_TOKEN=tok -- 86400 "costzeromerge:zm" "zm spent \$200 with 0 merged" zm
[ "$(grep -c 'CRITICAL \[pipeline-health\] costzeromerge:zm' "$T/h/logs/ALERTS.log" 2>/dev/null)" = 1 ] && ok \
  || bad "1: exactly one CRITICAL ALERTS line ($(cat "$T/h/logs/ALERTS.log" 2>/dev/null))"
B=$(cut -f2 "$T/h/beats.txt" 2>/dev/null)
[ "$(cut -f1 "$T/h/beats.txt" 2>/dev/null)" = 1 ] && ok || bad "1: the beat must be sent BEAT_STRICT=1"
[ "$(jq -r '.triaged' <<<"$B")" = true ] && [ "$(jq -r '.severity' <<<"$B")" = critical ] \
  && [ "$(jq -r '.kind' <<<"$B")" = fleet_alert ] && [ "$(jq -r '.project' <<<"$B")" = zm ] \
  && [ "$(jq -r '.alertid' <<<"$B")" = "costzeromerge:zm" ] && ok \
  || bad "1: the beat must be a triaged, critical fleet_alert for the project: $B"
[ ! -e "$T/h/curl.txt" ] && ok || bad "1: a delivered beat must not also DM"

# 2. dedupe on the key, not on the text
run TELEGRAM_BOT_TOKEN=tok -- 86400 "costzeromerge:zm" "zm spent \$210 with 0 merged" zm
[ "$(wc -l < "$T/h/beats.txt")" = 1 ] && [ "$(grep -c CRITICAL "$T/h/logs/ALERTS.log")" = 1 ] && ok \
  || bad "2: the same key inside its TTL must send nothing"
run TELEGRAM_BOT_TOKEN=tok -- 86400 "costzeromerge:zm7" "zm7 spent" zm7
[ "$(wc -l < "$T/h/beats.txt")" = 2 ] && ok || bad "2: a different key pages"
run TELEGRAM_BOT_TOKEN=tok NOW=$(( NOW + 86400 )) -- 86400 "costzeromerge:zm" "again" zm
[ "$(wc -l < "$T/h/beats.txt")" = 3 ] && ok || bad "2: past its TTL the key pages again"

# 3. console refused: a direct DM, with the token and the operator's chat
reset
run TELEGRAM_BOT_TOKEN=tok123 BEAT_RC=1 -- 600 "costceiling:fleet" "fleet over the ceiling"
grep -q 'api.telegram.org/bottok123/sendMessage' "$T/h/curl-stdin.txt" 2>/dev/null \
  && grep -q 'chat_id=100000000' "$T/h/curl.txt" && grep -q 'text=CRITICAL \[pipeline-health\] fleet over the ceiling' "$T/h/curl.txt" \
  && ok || bad "3: a failed beat must DM directly (argv: $(cat "$T/h/curl.txt" 2>/dev/null); stdin: $(cat "$T/h/curl-stdin.txt" 2>/dev/null))"
grep -q 'tok123' "$T/h/curl.txt" 2>/dev/null \
  && bad "3: the bot token must never be on curl's argv (visible to ps): $(cat "$T/h/curl.txt")" || ok
# the token can come from env/global.env, like lane-alert.sh reads it
reset
printf 'TELEGRAM_BOT_TOKEN="filetok"\n' > "$T/h/env/global.env"
run BEAT_RC=2 HENV="$T/h/env" -- 600 "costceiling:fleet" "x"
grep -q 'bot''filetok/' "$T/h/curl-stdin.txt" 2>/dev/null && ok || bad "3: the token must be read from env/global.env when not in the environment"
rm -f "$T/h/env/global.env"

# 3b. a corrupt dedupe file is not a reason to stay silent, and is repaired
reset; mkdir -p "$T/h/state"
printf '{"half": ' > "$T/h/state/page-critical.json"
run -- 600 "k:corrupt" "after a torn write"
[ "$(wc -l < "$T/h/beats.txt" 2>/dev/null | tr -d ' ')" = 1 ] && jq -e '.["k:corrupt"]' "$T/h/state/page-critical.json" >/dev/null 2>&1 \
  && ok || bad "3b: a corrupt state file must still page and be rewritten as valid JSON ($(cat "$T/h/state/page-critical.json"))"
# 3c. two writers (pipeline-health and ci-minutes-watch share the file) keep both keys
reset
( run -- 600 "k:one" "one" ) & ( run -- 600 "k:two" "two" ) & wait
jq -e '.["k:one"] and .["k:two"]' "$T/h/state/page-critical.json" >/dev/null 2>&1 && ok \
  || bad "3c: concurrent writers must not lose a key ($(cat "$T/h/state/page-critical.json"))"
[ -e "$T/h/state/page-critical.json.lock" ] && ok || bad "3c: the read-modify-write must hold a flock on page-critical.json.lock"

# 4. nothing to send it with
reset
run BEAT_RC=1 HENV="$T/h/env" TELEGRAM_BOT_TOKEN= -- 600 "costunpriced:grok" "grok unpriced"
grep -q 'only copy' "$T/h/logs/ALERTS.log" && [ ! -e "$T/h/curl.txt" ] && ok \
  || bad "4: with no console and no token the ALERTS line must say it is the only copy"

# 5. nothing to page
reset
run -- 600 "" "a line with no key"
run -- 600 "k" ""
[ ! -e "$T/h/beats.txt" ] && [ ! -e "$T/h/logs/ALERTS.log" ] && ok || bad "5: no key or no line must do nothing"

echo "page-critical.k1-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
