#!/bin/bash
# gh-identity: app-token
# bin/lib/served-sha-watch.d/10-alert.sh - the served-sha watch's alert hook
# (BH-4937, #4916 child 2). Sourced by bin/served-sha-watch.sh's hook loop,
# never executed.
#
# WHY. project-3 #467 merged, Vercel never built it, and prod served a ~5h old
# build. The tracer (BH-4936) judges that; this hook is the part that tells a
# human.
#
# WHAT. ssw_hook_alert reads the driver's verdict:
#   alert    record served-behind:<p>:<head12> in the state file's open_ids
#            FIRST, then page it through bin/lane-alert.sh --severity critical.
#            It pages on every alert tick on purpose: lane-alert's per-id state
#            machine dedupes repeats and owns the reminder cadence.
#   in-sync  one lane-alert --resolve per open served-behind:* id. The driver
#            deletes the state file after the hooks.
#   anything else (wait, unreadable) does nothing.
# Commits behind come from this hook's own GitHub compare read; a failed read
# says `?`, never 0. A failed state write still pages and returns 1 (the driver
# logs it). The alert path is lane-alert only: no direct log write here.

ssw_hook_alert() {
  local p="${1:-}" verdict="${2:-}" head="${3:-}" served="${4:-}" dep="${5:-}" age_s="${6:-}" sf="${7:-}"
  case "$verdict" in
    alert)   _ssw_alert_open "$p" "$head" "$served" "$dep" "$age_s" "$sf" ;;
    in-sync) _ssw_alert_resolve "$p" "$head" "$served" "$sf" ;;
    *) return 0 ;;
  esac
}

_ssw_alert_dep_word() {
  case "${1:-}" in
    none) echo none ;;
    building) echo building ;;
    ready) echo ready-not-promoted ;;
    failed) echo failed:ERROR ;;
    *) echo unread ;;
  esac
}

# _ssw_alert_ahead <served> <head> - GitHub's ahead_by, or ? when unreadable.
_ssw_alert_ahead() {
  local served="$1" head="$2" tmp k=""
  if [ -n "${SSW_SLUG:-}" ] && command -v gh_rest >/dev/null 2>&1 && ! ssw_same_sha "$head" "$served"; then
    tmp=$(mktemp "${TMPDIR:-/tmp}/ssw-alert.XXXXXX") || { echo '?'; return 0; }
    gh_rest GET "repos/$SSW_SLUG/compare/$served...$head" > "$tmp" 2>/dev/null \
      && k=$(jq -r '.ahead_by | numbers' "$tmp" 2>/dev/null)
    rm -f "$tmp"
  fi
  [[ $k =~ ^[0-9]+$ ]] && echo "$k" || echo '?'
}

_ssw_alert_open() {
  local p="$1" head="$2" served="$3" dep="$4" age_s="$5" sf="$6" id k mins st js rc=0
  id="served-behind:$p:${head:0:12}"
  k=$(_ssw_alert_ahead "$served" "$head")
  if [[ $age_s =~ ^[0-9]+$ ]]; then mins="$((age_s / 60))m"; else mins='?m'; fi
  st=$(ssw_state_read "$sf") || st='{}'
  js=$(jq -c --arg id "$id" '.open_ids = (((.open_ids // []) | map(strings)) + [$id] | unique)' <<< "$st" 2>/dev/null) \
    && ssw_state_write "$sf" "$js" || rc=1
  "$H/bin/lane-alert.sh" --severity critical --id "$id" served-sha-watch \
    "$p: prod serves ${served:0:8}, main is ${head:0:8} (merged $mins ago, $k commits behind, deployment for ${head:0:8}: $(_ssw_alert_dep_word "$dep"))" \
    >/dev/null 2>&1 < /dev/null
  return "$rc"
}

_ssw_alert_resolve() {
  local p="$1" head="$2" served="$3" sf="$4" st id
  st=$(ssw_state_read "$sf") || return 0
  while IFS= read -r id; do
    case "$id" in served-behind:*) ;; *) continue ;; esac
    "$H/bin/lane-alert.sh" --resolve --id "$id" served-sha-watch \
      "$p: prod serves ${served:0:8}, main is ${head:0:8}, back in sync" >/dev/null 2>&1 < /dev/null
  done < <(jq -r '(.open_ids // [])[] | strings' <<< "$st" 2>/dev/null)
  return 0
}
