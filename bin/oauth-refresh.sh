#!/usr/bin/env bash
# oauth-refresh.sh [CONFIG_DIR] [ACCOUNT] — keep a Claude FULL-LOGIN credentials.json alive.
#
# WHY (2026-09-07, hub usage meter down again): a full login's accessToken lives
# ~8 hours. The Claude CLI refreshes it whenever a session runs ON that login —
# but every harness lane on a box authenticates with the CLAUDE_CODE_OAUTH_TOKEN
# setup-token from global.env, so nothing ever runs on the file and it silently
# expires. The usage endpoint then answers 401 to the file and 429 to the
# setup-token (permanently — see extra-usage-track.sh's header), and the meter
# goes blind until a human runs a claude session by hand. That happened
# 2026-08-31..09-06 and again 09-06T23:26Z; the "429 for every credential" alert
# was really "the one credential that works has expired".
#
# HOW (BH-2561): nothing runs unless the token is expired or within
# OAUTH_REFRESH_MARGIN_S of expiry (default 15 min), so a healthy file costs
# nothing. Then, in order:
#   1. DIRECT: POST $(endpoint_url anthropic-oauth)/v1/oauth/token with
#      grant_type=refresh_token, the file's refreshToken and
#      OAUTH_REFRESH_CLIENT_ID. The body goes through a file in a 0700 temp dir
#      (curl --data @file), so the token is never in argv. A 200 with an
#      access_token and a future expiry rewrites accessToken/refreshToken/
#      expiresAt (every other field kept) through tmp + chmod 600 + mv, and the
#      script exits 0 with no model call. This path is INERT while
#      OAUTH_REFRESH_CLIENT_ID is empty, which is its registry default
#      (catalog/lanes.d/_lib.oauth-refresh.json). Any other outcome (non-200,
#      bad JSON, no expiry, curl or endpoint_url failure) logs the HTTP code
#      and falls through.
#   2. CLI FALLBACK: when this was written the token endpoint refused direct
#      calls (Cloudflare 1010 for a generic client, 404 with the CLI's user
#      agent), which is why this path stays. ONE tiny headless call through
#      agent-call.sh (so it writes a cost row) on the model of model_routes
#      role auth.fallback, lane oauth-refresh, runner claude, with the env
#      setup-token removed and CLAUDE_CONFIG_DIR pointed at the login, so the
#      CLI refreshes and rewrites the file itself. No route = one log line, no
#      call, exit 1. Claimed once per credential per UTC day (BH-3222): before
#      the call, cred_inference_claim oauth-refresh login:<12hex> (the
#      auth-fingerprint of the file's CONTENT, the cost row's auth_fp) writes a
#      `claimed` row to the canary-inference ledger, and a second tick that day
#      logs "already attempted today" and exits 1 without calling. A refresh
#      that works rewrites the file, so the next expiry is a new fp and a new
#      claim; a dead login's file never changes, so it costs one call a day,
#      not 96. Store unreachable = no call. The call runs with
#      AGENT_CALL_DEAD_ALERT=0, so agent-call never pages DEAD for it; this
#      script pages instead, once (lane-alert --id oauth-refresh-<dir hash>,
#      warn), and only when an enabled claude account in accounts.d routes to
#      this dir. An unrouted login gets a log line, never a page. The alert is
#      resolved the next time the dir is fresh or refreshed.
#
# Exit: 0 token fresh (or refreshed), 1 refresh attempted and failed,
#       2 no credentials.json here (nothing to refresh — the setup-token case).
#
# ACCOUNT (BH-2646) is the login's label. When given, exit 0 reports oauth ok
# with the file's expiry and exit 1 reports oauth fail with the tail reason,
# through bin/lib/token-health.sh (fail-open, never changes the exit code).
# Exit 2 and an empty ACCOUNT report nothing.
set -u
H="${HARNESS:-/root/harness}"
CDIR="${1:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}"
ACCOUNT="${2:-}"
F="$CDIR/.credentials.json"
MARGIN="${OAUTH_REFRESH_MARGIN_S:-900}"
OAUTH_REFRESH_CLIENT_ID="${OAUTH_REFRESH_CLIENT_ID:-}"
LOG="$H/logs/agent-rules.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
{ [ -r "$(dirname "$0")/lib/token-health.sh" ] && . "$(dirname "$0")/lib/token-health.sh"; } || token_health_report() { :; }
_th() { [ -n "$ACCOUNT" ] && token_health_report oauth "$ACCOUNT" "$@" >/dev/null 2>&1; return 0; }
_iso() { [ "${1:-0}" -gt 0 ] 2>/dev/null && date -u -d "@$(( $1 / 1000 ))" +%FT%TZ 2>/dev/null; }
[ -r "$F" ] || exit 2
# One alert id per login dir (BH-3222); the marker says this script fired it,
# so a healthy dir's every tick does not call lane-alert just to resolve nothing.
AID="oauth-refresh-$(realpath -m "$CDIR" | sha256sum | cut -c1-12)"
AMARK="$H/state/oauth-refresh/$AID.alerted"
_resolve() {
  [ -e "$AMARK" ] || return 0
  "$(dirname "$0")/lane-alert.sh" --resolve --id "$AID" oauth-refresh "$CDIR refreshed" >/dev/null 2>&1 || true
  rm -f "$AMARK"
}
exp=$(jq -r '.claudeAiOauth.expiresAt // 0' "$F" 2>/dev/null); case "$exp" in ''|*[!0-9]*) exp=0 ;; esac
now_ms=$(( $(date -u +%s) * 1000 ))
[ "$exp" -gt $(( now_ms + MARGIN * 1000 )) ] && { _th ok "$(_iso "$exp")"; _resolve; exit 0; }
LIB="$(cd "$(dirname "$0")" && pwd)/lib"
d=$(mktemp -d) || exit 1
chmod 700 "$d"
trap 'rm -rf "$d"' EXIT

# 1. Direct refresh — only with a client id, a refresh token and a resolvable URL.
if [ -n "$OAUTH_REFRESH_CLIENT_ID" ]; then
  code=skipped
  # shellcheck source=/dev/null
  if [ -r "$LIB/endpoints.sh" ] && . "$LIB/endpoints.sh" 2>/dev/null \
     && url=$(endpoint_url anthropic-oauth 2>/dev/null) && [ -n "$url" ] \
     && jq -e --arg c "$OAUTH_REFRESH_CLIENT_ID" '.claudeAiOauth.refreshToken // "" | select(. != "")
          | {grant_type:"refresh_token", refresh_token:., client_id:$c}' "$F" > "$d/body" 2>/dev/null; then
    code=$(curl -sS -m 30 -o "$d/resp" -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
           --data "@$d/body" "${url%/}/v1/oauth/token" 2>/dev/null) || code="curl-rc$?:${code:-000}"
    rm -f "$d/body"
    if [ "$code" = 200 ]; then
      exp2=$(jq -r --argjson now "$now_ms" '
        if (.access_token | type) == "string" and .access_token != "" then
          if (.expiresAt | type) == "number" then .expiresAt | floor
          elif (.expires_in | type) == "number" and .expires_in > 0 then $now + (.expires_in * 1000 | floor)
          else empty end
        else empty end' "$d/resp" 2>/dev/null)
      case "$exp2" in ''|*[!0-9]*) exp2=0 ;; esac
      if [ "$exp2" -gt "$now_ms" ]; then
        tmp=$(mktemp "$CDIR/.credentials.json.XXXXXX") || tmp=""
        if [ -n "$tmp" ] && jq --slurpfile r "$d/resp" --argjson e "$exp2" '
             .claudeAiOauth.accessToken = $r[0].access_token
             | .claudeAiOauth.expiresAt = $e
             | if (($r[0].refresh_token // "") | type) == "string" and ($r[0].refresh_token // "") != ""
               then .claudeAiOauth.refreshToken = $r[0].refresh_token else . end' "$F" > "$tmp" 2>/dev/null \
           && chmod 600 "$tmp" && mv -f "$tmp" "$F"; then
          echo "$(STAMP) oauth-refresh: $F refreshed directly (was $(_iso "$exp"), now expires $(_iso "$exp2"))" >> "$LOG" 2>/dev/null
          _th ok "$(_iso "$exp2")"
          _resolve
          exit 0
        fi
        [ -n "$tmp" ] && rm -f "$tmp"
        code="200-write-failed"
      else
        code="200-no-expiry"
      fi
    fi
  fi
  echo "$(STAMP) oauth-refresh: direct refresh of $F failed (http=$code); falling back to the CLI" >> "$LOG" 2>/dev/null
fi

# 2. CLI fallback through agent-call on role auth.fallback.
M=""
# shellcheck source=/dev/null
[ -r "$LIB/lane-model.sh" ] && . "$LIB/lane-model.sh" 2>/dev/null && M=$(lane_role_model auth.fallback 2>/dev/null)
if [ -z "$M" ]; then
  echo "$(STAMP) oauth-refresh: $F expiring and no model_routes route for role auth.fallback; no CLI refresh attempted" >> "$LOG" 2>/dev/null
  _th fail "" "no model_routes route for role auth.fallback"
  exit 1
fi
# BH-3222: one CLI attempt per credential per UTC day. A box mid-sync with no
# contract lib behaves as the contract's own stub does (claim 0): as before.
# shellcheck source=bin/lib/cred-probe.sh
if ! . "${CRED_PROBE_LIB:-$LIB/cred-probe.sh}" 2>/dev/null || ! command -v cred_inference_claim >/dev/null 2>&1; then
  cred_inference_claim() { return 0; }
  cred_inference_record() { return 0; }
fi
# The credential's fingerprint: the same login:<12hex> the cost row carries.
FP=$(unset CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY
     . "$(dirname "$0")/auth-fingerprint.sh" 2>/dev/null && CLAUDE_CONFIG_DIR="$CDIR" auth_fp_for_runner claude 2>/dev/null)
case "$FP" in login:?*) ;; *) FP="" ;; esac
# _routed: 1 when an enabled claude account routes to this dir (or the registry
# cannot be read: a missed page on a real account is worse than one extra warn).
_routed() {
  ( . "$(dirname "$0")/account-pick.sh" >/dev/null 2>&1 || { echo 1; exit 0; }
    accounts_load >/dev/null 2>&1
    want=$(realpath -m "$CDIR")
    for a in "${ACCOUNT_NAMES[@]}"; do
      [ "${ACCT_VENDOR[$a]}" = claude ] && [ "${ACCT_ENABLED[$a]}" = 1 ] || continue
      c=$(account_cred_get "$a" CLAUDE_CONFIG_DIR 2>/dev/null) || continue
      [ "$(realpath -m "$c")" = "$want" ] && { echo 1; exit 0; }
    done
    echo 0 )
}
cred_inference_claim oauth-refresh "$FP"; crc=$?
if [ "$crc" = 1 ]; then
  echo "$(STAMP) oauth-refresh: $F CLI refresh already attempted today for $FP (routed=$(_routed)); not calling again until tomorrow UTC" >> "$LOG" 2>/dev/null
  _th fail "" "CLI refresh already attempted today"
  exit 1
elif [ "$crc" != 0 ]; then
  echo "$(STAMP) oauth-refresh: $F expiring and the canary-inference store unreachable or no fp; no CLI refresh attempted" >> "$LOG" 2>/dev/null
  _th fail "" "canary-inference store unreachable or no fp"
  exit 1
fi
# cd / so no repo CLAUDE.md rides along; stdin closed so the CLI does not wait
# on it; never echo the CLI output (it is model text). ACCOUNT_ROUTING=0 keeps
# the call on THIS login, not another account's credentials.
# AGENT_CALL_DEAD_ALERT=0: this script owns the page for its own call (below).
# llm-site: oauth-refresh
(cd / && env -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY ACCOUNT_ROUTING=0 AGENT_CALL_RUNNERS=claude AGENT_CALL_LANE=oauth-refresh \
  AGENT_CALL_DEAD_ALERT=0 CLAUDE_CONFIG_DIR="$CDIR" "$H/bin/agent-call.sh" canary fleet "$M" "${OAUTH_REFRESH_TIMEOUT_S:-120}" "$d/out" 'reply ok' </dev/null >/dev/null 2>&1); rc=$?
exp2=$(jq -r '.claudeAiOauth.expiresAt // 0' "$F" 2>/dev/null); case "$exp2" in ''|*[!0-9]*) exp2=0 ;; esac
if [ "$exp2" -gt "$exp" ] && [ "$exp2" -gt "$now_ms" ]; then
  cred_inference_record oauth-refresh "$FP" ok >/dev/null 2>&1 || true
  echo "$(STAMP) oauth-refresh: $F refreshed by the CLI (was $(_iso "$exp"), now expires $(_iso "$exp2"))" >> "$LOG" 2>/dev/null
  _th ok "$(_iso "$exp2")"
  _resolve
  exit 0
fi
# A refusal (74..79) bought nothing, so there is nothing to record; the claimed
# row still blocks a second try today (same as lane-probe).
{ [ "$rc" -ge 74 ] && [ "$rc" -le 79 ]; } || cred_inference_record oauth-refresh "$FP" down >/dev/null 2>&1 || true
tail_out=$(tail -c 160 "$d/out" 2>/dev/null | tr '\n' ' ')
echo "$(STAMP) oauth-refresh: $F still expired after a CLI refresh attempt (rc=$rc, $FP): $tail_out" >> "$LOG" 2>/dev/null
_th fail "" "still expired after CLI refresh (rc=$rc): $tail_out"
if [ "$(_routed)" = 1 ]; then
  msg="$CDIR (${ACCOUNT:-no label}, $FP) is a routed login and its token could not be refreshed; re-auth it with CLAUDE_CONFIG_DIR=$CDIR claude /login"
  if [ -x "$(dirname "$0")/lane-alert.sh" ]; then
    "$(dirname "$0")/lane-alert.sh" --id "$AID" --severity warn oauth-refresh "$msg" >/dev/null 2>&1 || true
  else
    "$(dirname "$0")/alert-line.sh" --severity warn --id "$AID" "[oauth-refresh] $msg" >/dev/null 2>&1 || true
  fi
  mkdir -p "${AMARK%/*}" 2>/dev/null && : > "$AMARK" 2>/dev/null
else
  echo "$(STAMP) oauth-refresh: $F ($FP) not routed by any account; no page" >> "$LOG" 2>/dev/null
fi
exit 1
