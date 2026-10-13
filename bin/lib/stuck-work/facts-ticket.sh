# shellcheck shell=bash
# bin/lib/stuck-work/facts-ticket.sh — BH-3792 (BH-3781.3): the open-ticket fact
# reader. Sourced, never executed. Contract by BH-3789 (BH-3781.0).
#
#   swf_ticket_facts <repo> <open-pr-items-file>
#                         -> one FACTS line (kind ticket) per open `ai-build`
#                            issue, the format fixed in bin/lib/stuck-work/classify.sh
#   rc 0 = every line is complete, rc 3 = incomplete (the lines printed are
#   partial and the caller must not treat the set as whole; a failed list read
#   is rc 3 with nothing printed, as in facts-pr.sh), rc 1 = not wired (a bad
#   <repo>, or gh_rest / jq / seen.sh / hold.sh not loadable).
#
# What it reads, all GitHub REST through gh_rest (bin/lib/gh-rest.sh):
#   - repos/<repo>/issues?labels=ai-build&state=open, oldest first, 100 a page,
#     entries carrying `pull_request` dropped. Page 1 unreadable is rc 3 with
#     nothing printed; a later page unreadable, or STUCK_WORK_MAX_ITEMS (default
#     300) reached with more left, prints what was read and answers rc 3.
#   - issue_blocked: every `Blocked-by: #n` line in the body, spelled as
#     bin/launch-fastpath.sh spells it, each blocker's state read once per call.
#     1 = any blocker open, ? = none open but one unreadable, 0 otherwise.
#   - issue_hold: the thread (up to 10 pages) through hold_classify
#     (bin/lib/hold.sh), the fleet's one reading of a HOLD. 1 held, 0 clear,
#     ? unreadable.
#   - job_stage / job_stage_seen: ONE `job_rows running`, the first build row
#     whose ticket is <STUCK_WORK_KEY_PREFIX:-BH>-<n>; the anchor is
#     sw_first_seen "<job_id>|<stage>". No row is `-`; job_rows missing or
#     failing is `?` on every line, never `-`.
#   - open_pr: 1 when the key appears in the items file (not followed by a digit
#     or `.<digit>`, so BH-70 and BH-7.1 are not BH-7), 0 when not, ? when the
#     file cannot be read.
#   - first_seen: sw_first_seen "issue:<repo>#<n>|unlaunched".
# The only write is those ledger anchors (bin/lib/stuck-work/seen.sh), plus the
# thread cache below.
#
# BH-4660 (BH-4656.2), reads only on change:
#   - a blocker that is itself in this pass's open ai-build list is `open` with
#     no issues/<b> read; only a blocker absent from it is read.
#   - the thread is cached at state/stuck-work/thread/<owner_repo>-<n>.json (sorted
#     by created_at, then id) + .meta = <max updated_at>\t<full-read epoch>\t<last-read
#     epoch> (a two-field .meta reads last = full). With no cache, or a full read
#     STUCK_WORK_THREAD_FULL_S (1800; 0 = always) old or older, the whole thread
#     is read. Otherwise prs_wake_seen <repo> issue <n> <last read> at rc 1 reads
#     nothing; rc 0, rc 2 or no prs_wake_seen reads comments?since=<max updated_at>
#     and merges by id, the newer updated_at winning. A deleted comment is only
#     dropped by the next full read. A thread with a comment that has no numeric
#     id or no updated_at is never cached. SWF_COUNT_FILE gets THREAD-FULL|
#     THREAD-SINCE|THREAD-SKIP <n>.

swf_ticket_facts() {
  local repo="${1:-}" items="${2:-}" here tmp rc
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
  [ "$(type -t gh_rest)" = function ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  here=$(dirname "${BASH_SOURCE[0]}")
  if [ "$(type -t sw_first_seen)" != function ]; then . "$here/seen.sh" || return 1; fi
  if [ "$(type -t hold_classify)" != function ]; then . "$here/../hold.sh" || return 1; fi
  # _swf_state_dir / _swf_now / _swf_put / _swf_count live in facts-pr.sh.
  if [ "$(type -t _swf_state_dir)" != function ]; then . "$here/facts-pr.sh" || return 1; fi
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/swf-ticket.XXXXXX") || return 1
  _swf_ticket_run "$repo" "$items" "$tmp"; rc=$?
  rm -rf "$tmp"
  return "$rc"
}

_swf_ticket_run() {
  local repo=$1 items=$2 tmp=$3 cap=${STUCK_WORK_MAX_ITEMS:-300} pfx=${STUCK_WORK_KEY_PREFIX:-BH}
  local p=1 got n rc=0 jobs jobs_ok=1 cache=' ' line num url labels blockers key
  local b st blocked hold open_pr stage seen jrow jid
  [[ "$cap" =~ ^[0-9]+$ ]] && [ "$cap" -gt 0 ] || cap=300
  [[ "$pfx" =~ ^[A-Za-z]+$ ]] || pfx=BH
  # The list, page by page, until a short page, a failed page or the cap.
  : > "$tmp/list"
  while :; do
    if ! gh_rest GET "repos/$repo/issues?labels=ai-build&state=open&sort=created&direction=asc&per_page=100&page=$p" > "$tmp/page" \
       || ! jq -e 'type=="array"' "$tmp/page" >/dev/null 2>&1; then
      [ "$p" = 1 ] && return 3
      rc=3; break
    fi
    got=$(jq 'length' "$tmp/page")
    jq -c '.[] | select(type=="object" and .pull_request == null)' "$tmp/page" >> "$tmp/list"
    n=$(wc -l < "$tmp/list")
    if [ "$n" -ge "$cap" ]; then
      [ "$n" -gt "$cap" ] || [ "$got" -ge 100 ] && rc=3
      head -n "$cap" "$tmp/list" > "$tmp/capped" && mv "$tmp/capped" "$tmp/list"
      break
    fi
    [ "$got" -ge 100 ] || break
    p=$((p+1))
  done
  # A blocker in the open ai-build list just read is open: no read for it.
  cache=" $(jq -r '.number' "$tmp/list" 2>/dev/null | sed 's/$/=open/' | tr '\n' ' ')"
  # One read of the running jobs for the whole call.
  if [ "$(type -t job_rows)" = function ] && jobs=$(job_rows running); then :; else jobs_ok=0; fi
  while IFS= read -r line; do
    # \x1f, not tab: tab is IFS whitespace, so an empty field would collapse and
    # shift the ones after it into the wrong variables.
    IFS=$'\x1f' read -r num url labels blockers < <(printf '%s' "$line" | jq -r --arg br '^[\s>*_\-#]*blocked[- ]by\b(?<r>.*)$' '
      def clean: tostring | gsub("[\t\r\n]"; " ");
      (.number // "") as $n
      | [ ($n | tostring),
          ((.html_url // "") | clean | if . == "" then "?" else . end),
          ([ (.labels // [])[] | if type == "object" then (.name // "") else tostring end | clean ] | join(",") | if . == "" then "-" else . end),
          ([ ((.body // "") | tostring | split("\n")[] | sub("\r$"; ""))
             | (capture($br; "i") | .r) // empty | scan("#([0-9]+)")[] | tonumber
             | select(. != $n) ] | unique | map(tostring) | join(",") | if . == "" then "-" else . end)
        ] | join("\u001f")' 2>/dev/null)
    [[ "$num" =~ ^[0-9]+$ ]] || { rc=3; continue; }
    key="$pfx-$num"
    # issue_blocked
    blocked=0
    if [ "$blockers" != - ]; then
      for b in ${blockers//,/ }; do
        st=$(printf '%s' "$cache" | sed -n "s/.* $b=\([a-z?]*\) .*/\1/p")
        if [ -z "$st" ]; then
          # `> file`, never `$(gh_rest …)`: GH_REST_STATUS must survive (gh-rest-no-subshell-lint).
          st=""
          gh_rest GET "repos/$repo/issues/$b" > "$tmp/blk" 2>/dev/null \
            && st=$(jq -r '.state // empty' "$tmp/blk" 2>/dev/null)
          case "$st" in open|closed) ;; *) st='?' ;; esac
          cache="$cache$b=$st "
        fi
        case "$st" in open) blocked=1 ;; '?') [ "$blocked" = 1 ] || blocked='?' ;; esac
      done
    fi
    # issue_hold
    hold='?'
    if _swf_thread "$repo" "$num" "$tmp" "$tmp/thread"; then
      printf '%s' "$line" > "$tmp/issue"
      hold_classify "$tmp/issue" "$tmp/thread" >/dev/null
      case $? in 1) hold=1 ;; 0) hold=0 ;; esac
    fi
    # job_stage / job_stage_seen
    if [ "$jobs_ok" = 0 ]; then
      stage='?'; seen='?'
    else
      jrow=$(printf '%s\n' "$jobs" | awk -F'\t' -v k="$key" '$3 == "build" && toupper($6) == toupper(k) { print $1 "\t" $4; exit }')
      if [ -z "$jrow" ]; then
        stage=-; seen=-
      else
        jid=${jrow%%$'\t'*}; stage=${jrow#*$'\t'}
        stage=${stage//[[:space:]]/}
        if [ -z "$stage" ] || [ -z "$jid" ]; then stage=${stage:-?}; seen='?'
        else seen=$(sw_first_seen "$jid|$stage"); fi
      fi
    fi
    # open_pr
    if [ -n "$items" ] && [ -f "$items" ] && [ -r "$items" ]; then
      if grep -Eiq "(^|[^[:alnum:]])$key([^[:alnum:].]|\.([^0-9]|\$)|\$)" "$items"; then open_pr=1; else open_pr=0; fi
    else
      open_pr='?'
    fi
    printf 'ticket\t%s#%s\t%s\t-\t%s\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$repo" "$num" "$url" "$labels" "$stage" "$seen" "$blocked" "$hold" "$open_pr" \
      "$(sw_first_seen "issue:$repo#$num|unlaunched")"
  done < "$tmp/list"
  return "$rc"
}

# _swf_pages <repo> <num> <query> <tmp> — comments?<query>per_page=100, page by
#   page (at most 10), as one array in <tmp>/pages. rc 1 = a page unreadable or
#   the thread longer than 10 pages.
_swf_pages() {
  local c=1 cp
  : > "$4/c"
  while [ "$c" -le 10 ]; do
    gh_rest GET "repos/$1/issues/$2/comments?$3per_page=100&page=$c" > "$4/cp" \
      && jq -e 'type=="array"' "$4/cp" >/dev/null 2>&1 || return 1
    cat "$4/cp" >> "$4/c"
    cp=$(jq 'length' "$4/cp")
    if [ "$cp" -lt 100 ]; then jq -s 'add // []' "$4/c" > "$4/pages" 2>/dev/null; return; fi
    c=$((c+1))
  done
  return 1
}

# _swf_thread <repo> <num> <tmp> <out> — the whole thread as one array in <out>;
#   rc 1 = unreadable, never the cache instead. See the header for the rules.
_swf_thread() {
  local repo=$1 num=$2 tmp=$3 out=$4 f="" full=${STUCK_WORK_THREAD_FULL_S:-1800} now since="" fe="" le="" wrc=2 d
  now=$(_swf_now)
  [[ "$full" =~ ^[0-9]+$ ]] || full=1800
  full=$((10#$full))
  d=$(_swf_state_dir thread) && f="$d/${repo/\//_}-$num"
  if [ -n "$f" ] && [ "$full" -gt 0 ] && [ -r "$f.json" ] && [ -r "$f.meta" ]; then
    IFS=$'\t' read -r since fe le < "$f.meta"
    [ -n "$le" ] || le=$fe
    if [[ "$since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] && [[ "$fe" =~ ^[0-9]+$ ]] && [[ "$le" =~ ^[0-9]+$ ]] \
       && [ $((now - 10#$fe)) -ge 0 ] && [ $((now - 10#$fe)) -lt "$full" ] && jq -e 'type=="array"' "$f.json" >/dev/null 2>&1; then
      [ "$(type -t prs_wake_seen)" = function ] && { wrc=0; prs_wake_seen "$repo" issue "$num" "$le" || wrc=$?; }
      if [ "$wrc" = 1 ]; then
        _swf_count THREAD-SKIP "$num"
        cp "$f.json" "$out"; return
      fi
      _swf_count THREAD-SINCE "$num"
      _swf_pages "$repo" "$num" "since=$since&" "$tmp" || return 1
      # Merged by id, so a fresh comment with no numeric id goes to a full read.
      if jq -e 'all(.[]; (.id | type) == "number")' "$tmp/pages" >/dev/null 2>&1; then
        jq -s '(.[0] + .[1]) | group_by(.id) | map(max_by(.updated_at)) | sort_by(.created_at, .id)' "$f.json" "$tmp/pages" > "$out" 2>/dev/null || return 1
        _swf_thread_put "$f" "$out" "$fe" "$now"
        return 0
      fi
    fi
  fi
  _swf_count THREAD-FULL "$num"
  _swf_pages "$repo" "$num" "" "$tmp" || return 1
  cp "$tmp/pages" "$out" || return 1
  [ -n "$f" ] && jq 'sort_by(.created_at, .id)' "$out" > "$tmp/sorted" 2>/dev/null && _swf_thread_put "$f" "$tmp/sorted" "$now" "$now"
  return 0
}

# _swf_thread_put <base> <array-file> <full epoch> <now> — the cache pair, .json
#   first; nothing when a comment has no numeric id or no updated_at.
_swf_thread_put() {
  local max
  max=$(jq -er 'if all(.[]; (.id | type) == "number" and ((.updated_at // "") | type) == "string" and (.updated_at // "") != "")
    then (map(.updated_at) | max // "1970-01-01T00:00:00Z") else error("uncacheable") end' "$2" 2>/dev/null) || return 0
  _swf_put "$1.json" < "$2"
  printf '%s\t%s\t%s\n' "$max" "$3" "$4" | _swf_put "$1.meta"
}
