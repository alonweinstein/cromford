#!/bin/bash
# bin/lib/gh-shim/issue-read.sh — `gh issue view` and `gh issue list` as REST
# reads (#769 chunk 2). Sourced by bin/gh-rest-shim step 6, never executed.
#
# THE ONE TRAP THIS FILE EXISTS TO AVOID: /repos/{slug}/issues RETURNS PULL
# REQUESTS TOO. Every row carrying `.pull_request` is dropped BEFORE --limit is
# applied, because a board pass that reads a PR as a ticket triages a PR, and
# slicing first would answer `--limit 100` with 60 issues and 40 pulls.
#
# `comments` COSTS ONE CALL PER ISSUE. bin/triage-gate.sh asks for 100 and
# bin/orphan-reconcile.sh for 200, so that is 100/200 extra REST calls per tick
# — the documented price of the field, paid only when --json names it.

GSHIM_ISSUE_FIELDS='number,title,body,state,url,labels,author,createdAt,updatedAt,closedAt,assignees,milestone,id,comments'

GSHIM_ISSUE_MAP='{
  number: .number,
  title: .title,
  body: .body,
  state: (.state | gshim_up),
  url: .html_url,
  labels: (.labels | gshim_labels),
  author: (.user | gshim_author),
  createdAt: .created_at,
  updatedAt: .updated_at,
  closedAt: .closed_at,
  assignees: [ (.assignees // [])[] | gshim_author ],
  milestone: (if .milestone == null then null else {title: .milestone.title, number: .milestone.number} end),
  id: .node_id
}'

gshim_cmd_issue_view() {
  local arg num body mapped sub
  arg=$(gshim_pr_arg)
  # No --json: gh's human renderer is the real binary's job.
  [ -n "$GSHIM_FIELDS" ] || gshim_passthru untranslated
  gshim_slug "$arg"
  gshim_fields_ok "$GSHIM_ISSUE_FIELDS"
  num="$GSHIM_NUM"
  if [ -z "$num" ]; then
    echo "gh-rest-shim: issue view needs an issue number or URL" >&2
    exit 1
  fi
  body=$(gshim_api "repos/$GSHIM_SLUG/issues/$num") || exit $?
  mapped=$(printf '%s' "$body" | jq -c "$GSHIM_JQ_DEFS$GSHIM_ISSUE_MAP") || exit 1
  if gshim_wants comments; then
    sub=$(gshim_file) || exit 1
    gshim_fetch_comments "$GSHIM_SLUG" "$num" >"$sub" || exit $?
    mapped=$(gshim_pr_attach "$mapped" comments "$sub") || exit 1
  fi
  gshim_emit "$mapped"
}

# gshim_issue_search_q <state> <terms> <author> [label…] — the query `gh issue list --search`
# really means. --state and --label are QUALIFIERS ON THE SEARCH INDEX, not
# post-filters: the search endpoint takes neither `state=` nor `labels=`, so a
# handler that built them for /repos/{slug}/issues and then searched instead sent
# an unfiltered query. `bin/up10-lane.sh:91` is the caller that pays — its
# `--label ai-build --state open --search "\"up10: $SLUG\" in:title` matched a
# CLOSED lane issue and the lane reused it instead of filing a new one.
#
# `all` gets no state: qualifier and no --state at all means open, which is gh's
# own behaviour. --author and --label ride as qualifiers too (gshim_author_q,
# gshim_label_q): a post-filter on a search answer has no over-fetch behind it.
gshim_issue_search_q() {
  local state="$1" terms="$2" author="$3"; shift 3
  local q="repo:$GSHIM_SLUG+is:issue"
  case "$state" in ''|open) q="$q+state:open" ;; closed) q="$q+state:closed" ;; all) : ;; esac
  q="$q$(gshim_label_q "$@")$(gshim_author_q "$author")"
  [ -n "$terms" ] && q="$q+$(gshim_uri "$terms")"
  printf '%s' "$q"
}

gshim_cmd_issue_list() {
  local state="open" author="" search="" labels=() i=0 a
  while [ "$i" -lt "${#GSHIM_REST[@]}" ]; do
    a="${GSHIM_REST[$i]}"
    case "$a" in
      --state)   state="${GSHIM_REST[$((i+1))]:-}"; i=$((i+2)) ;;
      --state=*) state="${a#--state=}"; i=$((i+1)) ;;
      --author)  author="${GSHIM_REST[$((i+1))]:-}"; i=$((i+2)) ;;
      --author=*) author="${a#--author=}"; i=$((i+1)) ;;
      --search|-S) search="${GSHIM_REST[$((i+1))]:-}"; i=$((i+2)) ;;
      --search=*) search="${a#--search=}"; i=$((i+1)) ;;
      --label|-l) labels+=("${GSHIM_REST[$((i+1))]:-}"); i=$((i+2)) ;;
      --label=*) labels+=("${a#--label=}"); i=$((i+1)) ;;
      -*)        gshim_passthru "flag:$a" ;;
      *)         i=$((i+1)) ;;
    esac
  done
  gshim_slug ""
  gshim_fields_ok "$GSHIM_ISSUE_FIELDS"

  local q raw rows num sub fetch nraw nrows lim
  case "$state" in ''|open|closed|all) : ;; *) gshim_passthru "flag:--state" ;; esac
  q="state=${state:-open}"
  if [ "${#labels[@]}" -gt 0 ]; then
    # EACH label encoded, THEN joined on a literal comma: the comma is REST's
    # own AND separator and must stay a comma, while everything inside a label
    # is data. `--label "needs review"` used to put a raw space in the URL.
    # A single flag value is split on commas first, because gh's --label is a
    # string SLICE — `--label a,b` is two labels there, and gshim_label_q on the
    # search branch splits the same way.
    local lq="" one lbl bare
    for one in "${labels[@]}"; do
      IFS=, read -r -a bare <<<"$one"
      for lbl in ${bare[@]+"${bare[@]}"}; do
        [ -n "$lbl" ] || continue
        [ -z "$lq" ] || lq="$lq,"
        lq="$lq$(gshim_uri "$lbl")"
      done
    done
    [ -n "$lq" ] && q="$q&labels=$lq"
  fi
  # Over-fetch: the .pull_request rows come out of this answer, so asking for
  # exactly --limit would under-answer by however many pulls came back. Capped
  # by gshim_overfetch at the DROP ceiling, so the handler can never ask
  # gshim_paginate_wide for more rows than it is allowed to page.
  #
  # THE SEARCH BRANCH DOES NOT OVER-FETCH. `is:issue`, `state:`, `label:` and
  # `author:` are all qualifiers on the index, so nothing is dropped after the
  # fetch and --limit already counts matches. Asking for twice the limit there
  # paged the 30-requests-per-minute search endpoint 10 times for a 600-row read
  # that needed 6.
  fetch=$(gshim_overfetch "$GSHIM_LIMIT")
  lim="$GSHIM_LIMIT"
  case "$lim" in ''|*[!0-9]*) lim=30 ;; esac
  [ "$lim" -ge 1 ] || lim=30
  if [ -n "$search" ]; then
    raw=$(gshim_paginate "search/issues?q=$(gshim_issue_search_q "$state" "$search" "$author" \
            ${labels[@]+"${labels[@]}"})" "$GSHIM_LIMIT" .items) || exit $?
    rows=$(printf '%s' "$raw" | jq -c "$GSHIM_JQ_DEFS"'
      [ .[] | select(has("pull_request") | not) | '"$GSHIM_ISSUE_MAP"' ]') || exit 1
    # `author:` is already a qualifier on the query above, so this filter is a
    # no-op on a well-formed answer; it stays because the pre-qualifier contract
    # filtered here and a search index that answers wider must not answer wider
    # than gh does.
    [ -n "$author" ] && { rows=$(gshim_pr_filter "$rows" "$state" "$author") || exit 1; }
  else
    # A SHORT LIST IS NEVER AN ANSWER. Two kinds of row come out of this window
    # after the fetch — the pulls /repos/{slug}/issues interleaves, and --author
    # — so a window that came back FULL (`nraw == fetch`, more records exist)
    # with fewer than --limit issues left in it proves only that the window was
    # too narrow. bin/load-project.sh:330-334,377-381 runs `issue list --state
    # all --limit 1000 --json title | grep -qxF` as its duplicate-ticket guard,
    # and a short list read as the whole board files a duplicate ticket on a
    # client board. So the window DOUBLES and the read runs again (gshim_widen),
    # up to the drop ceiling; a ceiling that still cannot fill --limit exits.
    # gh's own `--limit 1000` is GraphQL and issues-only, which is why it never
    # had to do any of this.
    while :; do
      raw=$(gshim_paginate_wide "repos/$GSHIM_SLUG/issues?$q" "$fetch") || exit $?
      rows=$(printf '%s' "$raw" | jq -c "$GSHIM_JQ_DEFS"'
        [ .[] | select(has("pull_request") | not) | '"$GSHIM_ISSUE_MAP"' ]') || exit 1
      [ -n "$author" ] && { rows=$(gshim_pr_filter "$rows" "$state" "$author") || exit 1; }
      nraw=$(printf '%s' "$raw" | jq 'length') || exit 1
      nrows=$(printf '%s' "$rows" | jq 'length') || exit 1
      # Enough rows, or the endpoint ran out of records before the window did:
      # both are the whole answer to this query.
      { [ "$nrows" -ge "$lim" ] || [ "$nraw" -lt "$fetch" ]; } && break
      fetch=$(gshim_widen "$fetch") || {
        echo "gh-rest-shim: only $nrows of $lim rows survive a full window — narrow the query" >&2
        exit 1
      }
    done
  fi
  rows=$(printf '%s' "$rows" | jq -c ".[:$GSHIM_LIMIT]") || exit 1

  # ONE TEMP FILE PER THREAD, joined by one `jq -s`. 100 issues x 3 comments x
  # 3 KB is ~1 MB; an `--argjson` accumulator is E2BIG after ~40 threads and
  # the handler then exits 1 into a gate that fails open.
  if gshim_wants comments; then
    local rf tf cf cfiles=()
    rf=$(gshim_file) || exit 1
    printf '%s' "$rows" >"$rf"
    for num in $(jq -r '.[].number' "$rf"); do
      tf=$(gshim_file) || exit 1
      cf=$(gshim_file) || exit 1
      gshim_fetch_comments "$GSHIM_SLUG" "$num" >"$tf" || exit $?
      jq -c --arg n "$num" '{n: ($n|tonumber), c: .}' "$tf" >"$cf" || exit 1
      cfiles+=("$cf")
    done
    rows=$(jq -c -s '.[0] as $rows | .[1:] as $m
      | [ $rows[] | . as $r | .comments = (($m[] | select(.n == $r.number) | .c) // []) ]' \
      "$rf" ${cfiles[@]+"${cfiles[@]}"}) || exit 1
  fi

  if [ -n "$GSHIM_FIELDS" ] || [ -n "$GSHIM_JQ" ]; then
    gshim_emit "$rows"
  else
    # gh's non-TTY TSV, in gh's OWN column order: number, STATE, title, labels,
    # updatedAt — measured against the real binary on this box, not guessed. A
    # reader that takes field 2 as the title reads `OPEN` as a title.
    printf '%s' "$rows" | jq -r '.[] | [ (.number|tostring), .state, .title,
      ([ (.labels // [])[].name ] | join(",")), .updatedAt ] | @tsv'
  fi
}
