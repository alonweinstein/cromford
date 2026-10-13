# shellcheck shell=bash
# bin/lib/board-conformance/board.sh — the in-app board probe (BH-3947; this
# body BH-3959). Sourced, never executed. GET only, at most 3 GETs through
# bc_get, every item through bc_item (common.sh). jq judges every body; no body
# is ever eval'ed or put into a shell word.
#
#   bc_probe_board <prefix> <base> <token>
#     rc 0 = probed: all 20 items below recorded, one bc_item each.
#     rc 3 = the probe failed (000, 5xx or 401 on any of the 3 GETs); the reason
#            is in $BC_PROBE_NOTE and the entry discards the partial items.
#
#   GET {base}{prefix}/boards              boards.envelope boards.id
#                                          boards.keyPrefix boards.capability.dependencies
#   GET {base}{prefix}/boards/{b0}/tickets ticket.<14 fields>, judged over ALL rows
#   GET {base}{prefix}/tickets/{first id}  detail.envelope detail.comments
#
# An item that cannot be judged because an earlier GET came back unusable is
# `unverified` with the reason, so one root cause is one gap, not twenty.
# Zero tickets reads `unverified` ("board has no tickets"), never ok.

_BCB_BOARDS=(boards.id boards.keyPrefix boards.capability.dependencies)
_BCB_TICKET=(ticket.id ticket.status ticket.waitingOn ticket.triageVerdict ticket.commentCount
  ticket.lastActivityAt ticket.title ticket.key ticket.reporter.userId ticket.updatedAt
  ticket.turnChangedAt ticket.type ticket.labels ticket.dependencies)
_BCB_DETAIL=(detail.envelope detail.comments)

# _bcb_all <status> <note> <name>... — the same verdict for every name.
_bcb_all() { local s="$1" n="$2"; shift 2; local i; for i in "$@"; do bc_item "$i" "$s" "$n"; done; }

# _bcb_down <code> — the transport did not answer usefully (000, 5xx, 401).
_bcb_down() { case "$(bc_class "$1")" in 000|5xx) return 0 ;; esac; [ "$1" = 401 ]; }

# _bcb_emit <file> — read name<TAB>status<TAB>note lines into bc_item.
_bcb_emit() { local n s t; while IFS=$'\t' read -r n s t; do bc_item "$n" "$s" "$t"; done < "$1"; }

# The per-field verdicts over every ticket row (all but ticket.dependencies).
# shellcheck disable=SC2016  # a jq program, not shell
_BCB_FIELDS_JQ='
def isid: type == "string" or type == "number";
def chk($k; f): if type == "object" and has($k) then (if (.[$k] | f) then "ok" else "bad" end) else "absent" end;
(.tickets? // .) as $R | ($R | length) as $N |
def verdict($name; $s):
  ([$s[] | select(. == "absent")] | length) as $a | ([$s[] | select(. == "bad")] | length) as $b |
  if $a > 0 then [$name, "missing", "absent on \($a)/\($N)" + (if $b > 0 then "; wrong type on \($b)/\($N)" else "" end)]
  elif $b > 0 then [$name, "malformed", "\($b)/\($N)"]
  else [$name, "ok", ""] end;
(verdict("ticket.id"; [$R[] | chk("id"; isid)]),
 verdict("ticket.status"; [$R[] | chk("status"; type == "string")]),
 verdict("ticket.waitingOn"; [$R[] | chk("waitingOn"; . == null or type == "string")]),
 verdict("ticket.triageVerdict"; [$R[] | chk("triageVerdict"; . == null or (type == "string" and . != ""))]),
 verdict("ticket.commentCount"; [$R[] | chk("commentCount"; type == "number")]),
 verdict("ticket.lastActivityAt"; [$R[] | chk("lastActivityAt"; type == "string")]),
 verdict("ticket.title"; [$R[] | chk("title"; type == "string")]),
 verdict("ticket.key"; [$R[] |
   if type != "object" or ((has("key") or has("number")) | not) then "absent"
   elif ((.key | type) == "string" and .key != "") or ((.number | type) == "number" and (.number | floor) == .number) then "ok"
   else "bad" end]),
 verdict("ticket.reporter.userId"; [$R[] |
   if type == "object" and (.reporter | type) == "object" and (.reporter | has("userId"))
   then (if (.reporter.userId | type) == "string" and .reporter.userId != "" then "ok" else "bad" end)
   else "absent" end]),
 verdict("ticket.updatedAt"; [$R[] | chk("updatedAt"; type == "string")]),
 verdict("ticket.turnChangedAt"; [$R[] | chk("turnChangedAt"; . == null or type == "string")]),
 verdict("ticket.type"; [$R[] |
   if type != "object" or ((has("type") or has("ticketType") or has("issueType")) | not) then "absent"
   elif [.type, .ticketType, .issueType] | any(type == "string") then "ok"
   else "bad" end]),
 verdict("ticket.labels"; [$R[] | chk("labels"; type == "array")])
) | @tsv'

# ticket.dependencies has its own shape per capability, so it is one more
# program rather than a branch the verdict() helper cannot express.
# shellcheck disable=SC2016  # a jq program, not shell
_BCB_DEPS_JQ='
(.tickets? // .) as $R | ($R | length) as $N |
def has4: type == "object" and (has("parentId") and has("dependsOn") and has("children") and has("blocked"));
def hasany: type == "object" and (has("parentId") or has("dependsOn") or has("children") or has("blocked"));
def good: ((.parentId | . == null or type == "number" or (type == "string" and length > 0))
  and (.dependsOn | type) == "array" and (.children | type) == "array" and (.blocked | type) == "boolean");
if $cap == 1 then
  ([$R[] | select(has4 | not)] | length) as $a | ([$R[] | select(has4) | select(good | not)] | length) as $b |
  if $a > 0 then ["ticket.dependencies", "missing", "absent on \($a)/\($N)"]
  elif $b > 0 then ["ticket.dependencies", "malformed", "\($b)/\($N)"]
  else ["ticket.dependencies", "ok", ""] end
else
  ([$R[] | select(hasany)] | length) as $c |
  if $c > 0 then ["ticket.dependencies", "malformed", "\($c)/\($N) rows served without the dependencies capability"]
  else ["ticket.dependencies", "ok", ""] end
end | @tsv'

bc_probe_board() {
  local d rc
  # shellcheck disable=SC2034  # read by bin/board-conformance.sh
  BC_PROBE_NOTE=""
  d=$(mktemp -d) || { BC_PROBE_NOTE="board probe: mktemp failed"; return 3; }
  _bcb_probe "$1" "$2" "$3" "$d"; rc=$?
  rm -rf "$d"
  return "$rc"
}

# shellcheck disable=SC2034  # BC_PROBE_NOTE is read by bin/board-conformance.sh
_bcb_probe() {
  local prefix="$1" base="$2" tok="$3" d="$4" code cap=0 bid tid
  # 1. the board list
  code=$(bc_get "$base$prefix/boards" "$d/b" "$tok")
  if _bcb_down "$code"; then BC_PROBE_NOTE="GET $prefix/boards $code"; return 3; fi
  if [ "$(bc_class "$code")" = 404 ]; then
    bc_item boards.envelope missing "GET boards 404"
    _bcb_all unverified "no board list" "${_BCB_BOARDS[@]}" "${_BCB_TICKET[@]}" "${_BCB_DETAIL[@]}"; return 0
  fi
  if [ "$(bc_class "$code")" != 2xx ] || ! jq -e '(.boards? // .) | type == "array"' "$d/b" >/dev/null 2>&1; then
    if [ "$(bc_class "$code")" = 2xx ]; then bc_item boards.envelope malformed "not a board list"
    else bc_item boards.envelope malformed "GET boards $code"; fi
    _bcb_all unverified "no board list" "${_BCB_BOARDS[@]}" "${_BCB_TICKET[@]}" "${_BCB_DETAIL[@]}"; return 0
  fi
  bc_item boards.envelope ok ""
  if [ "$(jq '(.boards? // .) | length' "$d/b" 2>/dev/null)" = 0 ]; then
    _bcb_all unverified "board list is empty" "${_BCB_BOARDS[@]}" "${_BCB_TICKET[@]}" "${_BCB_DETAIL[@]}"; return 0
  fi
  # The capability expression is bin/lib/fc-board.sh's, verbatim.
  [ "$(jq -r '(.boards? // .) | if type == "array" then (.[0].capabilities | if type == "array" then any(.[]; . == "dependencies") else false end) else false end' "$d/b" 2>/dev/null)" = true ] && cap=1
  jq -r --argjson cap "$cap" '(.boards? // .) as $B | ($B | length) as $N |
    ([$B[] | select((type == "object" and ((.id | type) == "string" or (.id | type) == "number")) | not)] | length) as $x |
    (if $x == 0 then ["boards.id", "ok", ""] else ["boards.id", "missing", "absent on \($x)/\($N)"] end),
    ($B[0] | if type == "object" and has("keyPrefix") then
        (if (.keyPrefix | type) == "string" and .keyPrefix != "" then ["boards.keyPrefix", "ok", ""]
         else ["boards.keyPrefix", "malformed", "not a non-empty string"] end)
      else ["boards.keyPrefix", "missing", "absent on board[0]"] end),
    (if $cap == 1 then ["boards.capability.dependencies", "ok", ""]
     else ["boards.capability.dependencies", "missing", "board[0] does not advertise dependencies"] end)
    | @tsv' "$d/b" > "$d/bi" 2>/dev/null \
    || { BC_PROBE_NOTE="board probe: cannot judge the board list"; return 3; }
  _bcb_emit "$d/bi"
  bid=$(jq -r '(.boards? // .)[0] | if type == "object" and ((.id | type) == "string" or (.id | type) == "number") then (.id | tostring | @uri) else empty end' "$d/b" 2>/dev/null)
  if [ -z "$bid" ]; then
    _bcb_all unverified "board[0] has no id" "${_BCB_TICKET[@]}" "${_BCB_DETAIL[@]}"; return 0
  fi

  # 2. board[0]'s tickets
  code=$(bc_get "$base$prefix/boards/$bid/tickets" "$d/t" "$tok")
  if _bcb_down "$code"; then BC_PROBE_NOTE="GET $prefix/boards/$bid/tickets $code"; return 3; fi
  if [ "$(bc_class "$code")" = 404 ]; then
    _bcb_all missing "GET tickets 404" "${_BCB_TICKET[@]}"
    _bcb_all unverified "no ticket list" "${_BCB_DETAIL[@]}"; return 0
  fi
  if [ "$(bc_class "$code")" != 2xx ] || ! jq -e '(.tickets? // .) | type == "array"' "$d/t" >/dev/null 2>&1; then
    if [ "$(bc_class "$code")" = 2xx ]; then _bcb_all malformed "not a ticket list" "${_BCB_TICKET[@]}"
    else _bcb_all malformed "GET tickets $code" "${_BCB_TICKET[@]}"; fi
    _bcb_all unverified "no ticket list" "${_BCB_DETAIL[@]}"; return 0
  fi
  if [ "$(jq '(.tickets? // .) | length' "$d/t" 2>/dev/null)" = 0 ]; then
    _bcb_all unverified "board has no tickets" "${_BCB_TICKET[@]}" "${_BCB_DETAIL[@]}"; return 0
  fi
  { jq -r "$_BCB_FIELDS_JQ" "$d/t" && jq -r --argjson cap "$cap" "$_BCB_DEPS_JQ" "$d/t"; } > "$d/ti" 2>/dev/null \
    || { BC_PROBE_NOTE="board probe: cannot judge the ticket list"; return 3; }
  _bcb_emit "$d/ti"

  # 3. the first ticket's detail
  tid=$(jq -r '(.tickets? // .)[0] | if type == "object" and ((.id | type) == "string" or (.id | type) == "number") then (.id | tostring | @uri) else empty end' "$d/t" 2>/dev/null)
  if [ -z "$tid" ]; then
    _bcb_all unverified "no ticket id" "${_BCB_DETAIL[@]}"; return 0
  fi
  code=$(bc_get "$base$prefix/tickets/$tid" "$d/x" "$tok")
  if _bcb_down "$code"; then BC_PROBE_NOTE="GET $prefix/tickets/$tid $code"; return 3; fi
  if [ "$(bc_class "$code")" = 404 ]; then
    _bcb_all missing "GET ticket detail 404" "${_BCB_DETAIL[@]}"; return 0
  fi
  if [ "$(bc_class "$code")" = 2xx ] && jq -e '(.ticket // .) | type == "object" and has("id")' "$d/x" >/dev/null 2>&1; then
    bc_item detail.envelope ok ""
  elif [ "$(bc_class "$code")" = 2xx ]; then
    bc_item detail.envelope malformed "no ticket object with an id"
  else
    bc_item detail.envelope malformed "GET ticket detail $code"
  fi
  if [ "$(bc_class "$code")" = 2xx ] && jq -e '(.comments? // .ticket.comments? // .data.comments?) | type == "array"' "$d/x" >/dev/null 2>&1; then
    bc_item detail.comments ok ""
  else
    bc_item detail.comments missing "no comments array"
  fi
  return 0
}
