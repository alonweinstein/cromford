# bin/lib/prebuild-repro/stop.sh — the repro gate's stop stage (BH-2043).
# pr_stop <project> <ticket-id> <key> <build> <thread-json> <verdict>: rc 0 build, 10 stopped and commented, 11 comment failed.
#
# A bug the drive could not see (NOT_REPRODUCED) or saw already working
# (ALREADY_FIXED) gets ONE comment on its ticket, and an in-app ticket goes to
# the client's court. The repro_gate ledger, keyed by pr_ledger_key, makes that
# comment happen once per thread: `<v>_uncommented` is written BEFORE the send
# and `<v>` only after a response that carries a comment. A ledger we cannot
# read or write is never a stop (rc 0). Order and statuses: docs/repro-gate/stop.md.
#
# Sourced by bin/lib/prebuild-repro.sh, which run-build.sh sources: functions
# only, nothing runs at source time.
# shellcheck shell=bash

# _prs_field <file> <NAME> — the first `NAME: value` line, or "not recorded".
_prs_field() {
  local v=""
  [ -r "$1" ] && v=$(sed -n "/^$2:/{s/^$2:[[:space:]]*//p;q;}" "$1" 2>/dev/null)
  printf '%s' "${v:-not recorded}"
}

_prs_esc() { printf '%s' "${1:-}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'; }

_prs_ask="Could you send a screenshot or the exact steps you took? We'll pick it straight back up."

# _prs_mark <ledger-key> — the stop comment's own marker (BH-2133). An HTML
# comment, so it renders as nothing on GitHub or on an in-app board. Two
# readers: pr_ledger_key leaves a comment carrying it out of thread_fp (our own
# comment is not the thread moving), and _prs_posted finds it on a retry.
_prs_mark() { printf '<!-- harness:repro-stop %s -->' "${1##*/}"; }

# _prs_md_esc <text> — model-supplied text made inert in GitHub markdown
# (BH-2133): markdown punctuation backslash-escaped (no link, image, emphasis
# or code span), `&`, `<` and `>` as entities (no raw HTML), and a zero-width
# space after every `@` and `#` (no live @-mention of a person or a team, no
# cross-reference to an issue).
_prs_md_esc() {
  local zw; zw=$(printf '\342\200\213')
  printf '%s' "${1:-}" | sed -e 's/\\/\\\\/g' -e 's/[][`*_!|~()]/\\&/g' \
    -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e "s/[@#]/&$zw/g"
}

# _prs_html <lead> <role> <url> <steps> <observed> [marker]
# THE URL IS A REAL LINK HERE BECAUSE IT IS ALREADY ORIGIN-CHECKED (BH-2133):
# the drive only answers NOT_REPRODUCED / ALREADY_FIXED for a URL on the
# project's prod origin (drive.sh `_pr_origin`). A value that is not http(s)
# stays a <code> span, whatever it is.
_prs_html() {
  local u; u=$(_prs_esc "$3")
  case "$3" in
    http://*|https://*) u="<a href=\"$u\">$u</a>" ;;
    *) u="<code>$u</code>" ;;
  esac
  printf '<p>%s</p><p>We signed in as: <code>%s</code></p><p>We went to: %s</p><p>What we did:</p><blockquote>%s</blockquote><p>What we saw:</p><blockquote>%s</blockquote><p>%s</p>%s' \
    "$(_prs_esc "$1")" "$(_prs_esc "$2")" "$u" "$(_prs_esc "$4")" "$(_prs_esc "$5")" "$_prs_ask" "${6:-}"
}

# _prs_md <lead> <role> <url> <steps> <observed> [marker]
# The role and the URL are code spans (no autolink off model text); the steps
# and the observed text go through _prs_md_esc.
_prs_md() {
  printf '%s\n\n- We signed in as: `%s`\n- We went to: `%s`\n- What we did: %s\n\nWhat we saw:\n\n' \
    "$1" "${2//\`/}" "${3//\`/}" "$(_prs_md_esc "$4")"
  _prs_md_esc "$5" | sed 's/^/> /'
  printf '\n\n%s\n%s\n' "$_prs_ask" "${6:-}"
}

# _prs_root -> $HARNESS, else $H, else nothing (BH-2613). No root reads and
# sends exactly what an empty root does, and stamps and logs nothing.
_prs_root() { printf '%s' "${HARNESS:-${H:-}}"; }

# _prs_posted <project> <ticket-id> <key> <marker> <prefix> — rc 0 when the
# ticket already carries a comment with this marker. A post that was DELIVERED
# but not confirmed (a timeout, a 500 after the write) leaves the ledger at
# `_uncommented`, and the retry must not post it a second time (BH-2133). rc 1
# for "not there" and for any read failure: an unreadable thread keeps today's
# behaviour, which is to post. Only called on a retry, so a first send costs
# no extra read.
_prs_posted() {
  local h p="$1" tid="$2" key="$3" m="$4" prefix="$5" slug n page rc prod token resp t apps
  h=$(_prs_root); [ -n "$h" ] || return 1
  if [ "$prefix" = - ]; then
    slug=$("$h/bin/fleet-conf.sh" "$p" repo 2>/dev/null) || slug=""
    n="$tid"; [[ "$n" =~ ^[0-9]+$ ]] || n=$(sed -nE 's/^[A-Za-z]+-([0-9]+)$/\1/p' <<<"$key")
    [ -n "$slug" ] && [ -n "$n" ] || return 1
    # shellcheck disable=SC1091
    command -v gh_rest >/dev/null 2>&1 || { [ -r "$h/bin/lib/gh-rest.sh" ] && . "$h/bin/lib/gh-rest.sh" 2>/dev/null; }
    command -v gh_rest >/dev/null 2>&1 || return 1
    # Ours = the marker AND one of the harness Apps as the author (N2): a
    # client quoting our comment carries the marker too, and that is not a
    # delivery. No allowlist = nothing is found = post, today's behaviour.
    apps=$(command -v harness_self_apps_json >/dev/null 2>&1 && harness_self_apps_json); [ -n "$apps" ] || apps='[]'
    t=$(mktemp "${TMPDIR:-/tmp}/repro-seen.XXXXXX") || return 1
    for page in 1 2 3 4 5; do
      rc=0; gh_rest GET "repos/$slug/issues/$n/comments" -F per_page=100 -F page="$page" > "$t" 2>/dev/null || rc=$?
      if [ "$rc" != 0 ] || ! jq -e 'type == "array"' "$t" >/dev/null 2>&1; then rm -f "$t"; return 1; fi
      jq -e --arg m "$m" --argjson apps "$apps" "${HARNESS_SELF_JQ_DEF:-def hs_ours(\$a): false;}"'
          any(.[]; ((.body // "") | tostring | contains($m)) and hs_ours($apps))' "$t" >/dev/null 2>&1 && { rm -f "$t"; return 0; }
      [ "$(jq 'length' "$t")" -lt 100 ] && break
    done
    rm -f "$t"; return 1
  fi
  prod=$("$h/bin/fleet-conf.sh" "$p" prod 2>/dev/null) || prod=""
  [ -n "$prod" ] && [ "$prod" != - ] && [ -n "$prefix" ] && [ -n "$tid" ] || return 1
  token=$("$h/bin/internal-token-for.sh" "$p" 2>/dev/null) || token=""
  [ -n "$token" ] || return 1
  resp=$(curl -s --max-time 25 -H "Authorization: Bearer $token" -H "User-Agent: curl/8" \
    "$prod$prefix/tickets/$tid" 2>/dev/null) || return 1
  # In-app, ours is a comment the board marks internal (the harness posts with
  # the internal token), never a client's.
  printf '%s' "$resp" | jq -e --arg m "$m" \
    'any(((.comments? // .ticket.comments? // .data.comments? // [])[]?);
         ((.body // "") | tostring | contains($m)) and ((.isInternal // false) == true))' >/dev/null 2>&1
}

# _prs_log <project> <build> <line> — one line in logs/<project>.log and pipeline.log.
_prs_log() {
  local h; h=$(_prs_root)
  if [ -n "$h" ]; then
    mkdir -p "$h/logs" 2>/dev/null
    printf '%s\n' "$3" >> "$h/logs/$1.log"
  fi
  [ -d "$2" ] && printf '%s\n' "$3" >> "$2/pipeline.log"
  return 0
}

# _prs_send_app <project> <ticket-id> <html> — rc 0 only on a comment object; turn after it.
_prs_send_app() {
  local h prod prefix token resp
  h=$(_prs_root); [ -n "$h" ] || return 1
  prod=$("$h/bin/fleet-conf.sh" "$1" prod 2>/dev/null) || prod=""
  prefix=$("$h/bin/fleet-conf.sh" "$1" board_prefix 2>/dev/null) || prefix=""
  [ -n "$prod" ] && [ "$prod" != - ] && [ -n "$prefix" ] && [ -n "$2" ] || return 1
  token=$("$h/bin/internal-token-for.sh" "$1" 2>/dev/null) || token=""
  [ -n "$token" ] || return 1
  resp=$(curl -s --max-time 25 -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
    -H "User-Agent: curl/8" -X POST -d "$(jq -nc --arg b "$3" '{body:$b}')" \
    "$prod$prefix/tickets/$2/comments" 2>/dev/null) || resp=""
  printf '%s' "$resp" | jq -e '(.comment // .id // .data) != null' >/dev/null 2>&1 || return 1
  _prs_turn "$prod$prefix" "$2" "$token"
  return 0
}

# _prs_turn <board-base> <ticket-id> <token> — the one turn to the client, sent
# only after a comment is known to be on the ticket. Answer in _PRS_TURN.
_prs_turn() {
  _PRS_TURN=$(curl -s --max-time 25 -H "Authorization: Bearer $3" -H "Content-Type: application/json" \
    -H "User-Agent: curl/8" -X POST -d '{"to":"client"}' "$1/tickets/$2/turn" 2>/dev/null) || _PRS_TURN=""
}

# _prs_send_gh <project> <ticket-id> <key> <markdown> — rc 0 only on a body with an id.
_prs_send_gh() {
  local h slug n bf out rc=1
  h=$(_prs_root); [ -n "$h" ] || return 1
  slug=$("$h/bin/fleet-conf.sh" "$1" repo 2>/dev/null) || slug=""
  n="$2"; [[ "$n" =~ ^[0-9]+$ ]] || n=$(sed -nE 's/^[A-Za-z]+-([0-9]+)$/\1/p' <<<"$3")
  [ -n "$slug" ] && [ -n "$n" ] || return 1
  bf=$(mktemp "${TMPDIR:-/tmp}/repro-stop.XXXXXX") || return 1
  out=$(mktemp "${TMPDIR:-/tmp}/repro-stop.XXXXXX") || { rm -f "$bf"; return 1; }
  printf '%s' "$4" > "$bf"
  # Only through gh_rest: no gh-rest.sh on the box is a failed send (rc 11 and
  # the ALERT), never a bare `gh api` the fleet gh-identity ratchet cannot see.
  # shellcheck disable=SC1091
  if [ -r "$h/bin/lib/gh-rest.sh" ] && . "$h/bin/lib/gh-rest.sh" 2>/dev/null && command -v gh_rest >/dev/null 2>&1; then
    gh_rest POST "repos/$slug/issues/$n/comments" -F "body=@$bf" > "$out" 2>/dev/null || true
  fi
  jq -e '.id != null' "$out" >/dev/null 2>&1 && rc=0
  rm -f "$bf" "$out"
  return "$rc"
}

pr_stop() {
  local project="${1:-}" ticket="${2:-}" key="${3:-}" build="${4:-}" thread="${5:-}" verdict="${6:-}"
  local h v lkey st rc prefix md lead role url steps obs body over mark retry=0 _PRS_TURN=""
  h=$(_prs_root)
  case "$verdict" in
    NOT_REPRODUCED) v=not_reproduced ;;
    ALREADY_FIXED)  v=already_fixed ;;
    *) return 0 ;;
  esac
  lkey=$(pr_ledger_key "$project" "$key" "$thread" 2>/dev/null) || return 0
  [ -n "$lkey" ] || return 0

  # 1. Read. A delivered comment for this exact thread is a stop with no post;
  # an outage is a build, never a blind stop.
  [ -n "$h" ] && [ -x "$h/bin/jobs-client.sh" ] || return 0
  st=$("$h/bin/jobs-client.sh" ledger-get repro_gate "$lkey" 2>/dev/null); rc=$?
  st=$(printf '%s' "$st" | tr -d '[:space:]')
  case "$rc" in
    0) case "$st" in
         not_reproduced|already_fixed) return 10 ;;
         *_uncommented) retry=1 ;;
       esac ;;
    2) ;;
    *) return 0 ;;
  esac

  # 2. Write before send, with no detail so the drive's detail is kept.
  "$h/bin/jobs-client.sh" ledger-put repro_gate "$lkey" "${v}_uncommented" >/dev/null 2>&1 || return 0

  # 3. Compose once.
  md="$build/prebuild-repro.md"
  role=$(_prs_field "$md" REPRO_ROLE); url=$(_prs_field "$md" REPRO_URL)
  steps=$(_prs_field "$md" REPRO_STEPS); obs=$(_prs_field "$md" REPRO_OBSERVED)
  obs="${obs:0:2000}"
  if [ "$v" = not_reproduced ]; then
    lead="We tried to reproduce this before building a fix, and we couldn't see the problem."
  else
    lead="We tried this before building and it looks like it already works."
  fi

  # 4. Send — unless this is a retry and the earlier post is already on the
  # ticket (delivered, never confirmed): then it is delivered, so record it.
  prefix=$("$h/bin/fleet-conf.sh" "$project" board_prefix 2>/dev/null) || prefix=""
  mark=$(_prs_mark "$lkey")
  if [ "$retry" = 1 ] && _prs_posted "$project" "$ticket" "$key" "$mark" "$prefix"; then
    "$h/bin/jobs-client.sh" ledger-put repro_gate "$lkey" "$v" >/dev/null 2>&1 \
      || _prs_log "$project" "$build" "repro stop: $key was already commented, but the ledger put of $v failed for $lkey"
    _prs_log "$project" "$build" "repro stop: $key retry found the earlier comment on the ticket; not posted again"
    # The unconfirmed send never reached its turn; an in-app ticket gets it now.
    if [ "$prefix" != - ]; then
      _prs_turn "$("$h/bin/fleet-conf.sh" "$project" prod 2>/dev/null)$prefix" "$ticket" "$("$h/bin/internal-token-for.sh" "$project" 2>/dev/null)"
    fi
    return 10
  fi
  if [ "$prefix" = - ]; then
    body=$(_prs_md "$lead" "$role" "$url" "$steps" "$obs" "$mark")
    _prs_send_gh "$project" "$ticket" "$key" "$body"; rc=$?
  else
    # The in-app cap: trim the observed text first, then the steps.
    body=$(_prs_html "$lead" "$role" "$url" "$steps" "$obs" "$mark")
    while [ "${#body}" -gt 5000 ] && [ -n "$obs$steps" ]; do
      over=$(( ${#body} - 5000 + 20 ))
      if [ -n "$obs" ]; then obs="${obs:0:$(( ${#obs} > over ? ${#obs} - over : 0 ))}"
      else steps="${steps:0:$(( ${#steps} > over ? ${#steps} - over : 0 ))}"; fi
      body=$(_prs_html "$lead" "$role" "$url" "$steps" "${obs:+$obs (trimmed)}" "$mark")
    done
    _prs_send_app "$project" "$ticket" "$body"; rc=$?
  fi

  # 6. Not delivered: the ledger stays _uncommented and the next offer retries.
  if [ "$rc" != 0 ]; then
    mkdir -p "$h/logs" 2>/dev/null
    printf '%s [%s] prebuild-repro: %s %s comment POST failed — ledger %s left %s_uncommented; the next offer retries\n' \
      "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$project" "$key" "$verdict" "$lkey" "$v" >> "$h/logs/ALERTS.log"
    return 11
  fi

  # 5. Delivered. A failed final put still stops: a retry would post twice.
  "$h/bin/jobs-client.sh" ledger-put repro_gate "$lkey" "$v" >/dev/null 2>&1 \
    || _prs_log "$project" "$build" "repro stop: $key commented, but the ledger put of $v failed for $lkey"
  if [ "$prefix" != - ] && ! printf '%s' "$_PRS_TURN" | jq -e 'type == "object" and (has("error") | not)' >/dev/null 2>&1; then
    _prs_log "$project" "$build" "repro stop: $key commented, but the turn to client was refused: $(printf '%.160s' "$_PRS_TURN" | tr '\n' ' ')"
  fi
  return 10
}
