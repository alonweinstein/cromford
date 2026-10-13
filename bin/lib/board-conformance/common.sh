# shellcheck shell=bash
# bin/lib/board-conformance/common.sh — the helpers every board-conformance
# probe lib uses (BH-3947). Sourced, never executed: functions only, no `set`,
# no output on source, no path built from a harness root.
#
#   bc_get <url> <outfile> [token]  -> prints the HTTP code (000 when curl got
#       none). GET only: never -X, -d or --data. The token goes into the
#       Authorization header and nowhere else. Timeout: BC_TIMEOUT_S (20).
#   bc_class <code>                 -> 2xx | 404 | 000 | 5xx | other
#   bc_item <name> <status> <note>  -> one {name,status,note} JSON line appended
#       to $BC_ITEMS. status is ok|missing|malformed|unverified; anything else,
#       an empty name or no $BC_ITEMS is rc 2 and appends nothing.

bc_get() {
  local url="$1" out="$2" tok="${3:-}" code
  local -a args=(-s -m "${BC_TIMEOUT_S:-20}" -o "$out" -w '%{http_code}' -H 'User-Agent: curl/8')
  [ -n "$tok" ] && args+=(-H "Authorization: Bearer $tok")
  code=$(curl "${args[@]}" "$url" 2>/dev/null) || true
  case "$code" in [0-9][0-9][0-9]) ;; *) code=000 ;; esac
  printf '%s\n' "$code"
}

bc_class() {
  case "${1:-}" in
    2[0-9][0-9]) echo 2xx ;;
    404) echo 404 ;;
    ''|000) echo 000 ;;
    5[0-9][0-9]) echo 5xx ;;
    *) echo other ;;
  esac
}

bc_item() {
  [ -n "${BC_ITEMS:-}" ] && [ -n "${1:-}" ] || return 2
  case "${2:-}" in ok|missing|malformed|unverified) ;; *) return 2 ;; esac
  jq -cn --arg n "$1" --arg s "$2" --arg t "${3:-}" '{name:$n,status:$s,note:$t}' >> "$BC_ITEMS"
}
