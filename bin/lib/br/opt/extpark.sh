#!/bin/bash
# shellcheck shell=bash
# bin/lib/br/opt/extpark.sh — BH-4664.2 (BH-4669): EXTERNAL PRs, hand back to
# the author.
#
# The two hooks bin/lib/br/opt/external.sh and the lane's terminal guards call:
#
#   br_xpr_nopush   the gate found no push right on the head repo
#   br_xpr_terminal the ladder reached a terminal on an external PR
#
# Each tells the author ONCE PER HEAD, and the pr_attempts row (ext-nopush /
# ext-park, keyed on the head) is written BEFORE the comment: a failed put posts
# nothing, an outage is never read as a miss, and a comment that failed after
# its put deletes the row so the next tick retries. Nothing here closes a PR,
# enqueues a rebuild, records ABANDONED or writes an ALERTS line.
#
# The PR's token is the one br_one already holds for the row (the gate reads
# the same way); this file never switches or resets it.
#
# Functions only. Nothing runs on source (bin/lib/br/opt/README.md).

# br_xpr_pr_read <url> -> "state<US>head<US>login<US>slug<US>num", or rc 1.
#   Always a fresh read, never BR_XPR_HEAD: a fix round may have just moved the
#   head, and the hand-back binds to the head the author holds now. A failed
#   read, a non-object body or an empty head/login is rc 1 (D11): an unreadable
#   PR is never "the author".
br_xpr_pr_read() {
  local url="$1" slug num f rc st head login
  slug=$(br_slug_of_url "$url") || return 1
  num=$(mc_num_of_url "$url"); [ -n "$num" ] || return 1
  f=$(mktemp "${TMPDIR:-/tmp}/br-xpr.XXXXXX") || return 1
  rc=0; gh_rest GET "repos/$slug/pulls/$num" > "$f" 2>/dev/null || rc=$?
  if [ "$rc" != 0 ] || ! jq -e 'type == "object"' "$f" >/dev/null 2>&1; then rm -f "$f"; return 1; fi
  IFS=$'\x1f' read -r st head login < <(jq -r '[(.state // ""), (.head.sha // ""), (.user.login // "")]
      | join("\u001f")' "$f" 2>/dev/null)
  rm -f "$f"
  [ -n "${head:-}" ] && [ -n "${login:-}" ] || return 1
  printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "${st:-}" "$head" "$login" "$slug" "$num"
}

# br_xpr_has_ledger — rc 0 when this box can read and write pr_attempts.
br_xpr_has_ledger() {
  command -v pr_attempt_has >/dev/null 2>&1 && command -v pr_attempt_put >/dev/null 2>&1
}

# br_xpr_nopush <p> <url> — rc 0 always (the gate ignores it and returns 3).
br_xpr_nopush() {
  local p="$1" url="$2" slug num st head login rs rn rc body
  slug=$(br_slug_of_url "$url" 2>/dev/null) || slug="$url"
  num=$(mc_num_of_url "$url" 2>/dev/null)
  if ! br_xpr_has_ledger; then
    say "external $slug#$num: no attempts ledger on this box — the author is not told, retried next tick"
    return 0
  fi
  if ! IFS=$'\x1f' read -r st head login rs rn < <(br_xpr_pr_read "$url") || [ -z "${head:-}" ]; then
    say "external $slug#$num: the PR would not read — the author is not told, retried next tick"
    return 0
  fi
  slug="$rs"; num="$rn"
  rc=0; pr_attempt_has "$slug" "$num" ext-nopush "$head" || rc=$?
  case "$rc" in
    0) say "external $slug#$num: already told the author on ${head:0:12} — no push right"; return 0 ;;
    2) ;;
    *) say "external $slug#$num: the attempts ledger would not read (rc $rc) — the author is not told, retried next tick"
       return 0 ;;
  esac
  if ! pr_attempt_put "$slug" "$num" ext-nopush "$head"; then
    say "external $slug#$num: the ext-nopush row on ${head:0:12} was not written — the author is not told, retried next tick"
    return 0
  fi
  body="The harness can't push to this branch (it's a fork with maintainer edits turned off), so this one is yours. The review above lists what to change."
  if br_pr_comment "$url" "$body"; then
    say "external $slug#$num: told @$login on ${head:0:12} — no push right, left for the author"
    return 0
  fi
  br_xpr_release "$slug" "$num" ext-nopush "$head"
  return 0
}

# br_xpr_release <slug> <num> <kind> <head> — a comment failed after its put:
#   forget the row so the next tick retries; one honest line when that fails too.
br_xpr_release() {
  local rc=0
  if command -v pr_attempt_del >/dev/null 2>&1; then pr_attempt_del "$1" "$2" "$3" "$4" || rc=$?; else rc=1; fi
  case "$rc" in
    0|2) say "external $1#$2: the comment did not post — the $3 row on ${4:0:12} was released, retried next tick" ;;
    *)   say "external $1#$2: told nobody, and the $3 row on ${4:0:12} could not be released — this head stays silent" ;;
  esac
}

# br_xpr_terminal <p> <rkey|cap-key> <reason> <url> <rec> ... — the terminal's
#   rc. Keyed on $2 as given: br_abandon passes the cap key there and a "why"
#   sentence in $6, so $6 is never read. Below the review cap: rc 0 with
#   BR_XPR_PARKED set, the PR waits for the next head. At or over it: one
#   hand-back per head, then rc 3 with BR_XPR_PARKED set. Either way br_one
#   spends no PER_TICK slot and releases no conductor park.
br_xpr_terminal() {
  local p="$1" k="$2" reason="${3:-}" url="${4:--}" st n cap pst head login slug num rc body
  st=$(br_load "$p" "$k")
  n=$(br_num "$st" fixrounds)
  n=$(br_cap_rows "$p" "$k" review-changes-requested "$n" "$url" fixround fixrounds)
  cap=$(br_fix_cap "$st" review-changes-requested 2>/dev/null)
  case "$cap" in ''|*[!0-9]*) cap="${BR_REVIEW_FIX_ROUNDS:-2}" ;; esac
  if [ "$n" -lt "$cap" ]; then
    # PARKED, rc 0 (review of 7239e2ec). br_one reads BR_XPR_PARKED, not the
    # rc: unparked, this wait spent a PER_TICK slot and released the conductor's
    # park every tick. br_rebuild_fresh's direct callers reach here with no
    # round run, so fixrounds never grows on that path.
    br_xpr_parked "$p/$k [$reason]: external PR $url — round $n of $cap spent; waits for the next head, nothing closed"
    return 0
  fi
  if ! IFS=$'\x1f' read -r pst head login slug num < <(br_xpr_pr_read "$url") || [ -z "${head:-}" ]; then
    br_xpr_parked "$p/$k [$reason]: external PR $url — the PR would not read — nothing posted, retried next tick"
    return 3
  fi
  if [ "$pst" != open ]; then
    br_xpr_parked "$p/$k [$reason]: external PR $url is $pst, nothing to hand back"; return 3
  fi
  if ! br_xpr_has_ledger; then
    br_xpr_parked "external $slug#$num: no attempts ledger on this box — the author is not told, retried next tick"
    return 3
  fi
  rc=0; pr_attempt_has "$slug" "$num" ext-park "$head" || rc=$?
  case "$rc" in
    0) br_xpr_parked "$p/$k [$reason]: external PR $url — already handed to @$login on ${head:0:12}"; return 3 ;;
    2) ;;
    *) br_xpr_parked "$p/$k [$reason]: external PR $url — the attempts ledger would not read (rc $rc), nothing posted, retried next tick"
       return 3 ;;
  esac
  if ! pr_attempt_put "$slug" "$num" ext-park "$head"; then
    br_xpr_parked "$p/$k [$reason]: external PR $url — the ext-park row on ${head:0:12} was not written, nothing posted, retried next tick"
    return 3
  fi
  body="Over to you, @$login. The harness ran $n fix round(s) on this PR and the review still asks for changes, so it is stopping here and won't push to this head again. The review above lists what's left. Push a new commit when you're ready and it gets a fresh review."
  if ! br_pr_comment "$url" "$body"; then
    br_xpr_release "$slug" "$num" ext-park "$head"
    br_xpr_parked "$p/$k [$reason]: external PR $url — the hand-back did not post, nothing recorded"
    return 3
  fi
  br_record "$p" "$k" external-parked "$reason" \
      "handed back to @$login on ${head:0:12} after $n of $cap fix round(s)" "" "$url" "$head" \
    || say "$p/$k [$reason]: the external-parked attempt was not recorded — the ext-park row stands, nothing reposted"
  br_xpr_parked "$p/$k [$reason]: external PR $url — handed back to @$login on ${head:0:12} after $n of $cap fix round(s)"
  return 3
}
