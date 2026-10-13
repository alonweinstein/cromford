# shellcheck shell=bash
# bin/lib/board-conformance/report.sh — alerting and the fix-ticket draft
# (BH-3947; this body BH-3961). Sourced, never executed. The root is
# ${HARNESS:-${H:-}} and nothing else (D43).
#
#   bc_alert_on_change <project> <statefile>
#     rc 0 always. Called only after the state file is in place and only for a
#     probe that ran (probe "ok"). ONE alert family per project, id
#     board-conformance:<p>, re-sent only when the gap set changes. The set last
#     sent is state/board-conformance/<p>.alerted (sorted names), written only
#     AFTER lane-alert.sh returns, so a crash in between costs one duplicate,
#     never a silent miss. lane-alert's rc is not read.
#       same set            -> nothing
#       changed, non-empty  -> silent alert_state_resolve of the id (so the open
#                              row does not suppress the delta), then one
#                              `--severity warn` line naming new and cleared
#       now empty           -> one `--resolve` "board now meets the contract"
#     An empty root or project, an unreadable state or one with no gaps array
#     is one stderr line: nothing sent, the watermark untouched.
#   bc_file_ticket <project>
#     prints a markdown "Bring the <p> board to full contract" draft from
#     state/board-conformance/<p>.json: one bullet per missing|malformed item
#     with its status, note and docs/BOARD-API-CONTRACT.md section. Reads that
#     file only: no network, no alert, no write. rc 2 (stderr) for an empty
#     root or project, no state ("run the probe first"), an unparseable state,
#     or a state whose last probe failed.

_bc_root() {
  local r="${HARNESS:-${H:-}}"
  [ -n "$r" ] || return 2
  printf '%s\n' "$r"
}

# _bc_section <item> -> the docs/BOARD-API-CONTRACT.md heading it belongs to.
# Specific field patterns first; anything unknown is "## Endpoints".
_bc_section() {
  case "$1" in
    *health*) echo '## Health' ;;
    *migration*) echo '## Migrations' ;;
    *depend*|*parentId*|*blocked*) echo '### Dependencies' ;;
    *waitingOn*) echo '### waitingOn' ;;
    *triageVerdict*) echo '### triageVerdict' ;;
    *status*|*turnChangedAt*) echo '### status' ;;
    boards*|*keyPrefix*) echo '### GET /boards' ;;
    tickets*|list*) echo '### GET /boards/{boardId}/tickets' ;;
    ticket*|detail*|reporter*|comment*) echo '### GET /tickets/{id}' ;;
    *) echo '## Endpoints' ;;
  esac
}

bc_alert_on_change() {
  local p="${1:-}" st="${2:-}" root w gaps old new cleared n
  root=$(_bc_root) || { echo "board-conformance: no harness root; not alerting" >&2; return 0; }
  [ -n "$p" ] || { echo "board-conformance: bc_alert_on_change: no project" >&2; return 0; }
  [ -r "$st" ] || { echo "board-conformance: $p: cannot read $st; not alerting" >&2; return 0; }
  if ! gaps=$(jq -r 'if (.gaps|type)=="array" then .gaps[] else error("no gaps array") end' "$st" 2>/dev/null); then
    echo "board-conformance: $p: $st has no gaps array; not alerting" >&2; return 0
  fi
  gaps=$(printf '%s\n' "$gaps" | grep -v '^$' | LC_ALL=C sort -u)
  w="$root/state/board-conformance/$p.alerted"
  old=$(grep -v '^$' "$w" 2>/dev/null | LC_ALL=C sort -u)
  [ "$gaps" = "$old" ] && return 0
  new=$(LC_ALL=C comm -23 <(printf '%s\n' "$gaps") <(printf '%s\n' "$old") | grep -v '^$' | paste -sd, - | sed 's/,/, /g')
  cleared=$(LC_ALL=C comm -13 <(printf '%s\n' "$gaps") <(printf '%s\n' "$old") | grep -v '^$' | paste -sd, - | sed 's/,/, /g')
  if [ -n "$gaps" ]; then
    n=$(printf '%s\n' "$gaps" | wc -l)
    # shellcheck source=/dev/null
    ( . "$root/bin/lib/alert-state.sh" && alert_state_resolve "board-conformance:$p" ) >/dev/null 2>&1 || true
    "$root/bin/lane-alert.sh" --id "board-conformance:$p" --severity warn board-conformance \
      "$p: $n contract gaps (new: ${new:-none}; cleared: ${cleared:-none}) — state/board-conformance/$p.json"
  else
    "$root/bin/lane-alert.sh" --id "board-conformance:$p" --resolve board-conformance \
      "$p: board now meets the contract"
  fi
  if [ -n "$gaps" ]; then printf '%s\n' "$gaps" > "$w.tmp.$$"; else : > "$w.tmp.$$"; fi \
    && mv -f "$w.tmp.$$" "$w" \
    || { rm -f "$w.tmp.$$"; echo "board-conformance: $p: cannot write $w; the next run re-sends" >&2; }
  return 0
}

bc_file_ticket() {
  local p="${1:-}" root s probe at note items n name status inote
  root=$(_bc_root) || { echo "board-conformance: no harness root" >&2; return 2; }
  [ -n "$p" ] || { echo "board-conformance: --file-ticket needs a project" >&2; return 2; }
  s="$root/state/board-conformance/$p.json"
  if [ ! -r "$s" ]; then
    echo "board-conformance: no state for $p — run the probe first (bin/board-conformance.sh $p)" >&2
    return 2
  fi
  if ! IFS=$'\t' read -r probe at note < <(jq -er '[.probe, .probed_at, (.probe_note//"")]|@tsv' "$s" 2>/dev/null); then
    echo "board-conformance: $p: cannot parse $s; re-run the probe" >&2; return 2
  fi
  if [ "$probe" != ok ]; then
    echo "board-conformance: $p: The last probe failed (${note:-no note}); re-run it before filing." >&2
    return 2
  fi
  if ! jq -e '.items|type=="object"' "$s" >/dev/null 2>&1 \
    || ! items=$(jq -r '.items|to_entries|map(select(.value.status=="missing" or .value.status=="malformed"))
      |sort_by(.key)|.[]|[.key, .value.status, (.value.note//"")]|@tsv' "$s" 2>/dev/null); then
    echo "board-conformance: $p: $s has no items object; re-run the probe" >&2; return 2
  fi
  n=0; [ -n "$items" ] && n=$(printf '%s\n' "$items" | wc -l)
  printf '# Bring the %s board to full contract\n\n' "$p"
  if [ "$n" -eq 0 ]; then
    printf 'No contract gaps in the last probe.\n'
  else
    printf 'Probe of %s (probe: %s) found %s gaps against docs/BOARD-API-CONTRACT.md.\n\n' "$at" "$probe" "$n"
    while IFS=$'\t' read -r name status inote; do
      printf -- '- `%s`: %s. %s (docs/BOARD-API-CONTRACT.md, "%s")\n' "$name" "$status" "$inote" "$(_bc_section "$name")"
    done <<<"$items"
  fi
  printf '\nOut of scope: write routes (unverified).\n'
  return 0
}
