#!/bin/bash
# alert-writer: by-design — the CRITICAL paging path: the first ALERTS write is the record of truth made before the strict critical beat, the other two are the only copy when that beat (and the direct DM) failed; alert-line's own strict beat (30 s timeout) in front of a page, or after a beat that just failed, would delay or duplicate the page
# bin/lib/page-critical.sh — the deterministic CRITICAL page. Sourced, never run.
#
#   page_critical <dedupe-ttl-s> <key> <line> [project]
#
# WHY A SECOND PAGE PATH (K1 containment, 2026-09-24). Every alert a lane raises
# with alert()/beat.sh is an UNTRIAGED fleet_alert: it is quarantined on the box,
# collected by the hub's alert-triage lane (an LLM) and only reaches the operator after
# that lane decides it should, or after alert-flush's 45-minute safety valve.
# That is the right path for "something looks odd". It is the wrong path for
# the money breakers: a project the harness just PAUSED for spending with zero
# merges, the fleet crossing its daily hard ceiling, a runner whose calls the
# ledger cannot price. Those must reach a human on a path with no model in it,
# and within one tick.
#
# So this does three deterministic things, in this order, and nothing else:
#
#   1. dedupe on <key> against state/page-critical.json (the pipeline-health
#      alert() contract: at most one page per key per <ttl>). The stamp is
#      written BEFORE the send, so the failure shape is a lost repeat, never a
#      storm.
#   2. one ALERTS.log line, "CRITICAL [<lane>] <line>", the record of truth.
#   3. a `"triaged":true` fleet_alert beat with severity critical — triaged is
#      what makes bin/beat.sh post it straight to the console and Telegram
#      instead of quarantining it for the LLM triage lane — sent BEAT_STRICT so
#      the delivery is KNOWN. A beat the console did not take (rc != 0) falls
#      through to a direct Telegram DM with TELEGRAM_BOT_TOKEN, the same bot
#      and chat bin/lane-alert.sh --critical uses when the monitor is off.
#
# Never fails the caller. Knobs: PAGE_LANE (label, default pipeline-health),
# LANE_ALERT_DM_CHAT (the DM chat, default the operator's, shared with lane-alert.sh).
# Tests: tests/page-critical.k1-test.sh.

page_critical() {
  local ttl="${1:-86400}" key="${2:-}" line="${3:-}" proj="${4:-fleet}"
  local h="${HARNESS:-/root/harness}" now last st lane tok chat msg chunk rc
  [ -n "$key" ] && [ -n "$line" ] || return 0
  lane="${PAGE_LANE:-pipeline-health}"
  now="${NOW:-$(date +%s)}"
  mkdir -p "$h/state" "$h/logs" 2>/dev/null
  st="$h/state/page-critical.json"
  # ONE read-modify-write under a flock: pipeline-health and ci-minutes-watch
  # share this file, and two unlocked writers each drop the other's key. A file
  # that does not parse (a torn write, a full disk) reads as {} and is replaced:
  # a corrupt dedupe file must cost at most a repeat page, never a lost one.
  # rc 1 from the subshell = suppressed by the TTL.
  (
    command -v flock >/dev/null 2>&1 && flock -w 10 9
    cur=$(jq -c 'if type == "object" then . else {} end' "$st" 2>/dev/null) || cur='{}'
    [ -n "$cur" ] || cur='{}'
    last=$(jq -r --arg k "$key" '.[$k] // 0' <<<"$cur" 2>/dev/null) || last=0
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    [ $(( now - last )) -lt "$ttl" ] && exit 1
    jq --arg k "$key" --argjson t "$now" '.[$k]=$t' <<<"$cur" > "$st.tmp.$$" 2>/dev/null \
      && mv "$st.tmp.$$" "$st" 2>/dev/null
    rm -f "$st.tmp.$$" 2>/dev/null
    exit 0
  ) 9>"$st.lock" || return 0
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') CRITICAL [$lane] $key — $line" >> "$h/logs/ALERTS.log"
  rc=1
  if [ -x "$h/bin/beat.sh" ]; then
    BEAT_STRICT=1 "$h/bin/beat.sh" "$(jq -nc --arg p "$proj" --arg akey "critical:$key" \
      --arg id "$key" --arg l "CRITICAL [$lane] $line" \
      '{kind:"fleet_alert",project:$p,triaged:true,severity:"critical",akey:$akey,alertid:$id,line:$l}')" \
      >/dev/null 2>&1
    rc=$?
  fi
  [ "$rc" = 0 ] && return 0
  # The console did not take it (or this box has none): DM directly.
  tok="${TELEGRAM_BOT_TOKEN:-}"
  if [ -z "$tok" ]; then
    local envd="${HENV:-$h/env}"
    tok=$(sed -n 's/^\(export \)\{0,1\}TELEGRAM_BOT_TOKEN=//p' "$envd/global.env" 2>/dev/null | tr -d "\"'" | head -n 1)
  fi
  chat="${LANE_ALERT_DM_CHAT:-100000000}"
  if [ -z "$tok" ]; then
    echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') CRITICAL [$lane] $key — the console beat failed (rc $rc) and TELEGRAM_BOT_TOKEN is not set: this ALERTS line is the only copy" >> "$h/logs/ALERTS.log"
    return 0
  fi
  msg="CRITICAL [$lane] $line"$'\n'"(console beat failed rc $rc; DM sent directly by page_critical)"
  while [ -n "$msg" ]; do
    chunk="${msg:0:3800}"; msg="${msg:3800}"
    # The token rides curl's STDIN config (-K -), never its argv, where any
    # `ps` on the box would print it.
    printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$tok" | \
    curl -s --max-time 20 -K - \
      --data-urlencode "chat_id=$chat" --data-urlencode "text=$chunk" \
      --data-urlencode "disable_web_page_preview=true" >/dev/null 2>&1 || \
      echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') CRITICAL [$lane] $key — the direct DM FAILED too (curl); this ALERTS line is the only copy" >> "$h/logs/ALERTS.log"
  done
  return 0
}
