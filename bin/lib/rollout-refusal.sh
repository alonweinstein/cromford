#!/bin/bash
# shellcheck shell=bash
# bin/lib/rollout-refusal.sh — tell the author why their rollout was refused,
# once per reason, and park the master (BH-4061).
#
# bin/run-rollout.sh used to write `ROLLOUT_FAILED <reason>` into the build dir
# and stop. Nobody on the ticket saw the reason, and the master kept its
# `ai-build` label, so every tick rebuilt it into the same refusal (#3966 and
# #3979 were rebuilt about 12 times on 2026-10-03 and never filed a child).
#
# ONE PUBLIC FUNCTION, rollout_refusal_notify <slug> <issue> <build-dir> <reason>.
# run-rollout.sh calls it only from its PARSE-refusal arm (a body shape the
# author can fix) and only on the GitHub-Issues lane, after the RESULT line is
# written. Nothing here changes that RESULT, and every failure is an fc_log line
# with rc 0: a refusal that could not be announced is still the same refusal.
#
# THE THREAD IS THE DEDUP STORE. The comment's first line is a hidden marker,
# `<!-- rollout-refusal:<fp> -->`, fp = sha256("<slug>/<issue>/<reason>")[:16].
# The build runs on a pool machine whose disk does not survive, and the comment
# is its own record, so "marked posted without posting" cannot happen. A thread
# that could not be read to the end is UNKNOWN, never "no marker": nothing is
# posted or parked, because a duplicate on a client's thread cannot be undone
# (the same rule bin/lib/fc-issues.sh follows for the split comment).
#
# PARKING IS THE LABEL, as for a filed rollout, and it happens only once the
# marker is on the thread (posted now, or found from an earlier tick). A failed
# unlabel is a WARN, and the next tick finds the marker and retries the unlabel
# alone.
#
# Needs fc_log/fc_dry (bin/lib/file-children.sh, which run-rollout.sh sources)
# and gh_rest/gh_rest_comment/fc_unlabel_parent, which come from
# bin/lib/fc-issues.sh beside this file the first time they are needed.

# _rr_fix <reason> — one line telling the author what to change in the body.
_rr_fix() {
  case "${1:-}" in
    "unknown dependency"*)
      printf '%s' 'Every name on an `after:` line has to match the title of an earlier wave, written the way it appears after `### Wave:` (case does not matter). Fix the spelling, or add the wave it names.' ;;
    "comma in wave title"*)
      printf '%s' '`after:` splits names on commas, so no wave title can contain a comma while any wave has an `after:` line. Take the comma out of the title.' ;;
    "self dependency"*)
      printf '%s' 'A wave names itself on its own `after:` line. Remove that name.' ;;
    "forward dependency"*)
      printf '%s' 'An `after:` line names a wave that comes later in the list. A wave can only wait on waves above it, so reorder the waves or drop that name.' ;;
    "duplicate title"*)
      printf '%s' 'Two waves have the same title. Give each one its own.' ;;
    "empty title"*)
      printf '%s' 'A wave heading has no title. Write one after `### Wave:`.' ;;
    "too few waves"*|"no waves"*)
      printf '%s' 'A rollout needs 2 to 12 waves, each under its own `### Wave: <title>` heading inside the `## Rollout` section.' ;;
    "too many waves"*)
      printf '%s' 'A rollout holds at most 12 waves. Merge some of them, or split the work across two masters.' ;;
    "nested rollout"*|"duplicate rollout section"*)
      printf '%s' 'The body can have only one `## Rollout` heading. Remove the extra one.' ;;
    "unterminated code block"*)
      printf '%s' 'A code fence or a `<pre>`/`<code>` block is never closed, so everything after it would read as one wave. Close it.' ;;
    "mid-line heading tag"*)
      printf '%s' 'An `<h2>` or `<h3>` tag sits in the middle of a line inside the rollout. Put each heading on a line of its own.' ;;
    "indented after: line"*|"empty after: list"*|"empty after: name"*)
      printf '%s' 'The `after:` line has to be the first line of the wave body, not indented, written as `after: <title>, <title>` with no empty names.' ;;
    *)
      printf '%s' 'The body format is in the Rollout section of `skills/harness/SKILL.md`.' ;;
  esac
}

# _rr_fp <text> — the first 16 hex of its sha256, or nothing.
_rr_fp() {
  local h=""
  if command -v sha256sum >/dev/null 2>&1; then h=$(printf '%s' "$1" | sha256sum 2>/dev/null)
  elif command -v shasum >/dev/null 2>&1; then h=$(printf '%s' "$1" | shasum -a 256 2>/dev/null); fi
  h="${h%% *}"
  case "$h" in *[!0-9a-f]*|'') return 1 ;; esac
  printf '%s' "${h:0:16}"
}

# _rr_marker_seen <slug> <issue> <marker> — 0 found, 1 not on the thread,
# 2 could not tell (a page read failed, or 10 full pages).
_rr_marker_seen() {
  local slug="$1" num="$2" marker="$3" t k=1 rc n
  t=$(mktemp "${TMPDIR:-/tmp}/rr-comments.XXXXXX") || return 2
  while [ "$k" -le 10 ]; do
    rc=0
    gh_rest GET "repos/$slug/issues/$num/comments?per_page=100&page=$k" > "$t" 2>/dev/null || rc=$?
    if [ "$rc" != 0 ]; then rm -f "$t"; return 2; fi
    n=$(jq 'length' "$t" 2>/dev/null)
    case "${n:-}" in ''|*[!0-9]*) rm -f "$t"; return 2 ;; esac
    if jq -r '.[]?.body // empty' "$t" 2>/dev/null | grep -qF "$marker"; then rm -f "$t"; return 0; fi
    if [ "$n" -lt 100 ]; then rm -f "$t"; return 1; fi
    k=$((k + 1))
  done
  rm -f "$t"
  return 2
}

rollout_refusal_notify() {
  local slug="${1:-}" num="${2:-}" build="${3:-}" reason="${4:-}" fp marker file seen rc
  [ -n "$slug" ] && [ -n "$num" ] && [ -n "$build" ] && [ -n "$reason" ] || return 0
  if ! command -v fc_unlabel_parent >/dev/null 2>&1; then
    # shellcheck source=bin/lib/fc-issues.sh
    . "$(dirname "${BASH_SOURCE[0]}")/fc-issues.sh" 2>/dev/null || true
  fi
  if ! command -v gh_rest >/dev/null 2>&1 || ! command -v gh_rest_comment >/dev/null 2>&1 \
     || ! command -v fc_unlabel_parent >/dev/null 2>&1; then
    fc_log "$build" "ROLLOUT_REFUSAL_UNKNOWN #$num: the gh REST helpers are not on this box, so the refusal was not posted"
    return 0
  fi
  if ! fp=$(_rr_fp "$slug/$num/$reason"); then
    fc_log "$build" "ROLLOUT_REFUSAL_UNKNOWN #$num: no sha256 tool, so the refusal was not posted"
    return 0
  fi
  marker="<!-- rollout-refusal:$fp -->"
  file="$build/rollout-refusal-comment.md"
  {
    printf '%s\n' "$marker"
    printf 'We did not file the waves for this rollout. The parser stopped on this:\n\n'
    printf '> %s\n\n' "$reason"
    printf '%s\n\n' "$(_rr_fix "$reason")"
    printf 'Once the body is fixed, put the `ai-build` label back on and we will pick it up again.\n'
  } > "$file" 2>/dev/null || { fc_log "$build" "WARN: could not write $file, refusal not posted on #$num"; return 0; }

  if fc_dry; then
    printf 'gh api -X POST repos/%s/issues/%s/comments -F body=@%s\n' "$slug" "$num" "$file" >> "$build/decompose-gh.log"
    printf 'gh api -X DELETE repos/%s/issues/%s/labels/ai-build\n' "$slug" "$num" >> "$build/decompose-gh.log"
    fc_log "$build" "ROLLOUT_REFUSAL_DRYRUN #$num: comment and unlabel written to decompose-gh.log, nothing sent"
    return 0
  fi

  command -v gh_fresh >/dev/null 2>&1 && gh_fresh
  seen=0; _rr_marker_seen "$slug" "$num" "$marker" || seen=$?
  case "$seen" in
    0) fc_log "$build" "ROLLOUT_REFUSAL_SEEN #$num: this reason is already on the thread, not reposted" ;;
    1)
      printf 'gh api -X POST repos/%s/issues/%s/comments -F body=@%s\n' "$slug" "$num" "$file" >> "$build/decompose-gh.log"
      if ! gh_rest_comment "$slug" "$num" "$file" >/dev/null 2>&1; then
        fc_log "$build" "WARN: the rollout refusal comment did not post on #$num; ai-build left on, the next tick retries"
        return 0
      fi
      fc_log "$build" "ROLLOUT_REFUSAL_POSTED #$num ($fp)" ;;
    *)
      fc_log "$build" "ROLLOUT_REFUSAL_UNKNOWN #$num: the comment list could not be read to the end, so nothing was posted or unlabelled"
      return 0 ;;
  esac

  printf 'gh api -X DELETE repos/%s/issues/%s/labels/ai-build\n' "$slug" "$num" >> "$build/decompose-gh.log"
  rc=0; fc_unlabel_parent "$slug" "$num" || rc=$?
  case "$rc" in
    0)  fc_log "$build" "parent #$num unlabelled (refused rollout)" ;;
    44) fc_log "$build" "parent #$num was not labelled ai-build (refused rollout)" ;;
    *)  fc_log "$build" "WARN: could not remove the ai-build label from #$num after the refusal; the next tick retries the unlabel" ;;
  esac
  return 0
}
