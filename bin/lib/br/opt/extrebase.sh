#!/bin/bash
# shellcheck shell=bash
# bin/lib/br/opt/extrebase.sh — BH-4664.3 (BH-4670): rebase a dirty EXTERNAL PR.
#
# A quiet, trusted outsider's PR whose branch went `dirty` gets main merged INTO
# its branch through mc_rebase (a merge, never a history rewrite, pushed through
# hold_push with a lease on the head we read) — at most once per head sha, keyed
# on the `ext-rebase` pr_attempts row. Everything before this hook is
# external.sh's: br_opt_external_rung ran br_xpr_gate (open, knob on, push
# right, author quiet) and exported BR_XPR_HEAD BR_XPR_REF BR_XPR_SLUG BR_XPR_NUM.
#
# This file never closes, rebuilds, abandons or re-reviews the PR, writes no
# ALERTS line, and reads no ticket key. The only push is mc_rebase's.
#
# Functions only. Nothing runs on source (bin/lib/br/opt/README.md).

# _br_xpr_rebase_comment <url> <body> <tag> — one comment, one log line when it
#   did not post. No retry: the attempt row already stands for this head.
_br_xpr_rebase_comment() {
  br_pr_comment "$1" "$2" >/dev/null 2>&1 \
    || say "$3: comment not posted"
}

# br_xpr_rebase <p> <rkey> <reason> <url> <rec> <tkey> — rc 0 a rebase ran
#   (whatever mc_rebase answered), rc 3 nothing was done this tick.
br_xpr_rebase() {
  local p="$1" rkey="$2" url="$4" slug="${BR_XPR_SLUG:-}" num="${BR_XPR_NUM:-}" \
        head="${BR_XPR_HEAD:-}" ref="${BR_XPR_REF:-}" tag cs lk res src rc out body n f
  if [ -z "$slug" ] || [ -z "$num" ] || [ -z "$head" ] || [ -z "$ref" ]; then
    say "external-dirty $url: gate exported no head/ref — skipped"
    return 3
  fi
  tag="$p/$rkey [external-dirty] $slug#$num"
  if [ "${OBSERVE:-0}" = 1 ]; then
    say "$p/$rkey [external-dirty]: WOULD merge main into $ref at ${head:0:8} — observe mode"
    return 3
  fi
  # The conductor's row, when there is one, owns the rebase unless it is only
  # waiting on CI or already finished.
  cs=$(mc_row_field "$slug#$num" 2 2>/dev/null)
  case "$cs" in
    ''|WAIT_CI|MERGED|CLOSED|ABANDONED) ;;
    *) say "$tag: conductor holds $slug#$num in $cs — it owns the rebase"; return 3 ;;
  esac
  # Lock FIRST, then the attempt row, then the call (BH-4670 plan, R1): a lock
  # lost to the conductor spends nothing, and the row is written before the act.
  lk=$(mc_pr_lock "$p" "$num") || return 3
  res=$( ( flock -n 9 || exit 9
           a=0; pr_attempt_has "$slug" "$num" ext-rebase "$head" || a=$?
           if [ "$a" != 2 ]; then
             if [ "$a" = 0 ]; then say "$tag: already tried a rebase on ${head:0:8}"
             else say "$tag: pr_attempts unreadable (rc $a) — nothing done"; fi
             exit 10
           fi
           pr_attempt_put "$slug" "$num" ext-rebase "$head" >/dev/null 2>&1 || exit 11
           o=$(mc_rebase "$slug" "$p" "$ref" "$head" "$url"); r=$?
           printf '%s\n%s' "$r" "$o" ) 9>"$lk" ); src=$?
  case "$src" in
    0) ;;
    9) say "$tag: $slug#$num is locked by another lane — retried next tick"; return 3 ;;
    10) return 3 ;;
    11) say "$tag: could not write the ext-rebase attempt — nothing done"; return 3 ;;
    *) say "$tag: the rebase subshell answered rc $src — nothing known about the push"; return 3 ;;
  esac
  rc=${res%%$'\n'*}
  case "$res" in *$'\n'*) out=${res#*$'\n'} ;; *) out="" ;; esac
  case "$rc" in
    0|5)
      if [ -n "$out" ] && [ "$out" != "$head" ]; then
        say "$tag: merged main into $ref, ${head:0:8} -> ${out:0:8} (mc_rebase rc $rc)"
        _br_xpr_rebase_comment "$url" "Merged \`main\` into this branch (was \`${head:0:12}\`, now \`${out:0:12}\`). Your commits are untouched. The review lane looks at the new head next." "$tag"
      else
        say "$tag: nothing to merge at ${head:0:8} (mc_rebase rc $rc)"
      fi ;;
    1)
      say "$tag: merge conflicts at ${head:0:8} (mc_rebase rc 1)"
      body="We tried to merge \`main\` into this branch and hit conflicts in:"
      n=0
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        n=$((n+1))
        [ "$n" -le 20 ] && body="$body"$'\n'" - \`$f\`"
      done <<<"$out"
      [ "$n" -gt 20 ] && body="$body"$'\n'"…and $((n-20)) more"
      body="$body"$'\n\n'"Could you merge \`main\` in and push? We left the branch exactly as it was."
      _br_xpr_rebase_comment "$url" "$body" "$tag" ;;
    2)
      say "$tag: the merge went red on the repo's checks at ${head:0:8}, not pushed (mc_rebase rc 2)"
      _br_xpr_rebase_comment "$url" "We merged \`main\` into this branch locally, but the result went red on the repo's own checks, so we did not push it. The branch is unchanged." "$tag" ;;
    *)
      say "$tag: no push at ${head:0:8} (mc_rebase rc $rc: 3 lease/hold, 4 setup, 6 queued on pool, 7 pool unreachable, 8 tmp full)" ;;
  esac
  return 0
}
