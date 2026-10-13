# shellcheck shell=bash
# bin/lib/board-conformance/writes.sh — the write-route check (BH-3947, BH-3960).
# Sourced, never executed.
#
#   bc_write_routes <project>
#     rc 0, one bc_item for each of write.comments, write.move, write.turn,
#     write.triage and write.create. No network: a write route is never probed
#     live. The evidence is the hand-maintained catalog/board-features.json,
#     .projects[<project>]["write.<route>"] = {status, source}:
#       status ok|missing with a non-empty source -> that status, note = source
#       a row with no source                      -> unverified "row has no source"
#       a row with any other status               -> unverified
#       no row                                    -> unverified "no catalog row"
#       no file / no harness root                 -> unverified
#       a file jq cannot read for <project>       -> unverified "catalog unreadable"
#     Root: ${HARNESS:-${H:-}} only.

bc_write_routes() {
  local p="${1:-}" root="${HARNESS:-${H:-}}" f route row st src
  f="$root/catalog/board-features.json"
  for route in write.comments write.move write.turn write.triage write.create; do
    if [ -z "$root" ] || [ ! -f "$f" ]; then
      bc_item "$route" unverified "no catalog/board-features.json"; continue
    fi
    if ! row=$(jq -c --arg p "$p" --arg r "$route" '.projects[$p][$r] // empty' "$f" 2>/dev/null); then
      bc_item "$route" unverified "catalog unreadable"; continue
    fi
    if [ -z "$row" ]; then
      bc_item "$route" unverified "no catalog row"; continue
    fi
    st=$(jq -r 'if type=="object" then (.status // "") | tostring else "" end' <<<"$row" 2>/dev/null)
    src=$(jq -r 'if type=="object" and (.source|type)=="string" then .source else "" end' <<<"$row" 2>/dev/null)
    if [ -z "$src" ]; then
      bc_item "$route" unverified "row has no source"
    else
      case "$st" in
        ok|missing) bc_item "$route" "$st" "$src" ;;
        *) bc_item "$route" unverified "row status $st is not ok|missing" ;;
      esac
    fi
  done
  return 0
}
