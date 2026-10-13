# bin/lib/prebuild-repro/thread.sh — pr_fetch_thread (BH-2040, order 2 of #2004).
# pr_fetch_thread <project> <ticket-id> <key>: the normalized thread JSON on
# stdout, rc 0. rc 1 = the board exists and could not be read (nothing printed,
# never an "empty thread"). rc 3 = the project has no board this can read.
# Function-only: run-build.sh sources this file. docs/repro-gate/skip.md.
# shellcheck shell=bash

# _prt_self_actor <project> — the in-app board's system actor name. A copy of
# the SELF_ACTORS column of the case in bin/triage-gate.sh (keep them in step).
_prt_self_actor() {
  case "${1:-}" in
    project-1)   echo "project-1 Team Harness" ;;
    project-2) echo "project-2 Harness" ;;
    project-3)       echo "project-3 AI Harness" ;;
    project-4)       echo "system-board Harness" ;;
  esac
}

pr_fetch_thread() {
  # The root is HARNESS, then H (BH-2613); bin/prebuild-repro.sh owns the
  # /root/harness default. No root is "cannot fetch" (rc 3), never a path
  # built from an empty root.
  local p="${1:-}" tid="${2:-}" key="${3:-}" h="${HARNESS:-${H:-}}" prefix
  [ -n "$h" ] && [ -n "$p" ] && [ -x "$h/bin/fleet-conf.sh" ] || return 3
  prefix=$("$h/bin/fleet-conf.sh" "$p" board_prefix 2>/dev/null) || return 3
  [ -n "$prefix" ] || return 3
  if [ "$prefix" = - ]; then _prt_gh "$h" "$p" "$tid" "$key"; else _prt_app "$h" "$p" "$tid" "$prefix"; fi
}

# _prt_gh <harness> <project> <ticket-id> <key> — a GitHub-Issues board.
_prt_gh() {
  local h="$1" p="$2" n="$3" key="$4" slug d rc total last trunc ours apps
  slug=$("$h/bin/fleet-conf.sh" "$p" repo 2>/dev/null) || slug=""
  [[ "$n" =~ ^[0-9]+$ ]] || n=$(sed -nE 's/^[A-Za-z]+-([0-9]+)$/\1/p' <<<"$key")
  [ -n "$slug" ] && [ "$slug" != - ] && [ -n "$n" ] || return 3
  # shellcheck disable=SC1091
  command -v gh_rest >/dev/null 2>&1 || { [ -r "$h/bin/lib/gh-rest.sh" ] && . "$h/bin/lib/gh-rest.sh" 2>/dev/null; }
  command -v gh_rest >/dev/null 2>&1 || return 1
  # shellcheck disable=SC1091
  command -v harness_pr_spellings >/dev/null 2>&1 || { [ -r "$h/bin/lib/gh-pr-list.sh" ] && . "$h/bin/lib/gh-pr-list.sh" 2>/dev/null; }
  # shellcheck disable=SC1091
  command -v harness_self_apps_json >/dev/null 2>&1 || { [ -r "$h/bin/lib/harness-self.sh" ] && . "$h/bin/lib/harness-self.sh" 2>/dev/null; }
  d=$(mktemp -d "${TMPDIR:-/tmp}/repro-thread.XXXXXX") || return 1
  rc=0; gh_rest GET "repos/$slug/issues/$n" > "$d/i" 2>/dev/null || rc=$?
  if [ "$rc" != 0 ] || ! jq -e 'type == "object"' "$d/i" >/dev/null 2>&1; then rm -rf "$d"; return 1; fi
  rc=0; gh_rest GET "repos/$slug/issues/$n/comments" -F per_page=100 > "$d/c1" 2>/dev/null || rc=$?
  if [ "$rc" != 0 ] || ! jq -e 'type == "array"' "$d/c1" >/dev/null 2>&1; then rm -rf "$d"; return 1; fi
  # Past 100 comments, page 1 alone would freeze pr_ledger_key (it keys on the
  # newest comment), so the page holding the newest one is read and merged too.
  # An issue with no comment count and a full first page is truncated too: we
  # cannot tell it holds only 100.
  total=$(jq -r '.comments | numbers' "$d/i" 2>/dev/null)
  echo '[]' > "$d/c2"; trunc=false
  if [ -z "$total" ]; then
    [ "$(jq 'length' "$d/c1")" -ge 100 ] && trunc=true
  elif [ "$total" -gt 100 ]; then
    trunc=true; last=$(( (total + 99) / 100 ))
    rc=0; gh_rest GET "repos/$slug/issues/$n/comments" -F per_page=100 -F page="$last" > "$d/c2" 2>/dev/null || rc=$?
    if [ "$rc" != 0 ] || ! jq -e 'type == "array"' "$d/c2" >/dev/null 2>&1; then rm -rf "$d"; return 1; fi
  fi
  apps=$(command -v harness_self_apps_json >/dev/null 2>&1 && harness_self_apps_json); [ -n "$apps" ] || apps='[]'
  ours=$( (command -v harness_pr_spellings >/dev/null 2>&1 && harness_pr_spellings) | jq -R . | jq -sc 'map(ascii_downcase)')
  [ -n "$ours" ] || ours='[]'
  # harness = one of the harness Apps, or the stop marker from one of our
  # authors (the Apps or the PAT login). A client quoting the marker is not ours.
  if ! jq -nc --slurpfile i "$d/i" --slurpfile a "$d/c1" --slurpfile b "$d/c2" \
      --argjson trunc "$trunc" --argjson apps "$apps" --argjson ours "$ours" \
      "${HARNESS_SELF_JQ_DEF:-def hs_ours(\$a): false;}"'
      def prin: ((.author_association // "") as $x | ["OWNER","MEMBER","COLLABORATOR"] | index([$x]) != null)
                or ((.user.type // "") == "Bot");
      $i[0] as $iss
      | {source: "gh", truncated: $trunc, body: ($iss.body // "" | tostring), body_principal: ($iss | prin),
         comments: ([$a[0][], $b[0][]] | unique_by(.id) | sort_by([(.created_at // ""), .id]) | map({
           id: (.id | tostring), createdAt: (.created_at // "" | tostring), body: (.body // "" | tostring),
           author: (.user.login // "" | tostring), principal: prin,
           harness: (hs_ours($apps)
                     or (((.body // "") | tostring | contains("<!-- harness:repro-stop"))
                         and ((.user.login // "" | tostring | ascii_downcase) as $l | $ours | index([$l]) != null)))
         }))}' > "$d/out" 2>/dev/null; then
    rm -rf "$d"; return 1
  fi
  cat "$d/out"; rm -rf "$d"
}

# _prt_app <harness> <project> <ticket-id> <prefix> — an in-app board, the same
# read bin/lib/prebuild-repro/stop.sh _prs_posted makes.
_prt_app() {
  local h="$1" p="$2" tid="$3" prefix="$4" prod token resp out
  prod=$("$h/bin/fleet-conf.sh" "$p" prod 2>/dev/null) || prod=""
  [ -n "$prod" ] && [ "$prod" != - ] && [ -n "$tid" ] || return 3
  token=$("$h/bin/internal-token-for.sh" "$p" 2>/dev/null) || token=""
  [ -n "$token" ] || return 1
  resp=$(curl -s --max-time 25 -H "Authorization: Bearer $token" -H "User-Agent: curl/8" \
    "$prod$prefix/tickets/$tid" 2>/dev/null) || return 1
  # Principal = a comment the board marks internal, or one by this board's
  # system actor. Ours (`harness`) = a principal comment that carries the stop
  # marker: the harness posts with the internal token, but so does a person,
  # and their comment must move pr_ledger_key. A client cannot post internal,
  # so a client quoting the marker is not ours.
  out=$(printf '%s' "$resp" | jq -c --arg actor "$(_prt_self_actor "$p" | tr '[:upper:]' '[:lower:]')" '
      def who: if (.author | type) == "object" then (.author.name // "") else (.author // "") end | tostring;
      if type != "object" then error("not an object") else . end
      | (.comments // .ticket.comments // .data.comments) as $c
      | if ($c | type) != "array" then error("no comments array") else . end
      | (if (.ticket | type) == "object" then .ticket elif (.data | type) == "object" then .data else . end) as $t
      | ($t.reporter // .reporter // {}) as $r
      | {source: "app", truncated: (($c | length) > 100),
         body: ($t.description // $t.body // "" | tostring),
         body_principal: ((($r.userId? // $t.reporterId // .reporterId // "") == "system") or ($r.isInternal? == true)),
         comments: [$c[] | ((.isInternal // false) == true
                            or ($actor != "" and ([who, (.author.userId? // "")]
                                                  | map(tostring | ascii_downcase) | index([$actor]) != null))) as $pr
                    | {id: (.id | tostring), createdAt: (.createdAt // "" | tostring), body: (.body // "" | tostring),
                       author: who, principal: $pr,
                       harness: ($pr and ((.body // "") | tostring | contains("<!-- harness:repro-stop")))}]}' 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}
