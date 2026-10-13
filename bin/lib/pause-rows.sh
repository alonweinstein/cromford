#!/bin/bash
# bin/lib/pause-rows.sh — the DISPLAY fields of the live pauses (BH-1684).
#
# bin/lib/pause.sh answers "is this paused?" and nothing else. The autopilot's
# TICK line and the alert digest also need the reason, the actor and the age,
# and two lanes each reading the cache their own way is how two readers come to
# disagree. So this is the one place those fields are read, and every row it
# prints is first re-confirmed with pause_active: pause.sh stays the only judge
# of "active", this file only adds columns to rows it already accepts.
#
# Sourced, never executed, AFTER bin/lib/pause.sh (it uses __pause_cache and
# pause_active from there and sources nothing itself). Entry points:
#   pause_rows [project]  one TSV line per live row:
#                           scope what reason actor created_epoch expires_epoch
#                         Every field is non-empty (a missing reason or actor
#                         prints "-"), so a caller's `IFS=$'\t' read` cannot
#                         collapse two tabs and shift the columns after them.
#                         With a project, only rows scoped fleet or that project.
#                         An unreadable cache prints nothing (= not paused).
#   pause_why <project> <what>
#                         "reason=<reason> age=<dur>" for the live <what> row that
#                         covers <project> (fleet or its own; the latest expiry
#                         wins when both are live). Nothing when none is.
#   pause_dur <secs>      "2d 3h", "3h 5m", "21h" or "45m"; anything below a minute,
#                         negative or non-numeric is "0m".

pause_rows() {
  local p="${1:-}" scope what reason actor c e
  # \x1f, not a tab, between the fields: a tab is IFS whitespace, so an empty
  # reason would collapse into its neighbour and shift every column after it.
  while IFS=$'\x1f' read -r scope what reason actor c e; do
    [ -n "$scope" ] && [ -n "$what" ] || continue
    pause_active "$scope" "$what" || continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$scope" "$what" "$reason" "$actor" "$c" "$e"
  done < <(jq -r --arg p "$p" --argjson now "${PAUSE_NOW:-$(date -u +%s)}" '
      def ep: try (sub("\\.[0-9]+"; "") | fromdateiso8601) catch 0;
      def clean: tostring | gsub("[\t\r\n\u001f]"; " ") | if . == "" then "-" else . end;
      .pauses[]
      | select(($p == "") or .scope == "fleet" or .scope == $p)
      | select(.ended_at == null)
      | select((.expires_at | ep) > $now)
      | [(.scope|clean), (.what|clean), ((.reason // "")|clean), ((.actor // "")|clean),
         ((.created_at // "") | ep | floor | tostring), (.expires_at | ep | floor | tostring)]
      | join("\u001f")' "$(__pause_cache)" 2>/dev/null)
  return 0
}

pause_why() {
  local w="${2:-}" c r age=0
  IFS=$'\t' read -r c r < <(pause_rows "${1:-}" \
    | awk -F'\t' -v w="$w" '$2 == w && $6 + 0 >= e + 0 { e = $6; o = $5 "\t" $3 } END { if (o != "") print o }')
  [ -n "${r:-}" ] || return 0
  # created_epoch is 0 when created_at does not parse: that age is unknown and
  # reads 0m, never "20000d".
  case "${c:-}" in ''|0|*[!0-9]*) ;; *) age=$(( ${PAUSE_NOW:-$(date -u +%s)} - c )) ;; esac
  printf 'reason=%s age=%s' "$r" "$(pause_dur "$age")"
}

pause_dur() {
  local s="${1:-0}" d h m
  case "$s" in ''|*[!0-9]*) s=0 ;; esac
  d=$((s / 86400)); h=$((s % 86400 / 3600)); m=$((s % 3600 / 60))
  # A zero second unit is dropped: "21h", not "21h 0m".
  if [ "$d" -gt 0 ]; then printf '%dd' "$d"; [ "$h" -gt 0 ] && printf ' %dh' "$h"
  elif [ "$h" -gt 0 ]; then printf '%dh' "$h"; [ "$m" -gt 0 ] && printf ' %dm' "$m"
  else printf '%dm' "$m"; fi
  return 0
}
