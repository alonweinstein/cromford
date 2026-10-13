#!/bin/bash
# bin/lib/gh-shim/pr-write.sh — the `gh pr` WRITE verbs as single REST calls
# (#769 chunk 3). Sourced by bin/gh-rest-shim step 6; never executed.
#
# Handlers take no arguments. They read the contract's parsed globals
# (GSHIM_REPO GSHIM_FIELDS GSHIM_JQ GSHIM_LIMIT GSHIM_REST[]) and call only the contract's
# helpers (gshim_api gshim_passthru gshim_slug gshim_fields_ok gshim_emit gshim_bodyfile
# gshim_input gshim_paginate gshim_tmp). Nothing in here runs gh, $GH_REAL or gh api.
#
# EXITS, NOT RETURNS: gshim_api exits 75 (rate limited) or 1 (anything else), so
# every call site is `out=$(gshim_api …) || exit $?`. gshim_passthru and gshim_slug
# exec the real binary and never come back.
#
# FLAGS FIRST, WRITES SECOND. Each handler walks its whole flag list before it
# makes a single request: a flag we do not translate has to reach the real
# binary with the original argv, and a pass-through decided halfway through a
# write sequence would repeat the writes already made.
#
# BODY TEXT NEVER TRAVELS IN ARGV. --body/--body-file go through gshim_bodyfile
# into a temp file and into the request through `gshim_input --rawfile`, so a body
# carrying |, quotes, $( … ) or non-ASCII is never interpolated anywhere.

# ── the per-verb argv walker ─────────────────────────────────────────────────
# gshim_prw_parse <spec> — spec is space-separated `flag:kind:key` tokens, both
# spellings of each flag listed separately:
#   v = takes a value, b = boolean, m = repeatable/comma list (comma-joined)
# Results land in GSHIM_PRW[key]; the first non-flag argument lands in
# GSHIM_PRW[pos]. A flag outside the spec is not ours to guess at: the whole call
# passes through logged as flag:<flag>.
gshim_prw_parse() {
  local spec=" $1 " a flag val kind key inline i=0
  unset GSHIM_PRW
  declare -gA GSHIM_PRW=()
  while [ "$i" -lt "${#GSHIM_REST[@]}" ]; do
    a="${GSHIM_REST[$i]}"
    case "$a" in
      --*=*) flag="${a%%=*}"; val="${a#*=}"; inline=1 ;;
      -*)    flag="$a"; val=""; inline=0 ;;
      *)     [ -n "${GSHIM_PRW[pos]:-}" ] || GSHIM_PRW[pos]="$a"; i=$((i+1)); continue ;;
    esac
    kind=""; key=""
    case "$spec" in
      *" $flag:v:"*) kind=v; key="${spec##*" $flag:v:"}"; key="${key%% *}" ;;
      *" $flag:b:"*) kind=b; key="${spec##*" $flag:b:"}"; key="${key%% *}" ;;
      *" $flag:m:"*) kind=m; key="${spec##*" $flag:m:"}"; key="${key%% *}" ;;
    esac
    [ -n "$kind" ] || gshim_passthru "flag:$flag"
    if [ "$kind" = b ]; then
      GSHIM_PRW[$key]=1; i=$((i+1)); continue
    fi
    if [ "$inline" -eq 0 ]; then val="${GSHIM_REST[$((i+1))]:-}"; i=$((i+2)); else i=$((i+1)); fi
    if [ "$kind" = m ]; then
      GSHIM_PRW[$key]="${GSHIM_PRW[$key]:+${GSHIM_PRW[$key]},}$val"
    else
      GSHIM_PRW[$key]="$val"
    fi
  done
  return 0
}

# ── the request-body builder ─────────────────────────────────────────────────
# gshim_prw_body_init, then one gshim_prw_str/raw/json/expr per field in the order
# the body should carry them, then gshim_prw_build to get the --input path.
gshim_prw_body_init() { GSHIM_PRW_JA=(); GSHIM_PRW_P=""; }
gshim_prw_key()  { GSHIM_PRW_P="${GSHIM_PRW_P:+$GSHIM_PRW_P,}$1:${2:-\$$1}"; }
gshim_prw_str()  { GSHIM_PRW_JA+=(--arg "$1" "$2"); gshim_prw_key "$1"; }
gshim_prw_raw()  { GSHIM_PRW_JA+=(--rawfile "$1" "$2"); gshim_prw_key "$1"; }
gshim_prw_json() { GSHIM_PRW_JA+=(--argjson "$1" "$2"); gshim_prw_key "$1"; }
gshim_prw_split() { GSHIM_PRW_JA+=(--arg "$1" "$2"); gshim_prw_key "$1" "(\$$1|split(\",\")|map(select(length>0)))"; }
gshim_prw_build() { gshim_input "${GSHIM_PRW_JA[@]}" "{$GSHIM_PRW_P}"; }

# gshim_prw_bodyfield <key> — add a body field from --body/--body-file, as a raw
# file when there is one and the empty string when there is not. An unreadable
# --body-file is gshim_bodyfile's error and aborts the call.
gshim_prw_bodyfield() {
  local bf
  bf=$(gshim_bodyfile "${GSHIM_PRW[body]:-}" "${GSHIM_PRW[bodyfile]:-}") || exit 1
  if [ -n "$bf" ]; then gshim_prw_raw "$1" "$bf"; else gshim_prw_str "$1" ""; fi
}
gshim_prw_has_body() { [ -n "${GSHIM_PRW[body]:-}" ] || [ -n "${GSHIM_PRW[bodyfile]:-}" ]; }

# gshim_prw_labels_post <slug> <num> <csv> — one labels POST. Printed nothing on
# success; the caller decides what a failure means to it.
gshim_prw_labels_post() {
  local inp
  gshim_prw_body_init
  gshim_prw_split labels "$3"
  inp=$(gshim_prw_build) || exit 1
  gshim_api -X POST "repos/$1/issues/$2/labels" --input "$inp" >/dev/null
}

# gshim_prw_delete_branch <slug> <num> [best-effort:0|1] — DELETE the head ref of
# the PR, read from a raw GET.
#
# THE DELETE IS AGAINST THE BASE REPO, so the branch it names must LIVE there.
# A pull request from a FORK has its head in the fork, and refs/heads/<ref> in
# the base repo is then a DIFFERENT branch that happens to share the name —
# forks routinely open PRs from `main`. Deleting it would destroy work nobody
# asked us to touch. Real `gh` skips the remote delete on a cross-repository
# head, and bin/lib/gh-pr-merge.sh refuses it for the same reason (BH-892,
# "never delete a fork's branch"). Ownership is PROVEN from the same GET the ref
# comes from; a head whose repo the answer does not name (a fork deleted before
# the merge settled) is not proof. Lowercased on both sides: GitHub's canonical
# full_name and a -R slug can differ in case, and a case-only mismatch must not
# skip every delete.
#
# BEST EFFORT (1) is the POST-MERGE call. The merge has already landed and its
# line is already on stdout; a delete that fails there must never turn a merged
# PR into a non-zero exit — bin/poll-commands.sh:107 reads that rc as
# `merge failed:` and re-leases a console command toward a dead letter for a
# merge that is on main. A branch GitHub deleted itself (the repo's
# delete-branch-on-merge setting) is the ordinary case.
#
# NOTHING IS DELETED WHILE AN OPEN PR IS STILL BASED ON IT (BH-1715). With
# delete_branch_on_merge off, GitHub answers a ref delete by CLOSING every open
# PR based on that ref: #1659's branch went and #1664 and #1666 closed with it.
# So the delete lists the open PRs based on the ref first. On a MERGE (best=1)
# each one is PATCHed to this PR's own base, the order bin/lib/gh-pr-merge.sh
# `_gpm_delete_branch` keeps, and the ref goes only when every PATCH landed. On
# a CLOSE the parent never merged, and moving its children onto its base would
# put its unmerged commits in their diffs, so any open child keeps the branch.
# A list that did not read, is not an array, or is a full page of 100 proves
# nothing and keeps the branch too. Each kept branch is one stderr line. A merge
# still exits 0 (BEST EFFORT above). A close exits 0 when an open child is why
# the branch stayed, since that is the answer, and exits 1 when the list itself
# could not be proven, the same as a head ref that did not read.
gshim_prw_delete_branch() {
  local slug="$1" num="$2" best="${3:-0}" body ref hrepo pbase kids n kid left="" rc=0
  body=$(gshim_api "repos/$slug/pulls/$num") || rc=$?
  ref=$(printf '%s' "$body" | jq -r '.head.ref // empty' 2>/dev/null)
  hrepo=$(printf '%s' "$body" | jq -r '.head.repo.full_name // empty' 2>/dev/null)
  pbase=$(printf '%s' "$body" | jq -r '.base.ref // empty' 2>/dev/null)
  if [ "$rc" -ne 0 ] || [ -z "$ref" ]; then
    echo "gh-rest-shim: cannot read the head branch of #$num" >&2
    [ "$best" = 1 ] && return 0
    [ "$rc" -ne 0 ] && exit "$rc"
    exit 1
  fi
  if [ "${hrepo,,}" != "${slug,,}" ]; then
    echo "gh-rest-shim: skipped deleting the remote branch $ref of a pull request from ${hrepo:-a repo this answer does not name}, not $slug" >&2
    return 0
  fi
  kids=$( (gshim_api "repos/$slug/pulls?state=open&base=$(gshim_uri "$ref")&per_page=100") 2>/dev/null ) || kids=""
  n=$(printf '%s' "$kids" | jq -r 'if type=="array" then length else empty end' 2>/dev/null)
  case "${n:-x}" in
    ''|*[!0-9]*)
      echo "gh-rest-shim: kept the branch $ref — the open pull requests based on it could not be listed, and a delete would close them" >&2
      [ "$best" = 1 ] && return 0
      exit 1 ;;
  esac
  if [ "$n" -ge 100 ]; then
    echo "gh-rest-shim: kept the branch $ref — a full page of $n open pull requests is based on it and no second page was read" >&2
    [ "$best" = 1 ] && return 0
    exit 1
  fi
  if [ "$n" -gt 0 ] && [ "$best" != 1 ]; then
    echo "gh-rest-shim: kept the branch $ref — $n open pull request(s) are based on it, and #$num was closed, not merged" >&2
    return 0
  fi
  if [ "$n" -gt 0 ] && [ -z "$pbase" ]; then
    echo "gh-rest-shim: kept the branch $ref — #$num's own base did not read, so its stacked pull requests have nowhere to go" >&2
    return 0
  fi
  for kid in $(printf '%s' "$kids" | jq -r '.[].number // empty' 2>/dev/null); do
    ( gshim_api -X PATCH "repos/$slug/pulls/$kid" -f "base=$pbase" >/dev/null ) 2>/dev/null \
      || left="${left:+$left, }#$kid"
  done
  if [ -n "$left" ]; then
    echo "gh-rest-shim: kept the branch $ref — $left could not be retargeted to $pbase and a delete would close them" >&2
    return 0
  fi
  ( gshim_api -X DELETE "repos/$slug/git/refs/heads/$ref" >/dev/null ) || rc=$?
  [ "$rc" -eq 0 ] && return 0
  if [ "$best" = 1 ]; then
    echo "gh-rest-shim: the merged branch $ref was not deleted — best effort, the merge stands" >&2
    return 0
  fi
  exit "$rc"
}

# ── pr create ────────────────────────────────────────────────────────────────
gshim_cmd_pr_create() {
  gshim_prw_parse "--title:v:title -t:v:title --body:v:body -b:v:body \
--body-file:v:bodyfile -F:v:bodyfile --base:v:base -B:v:base --head:v:head -H:v:head \
--label:m:label -l:m:label --draft:b:draft -d:b:draft"
  gshim_slug ""
  local head="${GSHIM_PRW[head]:-}" base="${GSHIM_PRW[base]:-}" inp out url num
  if [ -z "$head" ]; then
    head=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || head=""
    # Detached HEAD has no branch name to push a PR from; `HEAD` as a head ref
    # is a 422 we would spend a request to earn. Let the real binary explain.
    [ -n "$head" ] && [ "$head" != "HEAD" ] || gshim_passthru "flag:--head"
  fi
  if [ -z "$base" ]; then
    base=$(gshim_api "repos/$GSHIM_SLUG" -q .default_branch) || exit $?
    base=$(printf '%s' "$base" | tr -d '\n')
    [ -n "$base" ] && [ "$base" != "null" ] || gshim_passthru "flag:--base"
  fi
  gshim_prw_body_init
  gshim_prw_str title "${GSHIM_PRW[title]:-}"
  gshim_prw_bodyfield body
  gshim_prw_str base "$base"
  gshim_prw_str head "$head"
  gshim_prw_json draft "$([ -n "${GSHIM_PRW[draft]:-}" ] && echo true || echo false)"
  inp=$(gshim_prw_build) || exit 1
  out=$(gshim_api -X POST "repos/$GSHIM_SLUG/pulls" --input "$inp") || exit $?
  url=$(printf '%s' "$out" | jq -r '.html_url // empty')
  num=$(printf '%s' "$out" | jq -r '.number // empty')
  printf '%s\n' "$url"
  if [ -n "${GSHIM_PRW[label]:-}" ] && [ -n "$num" ]; then
    # The PR exists and its URL is already on stdout: a label failure must not
    # swallow it. The subshell keeps gshim_api's own exit from ending the handler
    # before the warning is written.
    ( gshim_prw_labels_post "$GSHIM_SLUG" "$num" "${GSHIM_PRW[label]}" ) || {
      echo "gh-rest-shim: pull request created but the labels could not be applied" >&2
      exit 1
    }
  fi
  exit 0
}

# ── pr edit ──────────────────────────────────────────────────────────────────
gshim_cmd_pr_edit() {
  gshim_prw_parse "--add-label:m:add --remove-label:m:remove \
--title:v:title -t:v:title --body:v:body -b:v:body --body-file:v:bodyfile -F:v:bodyfile \
--base:v:base -B:v:base"
  gshim_slug "${GSHIM_PRW[pos]:-}"
  local inp name
  if [ -n "${GSHIM_PRW[add]:-}" ]; then
    gshim_prw_labels_post "$GSHIM_SLUG" "$GSHIM_NUM" "${GSHIM_PRW[add]}" || exit $?
  fi
  if [ -n "${GSHIM_PRW[remove]:-}" ]; then
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      gshim_api -X DELETE "repos/$GSHIM_SLUG/issues/$GSHIM_NUM/labels/$name" >/dev/null || exit $?
    done < <(printf '%s\n' "${GSHIM_PRW[remove]}" | tr ',' '\n')
  fi
  if [ -n "${GSHIM_PRW[title]:-}" ] || gshim_prw_has_body || [ -n "${GSHIM_PRW[base]:-}" ]; then
    gshim_prw_body_init
    [ -n "${GSHIM_PRW[title]:-}" ] && gshim_prw_str title "${GSHIM_PRW[title]}"
    gshim_prw_has_body && gshim_prw_bodyfield body
    [ -n "${GSHIM_PRW[base]:-}" ] && gshim_prw_str base "${GSHIM_PRW[base]}"
    inp=$(gshim_prw_build) || exit 1
    gshim_api -X PATCH "repos/$GSHIM_SLUG/pulls/$GSHIM_NUM" --input "$inp" >/dev/null || exit $?
  fi
  exit 0
}

# ── pr close ─────────────────────────────────────────────────────────────────
# Comment FIRST: a failed comment leaves the PR open, which is what gh does, and
# is the recoverable order — a closed PR with no explanation is not.
gshim_cmd_pr_close() {
  gshim_prw_parse "--comment:v:comment -c:v:comment --delete-branch:b:delbranch"
  gshim_slug "${GSHIM_PRW[pos]:-}"
  local inp
  if [ -n "${GSHIM_PRW[comment]:-}" ]; then
    gshim_prw_body_init
    gshim_prw_str body "${GSHIM_PRW[comment]}"
    inp=$(gshim_prw_build) || exit 1
    gshim_api -X POST "repos/$GSHIM_SLUG/issues/$GSHIM_NUM/comments" --input "$inp" >/dev/null || exit $?
  fi
  gshim_prw_body_init
  gshim_prw_str state closed
  inp=$(gshim_prw_build) || exit 1
  gshim_api -X PATCH "repos/$GSHIM_SLUG/pulls/$GSHIM_NUM" --input "$inp" >/dev/null || exit $?
  if [ -n "${GSHIM_PRW[delbranch]:-}" ]; then
    gshim_prw_delete_branch "$GSHIM_SLUG" "$GSHIM_NUM"
  fi
  exit 0
}

# ── pr reopen ────────────────────────────────────────────────────────────────
gshim_cmd_pr_reopen() {
  gshim_prw_parse ""
  gshim_slug "${GSHIM_PRW[pos]:-}"
  local inp
  gshim_prw_body_init
  gshim_prw_str state open
  inp=$(gshim_prw_build) || exit 1
  gshim_api -X PATCH "repos/$GSHIM_SLUG/pulls/$GSHIM_NUM" --input "$inp" >/dev/null || exit $?
  exit 0
}

# ── pr comment ───────────────────────────────────────────────────────────────
gshim_cmd_pr_comment() {
  gshim_prw_parse "--body:v:body -b:v:body --body-file:v:bodyfile -F:v:bodyfile"
  gshim_slug "${GSHIM_PRW[pos]:-}"
  local inp out
  gshim_prw_body_init
  gshim_prw_bodyfield body
  inp=$(gshim_prw_build) || exit 1
  out=$(gshim_api -X POST "repos/$GSHIM_SLUG/issues/$GSHIM_NUM/comments" --input "$inp") || exit $?
  printf '%s\n' "$(printf '%s' "$out" | jq -r '.html_url // empty')"
  exit 0
}

# ── pr review ────────────────────────────────────────────────────────────────
# Exactly one event flag, or the real binary gets the call: guessing an event is
# guessing whether a PR was approved.
gshim_cmd_pr_review() {
  gshim_prw_parse "--approve:b:approve -a:b:approve --comment:b:comment -c:b:comment \
--request-changes:b:changes -r:b:changes --body:v:body -b:v:body --body-file:v:bodyfile -F:v:bodyfile"
  gshim_slug "${GSHIM_PRW[pos]:-}"
  local event="" n=0 inp
  [ -n "${GSHIM_PRW[approve]:-}" ] && { event=APPROVE; n=$((n+1)); }
  [ -n "${GSHIM_PRW[comment]:-}" ] && { event=COMMENT; n=$((n+1)); }
  [ -n "${GSHIM_PRW[changes]:-}" ] && { event=REQUEST_CHANGES; n=$((n+1)); }
  [ "$n" -eq 1 ] || gshim_passthru "flag:review-event"
  gshim_prw_body_init
  gshim_prw_str event "$event"
  gshim_prw_has_body && gshim_prw_bodyfield body
  inp=$(gshim_prw_build) || exit 1
  gshim_api -X POST "repos/$GSHIM_SLUG/pulls/$GSHIM_NUM/reviews" --input "$inp" >/dev/null || exit $?
  exit 0
}

# ── pr diff ──────────────────────────────────────────────────────────────────
gshim_cmd_pr_diff() {
  gshim_prw_parse "--name-only:b:nameonly"
  gshim_slug "${GSHIM_PRW[pos]:-}"
  local out
  if [ -n "${GSHIM_PRW[nameonly]:-}" ]; then
    # 3000 is GitHub's own ceiling on /files; over GH_SHIM_MAX_PAGES pages
    # gshim_paginate errors loudly rather than returning a partial list.
    out=$(gshim_paginate "repos/$GSHIM_SLUG/pulls/$GSHIM_NUM/files" 3000) || exit $?
    printf '%s' "$out" | jq -r '.[].filename'
    exit 0
  fi
  gshim_api "repos/$GSHIM_SLUG/pulls/$GSHIM_NUM" -H "Accept: application/vnd.github.v3.diff" || exit $?
  exit 0
}

# ── pr merge ─────────────────────────────────────────────────────────────────
# One PUT. Default method is squash: gh would prompt for it, and a headless lane
# has nothing to answer with, while every fleet caller passes --squash anyway.
gshim_cmd_pr_merge() {
  gshim_prw_parse "--squash:b:squash -s:b:squash --rebase:b:rebase -r:b:rebase \
--merge:b:merge -m:b:merge --match-head-commit:v:sha --delete-branch:b:delbranch -d:b:delbranch \
--body:v:body -b:v:body --body-file:v:bodyfile -F:v:bodyfile --subject:v:subject -t:v:subject"
  gshim_slug "${GSHIM_PRW[pos]:-}"
  local method=squash wording="Squashed and merged" inp out title errf rc=0
  if [ -n "${GSHIM_PRW[rebase]:-}" ]; then method=rebase; wording="Rebased and merged"
  elif [ -n "${GSHIM_PRW[merge]:-}" ]; then method=merge; wording="Merged"
  fi
  gshim_prw_body_init
  gshim_prw_str merge_method "$method"
  [ -n "${GSHIM_PRW[sha]:-}" ] && gshim_prw_str sha "${GSHIM_PRW[sha]}"
  [ -n "${GSHIM_PRW[subject]:-}" ] && gshim_prw_str commit_title "${GSHIM_PRW[subject]}"
  gshim_prw_has_body && gshim_prw_bodyfield commit_message
  inp=$(gshim_prw_build) || exit 1
  errf=$(gshim_tmp) || { echo "gh-rest-shim: cannot create a temp file" >&2; exit 1; }
  out=$(gshim_api -X PUT "repos/$GSHIM_SLUG/pulls/$GSHIM_NUM/merge" --input "$inp" 2>"$errf") || rc=$?
  if [ "$rc" -ne 0 ]; then
    # A NATIVE MERGE QUEUE IS NOT THIS HANDLER'S BUSINESS (BH-892). Under
    # GitHub's own merge queue `gh pr merge` ENQUEUES and REST has no
    # equivalent, so bin/poll-commands.sh, bin/merge-sweep.sh,
    # bin/merge-queue.sh, bin/review-prs.sh and bin/run-build.sh all run
    # `gh pr merge` as the enqueue on those repos. GitHub answers the PUT 405
    # and that 405 WROTE NOTHING, so handing the original argv to the real
    # binary neither repeats a write nor changes what the caller asked for —
    # while translating it would leave the PR un-queued and read as a failed
    # merge. Every other refusal (409, 422, another 405) is GitHub's answer
    # ABOUT THIS MERGE and is never retried through a second path.
    grep -qiE 'merge[ _-]queue' "$errf" && gshim_passthru "merge-queue"
    cat "$errf" >&2
    exit "$rc"
  fi
  title=$(printf '%s' "$out" | jq -r '.title // empty' 2>/dev/null)
  if [ -z "$title" ]; then
    # The merge landed. A failed title read is cosmetic and must never turn a
    # merged PR into a non-zero exit (D9, in the direction that matters here).
    title=$( (gshim_api "repos/$GSHIM_SLUG/pulls/$GSHIM_NUM" -q '.title // ""') 2>/dev/null | tr -d '\n' )
  fi
  printf '✓ %s pull request #%s (%s)\n' "$wording" "$GSHIM_NUM" "$title"
  if [ -n "${GSHIM_PRW[delbranch]:-}" ]; then
    gshim_prw_delete_branch "$GSHIM_SLUG" "$GSHIM_NUM" 1
  fi
  exit 0
}
