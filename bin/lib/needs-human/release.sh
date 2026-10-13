# bin/lib/needs-human/release.sh — the release half of the needs-human hold
# (BH-3433, this slice BH-3446). Sourced, never executed. Once a person has
# cleared a NEEDS-HUMAN: hold on the issue, the next build's review prompt and
# PR body carry that person's evidence instead of re-blocking on the step.
#
#   nh_release_evidence <slug> <issue>
#     Reads the issue thread through gh_rest (REST, ETag-cached; paged 100 at a
#     time up to 1000 comments, the read style of hold_check_thread). The hold
#     is the NEWEST comment whose first line starts with NEEDS-HUMAN: (any
#     author: the placer is a Bot). The evidence is the newest NON-bot comment
#     after it whose first line starts with HUMAN-STEP-DONE:, or is a
#     "## Hub probe … PASS" header with no FAIL in it. "First line" is the
#     first non-blank line, CR and leading blanks stripped, so a comment that
#     only quotes or discusses the protocol mid-body never counts.
#     Prints "comment: <url>", "author: @<login> at <created_at>" and the
#     body's first 40 lines; rc 0. No hold or no release: nothing, rc 0.
#     Unreadable (bad slug/issue, no gh_rest, non-zero read, non-array page,
#     more than 1000 comments): nothing, rc 2 — never invented evidence.
#   nh_prompt_release_note <slug> <issue>
#     The review-prompt tail: a blank line, the release sentence, the evidence.
#     Nothing when there is no evidence. Always rc 0.
#   nh_pr_body_section <slug> <issue>
#     A "## Human step evidence" section quoting the evidence as a blockquote
#     (so a heading inside it cannot open a PR-body section). Nothing when
#     there is no evidence. Always rc 0.
# shellcheck shell=bash

# The whole thread as one JSON array on stdout; rc 2 when it cannot be read.
_nh_rel_thread() { # _nh_rel_thread <slug> <issue>
  local slug="${1:-}" n="${2:-}" t acc='[]' page len rc
  case "$slug" in */*) ;; *) return 2 ;; esac
  case "$n" in ''|*[!0-9]*) return 2 ;; esac
  command -v gh_rest >/dev/null 2>&1 || return 2
  t=$(mktemp "${TMPDIR:-/tmp}/nh-release.XXXXXX" 2>/dev/null) || return 2
  for page in 1 2 3 4 5 6 7 8 9 10; do
    rc=0; gh_rest GET "repos/$slug/issues/$n/comments?per_page=100&page=$page" > "$t" 2>/dev/null || rc=$?
    if [ "$rc" != 0 ] || ! jq -e 'type == "array"' "$t" >/dev/null 2>&1; then rm -f "$t"; return 2; fi
    acc=$(jq -sc '.[0] + .[1]' <(printf '%s\n' "$acc") "$t" 2>/dev/null) || { rm -f "$t"; return 2; }
    len=$(jq 'length' "$t")
    [ "$len" -lt 100 ] && break
    [ "$page" = 10 ] && { rm -f "$t"; return 2; }
  done
  rm -f "$t"
  printf '%s\n' "$acc"
}

nh_release_evidence() { # nh_release_evidence <slug> <issue>
  local thread
  thread=$(_nh_rel_thread "${1:-}" "${2:-}") || return 2
  # Oldest first, rebuilt from created_at (REST pages arrive in any order): a
  # non-ISO timestamp sorts OLDEST, and the REST index breaks same-second ties.
  printf '%s\n' "$thread" | jq -r --arg mark "${NH_MARKER_PREFIX:-NEEDS-HUMAN:}" --arg done "${NH_DONE_PREFIX:-HUMAN-STEP-DONE:}" '
    [ to_entries[] | select((.value | type) == "object")
      | ((.value.body // "") | tostring | gsub("\r"; "")) as $b
      | { b: $b, i: .key,
          at: ((.value.created_at // "") | tostring),
          url: ((.value.html_url // "") | tostring),
          who: (((.value.user // {}).login // "") | tostring),
          bot: ((((.value.user // {}).type // "") | tostring | ascii_downcase) == "bot"),
          first: ([ $b | split("\n")[] | sub("^[ \t]+"; "") | select(length > 0) ] | first // "") }
      | . + { k: (if (.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")) then .at else "" end) }
    ] | sort_by([.k, .i]) as $s
    | ([ range(0; $s | length) | select($s[.].first | startswith($mark)) ] | last) as $m
    | if $m == null then empty else
        [ $s[($m + 1):][] | select(.bot | not)
          | select((.first | startswith($done))
                   or ((.first | test("^##[ \t]+Hub probe\\b.*\\bPASS\\b")) and (.first | test("\\bFAIL\\b") | not))) ]
        | last // empty
        | "comment: \(.url)", "author: @\(.who) at \(.at)", (.b | split("\n") | .[:40][])
      end' 2>/dev/null || return 2
}

nh_prompt_release_note() { # nh_prompt_release_note <slug> <issue>
  local ev
  ev=$(nh_release_evidence "${1:-}" "${2:-}" 2>/dev/null) || return 0
  [ -n "$ev" ] || return 0
  printf '\n\nA person ran the human step; their evidence is below. Do not re-block on that finding; check the PR body quotes it.\n%s\n' "$ev"
}

nh_pr_body_section() { # nh_pr_body_section <slug> <issue>
  local ev url
  ev=$(nh_release_evidence "${1:-}" "${2:-}" 2>/dev/null) || return 0
  [ -n "$ev" ] || return 0
  url=$(sed -n '1s/^comment: //p' <<<"$ev")
  printf '\n## Human step evidence\n\nFrom %s:\n\n' "$url"
  sed '1d; s/^/> /; s/^> $/>/' <<<"$ev"
}
