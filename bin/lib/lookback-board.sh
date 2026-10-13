# shellcheck shell=bash
# bin/lib/lookback-board.sh — BH-1795.4: lookback_file_board, the filer the
# weekly `lookback` lane (bin/lookback.sh) calls for a target:app cluster. It
# puts the cluster on that project's product board through the board's ticket
# API (docs/BOARD-API-CONTRACT.md). Sourced, never executed; no output on source.
# The shapes and rc convention are in bin/lib/lookback-common.sh.
#
#   lookback_file_board <cluster_json> <run_dir>
#     4  the project has no board: fleet.conf column 4 is `-`, or its env file
#        has no token/base. Zero calls, no ALERTS line. (A DUPLICATE token is a
#        broken env, and bin/lib/board-creds.sh writes its usual alert.)
#     75 the ledger row cannot be read. Nothing is sent.
#     3  the row names a ticket that is still open: one comment listing only
#        the item ids the row does not have yet (none new: no comment), and the
#        row's item_ids are unioned.
#     0  a new ticket, whose description ends `lookback-cluster: <fingerprint>`.
#        Only a create that answered an id counts, and only then is the
#        ledger row written (status filed, detail {board, ticket_id, ...}).
#     1  anything else failed; nothing is written.
#   lookback_board_comment <project> <ticket_id> <textfile> — 0 posted, 4 no
#     board, 1 failed. bin/lib/lookback-followup.sh posts through it.
#
# THE TOKEN rides curl's stdin config (`-K -`), never argv, a log or a line.
# Every posted text has its em and en dashes replaced first.

_LBB_LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/lib/internal-token.sh
declare -F internal_token_var >/dev/null || . "$_LBB_LIB/internal-token.sh" 2>/dev/null
# shellcheck source=bin/lib/board-creds.sh
declare -F board_token_var >/dev/null || . "$_LBB_LIB/board-creds.sh" 2>/dev/null
# shellcheck source=bin/lib/env-path.sh
declare -F harness_env_dir >/dev/null || . "$_LBB_LIB/env-path.sh" 2>/dev/null

_lbb_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# _lbb_clean — stdin to stdout with ` — ` as `, ` and any other em/en dash as `-`.
_lbb_clean() { sed -e 's/ — /, /g' -e 's/—/-/g' -e 's/–/-/g'; }

# _lbb_html — stdin text to HTML, the same rules as _fcb_html in fc-board.sh.
_lbb_html() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' | awk '
    /^[ \t]*$/ { if (p != "") { print "<p>" p "</p>"; p = "" }; next }
    { p = (p == "" ? $0 : p "<br>" $0) }
    END { if (p != "") print "<p>" p "</p>" }'
}

# lookback_board_resolve <project> — sets _LBB_BASE, _LBB_TOKEN, _LBB_TOKEN_VAR.
# rc 0 resolved, rc 4 no board. "No board" is decided before anything alerts.
lookback_board_resolve() {
  # The root is HARNESS, then H (BH-2613); bin/lookback.sh owns the default.
  # No root is "no board" (rc 4): zero calls, never a path from an empty root.
  local p="${1:-}" h="${HARNESS:-${H:-}}" fcs prefix envf tv bv rt rb tok base
  _LBB_BASE=""; _LBB_TOKEN=""; _LBB_TOKEN_VAR=""
  [ -n "$p" ] && [ -n "$h" ] || return 4
  fcs="$_LBB_LIB/../fleet-conf.sh"; [ -x "$fcs" ] || fcs="$h/bin/fleet-conf.sh"
  prefix=$(FLEET_CONF="${FLEET_CONF:-$h/fleet.conf}" "$fcs" "$p" board_prefix 2>/dev/null) || prefix=""
  case "$prefix" in ''|-) return 4 ;; esac
  envf="$(harness_env_dir "$h")/$p.env"
  [ -r "$envf" ] || return 4
  tv=$(internal_token_var "$envf"); rt=$?
  bv=$(app_base_var "$envf"); rb=$?
  if [ "$rt" = 1 ] || [ "$rb" = 1 ]; then return 4; fi
  if [ "$rt" != 0 ] || [ "$rb" != 0 ]; then
    board_token_var "$p" "$envf" lookback >/dev/null
    board_base_var "$p" "$envf" lookback >/dev/null
    return 4
  fi
  tok=$(board_env_value "$tv" "$envf"); base=$(board_env_value "$bv" "$envf")
  [ -n "$tok" ] && [ -n "$base" ] || return 4
  _LBB_TOKEN="$tok"; _LBB_TOKEN_VAR="$tv"; _LBB_BASE="${base%/}$prefix"
  return 0
}

# _lbb_curl <GET|POST> <url> [<json file> [<idempotency key>]] — the answer on
# stdout, curl's rc (HTTP >= 400 included, `-f`) as the rc.
_lbb_curl() {
  local method="$1" url="$2" data="${3:-}" idem="${4:-}" t
  local args=(-sS -f --max-time 30 -K - -H "User-Agent: curl/8")
  if [ "$method" = POST ]; then
    args+=(-X POST -H "Content-Type: application/json")
    [ -n "$idem" ] && args+=(-H "Idempotency-Key: $idem")
    args+=(--data-binary "@$data")
  fi
  t=${_LBB_TOKEN//\\/\\\\}; t=${t//\"/\\\"}
  printf 'header = "Authorization: Bearer %s"\n' "$t" | curl "${args[@]}" "$url"
}

# _lbb_post_text <url> <textfile> — {body} comment POST of a cleaned, HTML'd text.
_lbb_post_text() {
  local req rc
  req=$(mktemp "${TMPDIR:-/tmp}/lookback-board.XXXXXX") || return 1
  jq -n --arg b "$(_lbb_clean < "$2" | _lbb_html)" '{body:$b}' > "$req" || { rm -f "$req"; return 1; }
  _lbb_curl POST "$1" "$req" >/dev/null; rc=$?
  rm -f "$req"
  [ "$rc" = 0 ]
}

lookback_board_comment() {
  lookback_board_resolve "${1:-}" || return 4
  [ -n "${2:-}" ] && [ -r "${3:-}" ] || return 1
  _lbb_post_text "$_LBB_BASE/tickets/$2/comments" "$3" || return 1
  return 0
}

# _lbb_item_lines <bundle> <ids json> — one evidence line per item id.
_lbb_item_lines() {
  jq -r --argjson ids "$2" '
    (.items // []) as $all | $ids[] as $id
    | ($all | map(select(.id == $id)) | first) as $it
    | if $it == null then "- \($id)" else
        "- \($id): \($it.project // "?")"
        + (if $it.ticket then ", ticket \($it.ticket)" else "" end)
        + (if $it.pr then ", PR #\($it.pr)" else "" end)
        + (if ($it.files // []) | length > 0 then ", files \($it.files | join(" "))" else "" end)
        + (if $it.lane then ", lane \($it.lane)" else "" end)
        + (if $it.reason then ": \($it.reason)" else "" end)
      end' "$1" 2>/dev/null || jq -r '.[] | "- \(.)"' <<<"$2"
}

lookback_file_board() {
  local c="${1:-}" run="${2:-}" fp p title ids row rrc detail tid status new n tmp resp rc
  local boards bid req nid nkey now put prior="" rstat idem
  fp=$(jq -er '.fingerprint | select(type == "string" and length > 0)' <<<"$c" 2>/dev/null) \
    && p=$(jq -er '.project | select(type == "string" and length > 0)' <<<"$c" 2>/dev/null) \
    && ids=$(jq -ec '.item_ids | select(type == "array")' <<<"$c" 2>/dev/null) \
    || { echo "failed: unreadable cluster"; return 1; }
  title=$(jq -r '.title // "lookback cluster"' <<<"$c")

  lookback_board_resolve "$p" || { echo "$p has no board configured"; return 4; }

  # THE LEDGER IS READ BEFORE ANYTHING IS SENT; an outage sends nothing.
  declare -F job_ledger_row >/dev/null || { echo "ledger unreadable: $title"; return 75; }
  row=$(job_ledger_row lookback_cluster "$fp"); rrc=$?
  case "$rrc" in
    0|2) ;;
    *) echo "ledger unreadable: $title"; return 75 ;;
  esac
  if [ "$rrc" = 0 ]; then
    detail=$(jq -c '.detail | if type == "string" then (try fromjson catch null) else . end
                    | select(type == "object")' <<<"$row" 2>/dev/null)
    tid=$(jq -r '.ticket_id // empty | tostring' <<<"${detail:-null}" 2>/dev/null)
    # A row we cannot read a ticket from is not "never filed": a guess here is
    # a duplicate ticket on a client board.
    [ -n "$tid" ] || { echo "failed: ledger row $fp names no ticket"; return 1; }
    # The comment path writes back the row's OWN status: resetting a
    # followed_up_* row to `filed` would re-arm the one-time 30-day follow-up.
    rstat=$(jq -r '.status // empty' <<<"$row" 2>/dev/null)
    [ -n "$rstat" ] || rstat=filed
    resp=$(_lbb_curl GET "$_LBB_BASE/tickets/$tid") \
      || { echo "failed: ticket $tid state unreadable"; return 1; }
    status=$(jq -r '(.ticket // .data // .).status // empty' <<<"$resp" 2>/dev/null)
    [ -n "$status" ] || { echo "failed: ticket $tid state unreadable"; return 1; }
    case "$status" in
      done|closed|archived|cancelled|canceled) prior="$tid" ;;
      *)
        new=$(jq -c --argjson have "$(jq -c '.item_ids // []' <<<"$detail")" '. - $have' <<<"$ids")
        n=$(jq 'length' <<<"$new")
        put=""
        if [ "$n" -gt 0 ]; then
          tmp=$(mktemp "${TMPDIR:-/tmp}/lookback-board.XXXXXX") || { echo "failed: no temp file"; return 1; }
          { printf '%s new:\n' "$n"; _lbb_item_lines "$run/bundle.json" "$new"; } > "$tmp"
          if ! _lbb_post_text "$_LBB_BASE/tickets/$tid/comments" "$tmp"; then
            rm -f "$tmp"; echo "failed: comment on $p ticket $tid"; return 1
          fi
          rm -f "$tmp"
          job_ledger_put lookback_cluster "$fp" "$rstat" \
            "$(jq -c --argjson new "$new" '.item_ids = ((.item_ids // []) + $new | unique)' <<<"$detail")" \
            || put="; ledger write failed"
        fi
        echo "$title on $p ticket $tid ($n new items)$put"
        return 3 ;;
    esac
  fi

  # CREATE, on board [0] (docs/BOARD-API-CONTRACT.md "The write lanes take [0]").
  boards=$(_lbb_curl GET "$_LBB_BASE/boards") || { echo "failed: board list on $p unreadable"; return 1; }
  bid=$(jq -r '(.boards? // .) | if type == "array" then (.[0].id // empty | tostring) else empty end' <<<"$boards" 2>/dev/null)
  [ -n "$bid" ] || { echo "failed: no board id on $p"; return 1; }
  tmp=$(mktemp "${TMPDIR:-/tmp}/lookback-board.XXXXXX") || { echo "failed: no temp file"; return 1; }
  req="$tmp.json"
  {
    jq -r '.cause // ""' <<<"$c"; echo
    echo "Evidence:"; _lbb_item_lines "$run/bundle.json" "$ids"; echo
    echo "Proposed fix:"; jq -r '.proposed_fix // ""' <<<"$c"; echo
    echo "lookback-cluster: $fp"
  } | _lbb_clean | _lbb_html > "$tmp"
  jq -n --arg t "$(printf '%s' "$title" | _lbb_clean)" --rawfile d "$tmp" \
    '{title:$t, description:($d | sub("\n$"; ""))}' > "$req"
  # A re-create after a closed ticket gets its own key, so a board that honours
  # it never answers with the closed original.
  idem="lookback-$fp"; [ -n "$prior" ] && idem="$idem-$prior"
  resp=$(_lbb_curl POST "$_LBB_BASE/boards/$bid/tickets" "$req" "$idem"); rc=$?
  rm -f "$tmp" "$req"
  nid=$(jq -r '(.ticket // .).id // empty | tostring' <<<"$resp" 2>/dev/null)
  if [ "$rc" != 0 ] || [ -z "$nid" ]; then echo "failed: create on $p (rc=$rc)"; return 1; fi
  nkey=$(jq -r '(.ticket // .).key // empty | tostring' <<<"$resp" 2>/dev/null)
  now=$(_lbb_now_iso)
  put=""
  job_ledger_put lookback_cluster "$fp" filed "$(jq -c --arg p "$p" --arg id "$nid" --arg k "$nkey" \
      --arg at "$now" --arg prior "$prior" --argjson ids "$ids" '
    {board:$p, ticket_id:$id} + (if $k != "" then {key:$k} else {} end)
    + {filed_at:$at, key_kind, key_value, project, target:"app", items:($ids|length), item_ids:$ids}
    + (if $prior != "" then {prior_ticket:$prior} else {} end)' <<<"$c")" \
    || put="; ledger write failed, next run may duplicate"
  echo "$title on $p ticket ${nkey:-$nid}$put"
  return 0
}
