#!/bin/bash
# bin/lib/gh-shim/read-maps.sh — the jq mappers the PR and issue read handlers
# share (#769 chunk 2). Sourced by bin/gh-rest-shim step 6, never executed.
#
# WHY A SHARED FILE. `author`, `labels` and the comment thread come back in the
# same REST shapes on a pull, an issue and a review, and gh's GraphQL spelling
# of each is what the harness reads. One mapper per shape, written once, so a
# pull and an issue can never disagree about what `.author.login` means.
#
# GSHIM_JQ_DEFS is a jq PROGRAM PREFIX, not a shell function: every handler pastes
# it in front of its own filter so the defs are available inside it.
#   gshim_up      upper-case, null-safe (GraphQL enums are upper, REST's are not)
#   gshim_author  {login,is_bot}; login is `app/<name>` for a Bot whose login ends
#               `[bot]` — the spelling harness_pr_author_match expects. TYPE, not
#               the suffix, decides: a human login that merely ends `[bot]` is
#               not an App and is left alone.
#   gshim_labels  [{id,name,description,color}] with id = node_id
#   gshim_actor   {login} for the places gh emits only a login (review author)
# ISO timestamps pass through untouched: REST already answers them the way
# GraphQL does.
GSHIM_JQ_DEFS='
def gshim_up: if . == null then null else ascii_upcase end;
def gshim_actor: if . == null then null else {login: .login} end;
def gshim_author:
  if . == null then null
  else {
    login: (if .type == "Bot" and (.login | test("\\[bot\\]$"))
            then "app/" + (.login | sub("\\[bot\\]$"; ""))
            else .login end),
    is_bot: (.type == "Bot")
  } end;
def gshim_labels:
  if . == null then null
  else [ .[] | {id: .node_id, name: .name, description: .description, color: .color} ] end;
'

# gshim_uri <string> — the string as ONE url-safe query term. jq's @uri leaves
# A-Za-z0-9-_.~ alone and percent-encodes everything else, so `BH-788` travels
# unchanged while `&` can no longer open a second query parameter and `#` can no
# longer truncate the URL at a fragment. The `${terms// /+}` this replaced sent
# `a&b #1` as `q=repo:o/r+is:pr+a&b+#1`, which GitHub read as `q=repo:o/r+is:pr+a`
# plus a stray `b` parameter — a search that answered the wrong question.
gshim_uri() {
  jq -rn --arg t "${1:-}" '$t|@uri'
}

# gshim_author_q <author> / gshim_label_q [label…] — the `author:` and `label:`
# QUALIFIERS a --search query carries for the two flags the REST list branch
# post-filters. A post-filter on a search answer has no over-fetch behind it,
# so `--search x --author y --limit 30` answered 30 hits minus everyone else's;
# on the index the qualifier IS the filter and --limit counts matches. Labels
# are split on commas as well as repeated flags, the way the REST branch's
# `labels=a,b` does, and each one is quoted so a label with a space searches
# as one term rather than two. Each prints with its leading `+`, or nothing.
gshim_author_q() {
  [ -n "${1:-}" ] || return 0
  printf '+author:%s' "$(gshim_uri "$1")"
}
gshim_label_q() {
  local l one bare
  for l in "$@"; do
    IFS=, read -r -a bare <<<"$l"
    for one in ${bare[@]+"${bare[@]}"}; do
      [ -n "$one" ] || continue
      printf '+label:%s' "$(gshim_uri "\"$one\"")"
    done
  done
}

# gshim_file — gshim_tmp, or the contract's own "cannot create a temp file" exit
# message; the caller adds `|| exit 1`. BODIES NEVER TRAVEL THROUGH ARGV: every
# REST answer a handler holds on to goes to one of these and reaches jq through
# --slurpfile or as a positional file, never as `--argjson`. One thread of 40
# comments at 3 KB is over MAX_ARG_STRLEN (128 KB per argument); jq then never
# starts, and an unguarded `x=$(jq …)` prints "" with rc 0 — "no comments" to
# the caller. gshim_paginate already pages the same way; this is the same rule
# for everything that comes after the page.
gshim_file() {
  gshim_tmp && return 0
  echo "gh-rest-shim: cannot create a temp file" >&2
  return 1
}

# gshim_drop_pages — the page ceiling a DROP-FILTERED read may spend, which is
# NOT the same budget as an unfiltered one. A read whose rows get dropped after
# the fetch has to look at more records than it returns, so holding it to the
# plain GH_SHIM_MAX_PAGES made `--limit N` undeliverable the moment the dropped
# rows outnumbered the kept ones: `issue list --state all --limit 1000`
# (bin/load-project.sh:330-334,377-381) capped its window at 10x100 = 1000 rows,
# and cromford is past #1201 with issues and pulls interleaved in the same
# endpoint, so the window ALWAYS came back full with fewer than 1000 issues in
# it and the handler always exited 1. Real gh answers that call from GraphQL, which is issues-only,
# and answers it fine. GH_SHIM_DROP_PAGE_FACTOR x GH_SHIM_MAX_PAGES (3 x 10 =
# 3000 rows) is what lets the same read reach the end of a board that interleaves
# two record types. Sanitation is gshim_paginate's, line for line.
gshim_drop_pages() {
  local maxp="${GH_SHIM_MAX_PAGES:-10}" f="${GH_SHIM_DROP_PAGE_FACTOR:-3}"
  case "$maxp" in ''|*[!0-9]*) maxp=10 ;; esac
  [ "$maxp" -ge 1 ] || maxp=10
  case "$f" in ''|*[!0-9]*) f=3 ;; esac
  [ "$f" -ge 1 ] || f=3
  printf '%s' "$((maxp * f))"
}

# gshim_paginate_wide <endpoint> <limit> [jq-path] — gshim_paginate under the
# drop ceiling instead of the plain one. The ceiling is a shell variable
# gshim_paginate reads, so it is raised for exactly this call and put back
# afterwards; a handler that paged wide must not leave the next call wide.
gshim_paginate_wide() {
  local had=0 prev="" rc=0
  if [ -n "${GH_SHIM_MAX_PAGES+x}" ]; then had=1; prev="$GH_SHIM_MAX_PAGES"; fi
  GH_SHIM_MAX_PAGES=$(gshim_drop_pages)
  gshim_paginate "$@" || rc=$?
  if [ "$had" = 1 ]; then GH_SHIM_MAX_PAGES="$prev"; else unset GH_SHIM_MAX_PAGES; fi
  return "$rc"
}

# gshim_overfetch <limit> — how many rows to ASK gshim_paginate for on a query whose
# rows get dropped after the fetch (the .pull_request rows, --author, --label,
# merged). Twice the limit, because slicing to --limit before the filter answers
# `--limit 30` with the 4 that matched; never more than the DROP ceiling can
# deliver, because gshim_paginate EXITS 1 ("narrow the query") the moment it needs
# one page more than it is allowed.
#
# NEVER BELOW <limit> ITSELF. When even the caller's own limit is wider than the
# ceiling, the honest answer is still gshim_paginate's exit — returning a ceiling's
# worth of rows as if it were the whole list is the truncation the contract
# refuses to print.
gshim_overfetch() {
  local limit="${1:-$GSHIM_LIMIT}" want cap
  case "$limit" in ''|*[!0-9]*) limit=30 ;; esac
  [ "$limit" -ge 1 ] || limit=30
  cap=$(( $(gshim_drop_pages) * 100 ))
  want=$((limit * 2))
  [ "$want" -gt "$cap" ] && want="$cap"
  [ "$want" -lt "$limit" ] && want="$limit"
  printf '%s' "$want"
}

# gshim_widen <fetch> — the NEXT window a drop-filtered read should try, on
# stdout, or rc 1 when the drop ceiling is already reached.
#
# WHY A SECOND LOOK RATHER THAN A SHORT ANSWER. A fetch of limit*2 that comes
# back full with fewer than --limit rows surviving the filter proves only that
# this window was too narrow — more records exist and some of them may match.
# Printing what survived is the dishonest answer the contract refuses (`pr list
# --state merged --limit 100` answering 80 rows rc 0 where gh answers 100), and
# exiting straight away is worse for the callers that already swallow a non-zero
# rc into `[]` (bin/board-invariants.sh:81, bin/pr-owner-sweep.sh:261,
# bin/lib/revdep-lib.sh:163): they would trade a short list for an empty one.
# So the window doubles and the read runs again, up to the drop ceiling; only a
# ceiling that still cannot fill --limit is an error.
gshim_widen() {
  local cur="${1:-0}" cap nxt
  case "$cur" in ''|*[!0-9]*) return 1 ;; esac
  cap=$(( $(gshim_drop_pages) * 100 ))
  [ "$cur" -ge "$cap" ] && return 1
  nxt=$((cur * 2))
  [ "$nxt" -gt "$cap" ] && nxt="$cap"
  printf '%s' "$nxt"
}

# gshim_wants <field> — true when the caller asked for this --json field. A field
# nobody asked for must never cost a REST call.
gshim_wants() {
  case ",$GSHIM_FIELDS," in
    *",$1,"*) return 0 ;;
    *) return 1 ;;
  esac
}

# gshim_fetch_comments <slug> <number> — the issue/PR comment thread as gh's
# GraphQL shape. `id` is node_id because the triage state file keys
# lastSeenCommentId on gh's node id, and the REST integer id is a different
# namespace: emitting it would make every thread look brand new.
#
# The 1000 ceiling is the contract's page cap (10 x 100) doing its job: a longer
# thread EXITS from gshim_paginate rather than coming back truncated, because a
# half-read thread read as whole is how a triage pass decides a client never
# answered.
gshim_fetch_comments() {
  local slug="$1" num="$2" raw
  raw=$(gshim_file) || exit 1
  gshim_paginate "repos/$slug/issues/$num/comments" 1000 >"$raw" || exit $?
  jq -c "$GSHIM_JQ_DEFS"'
    [ .[] | {
      id: .node_id,
      author: (.user | gshim_author | if . == null then null else {login: .login} end),
      authorAssociation: .author_association,
      body: .body,
      createdAt: .created_at,
      updatedAt: .updated_at,
      url: .html_url
    } ]' "$raw" || exit 1
}
