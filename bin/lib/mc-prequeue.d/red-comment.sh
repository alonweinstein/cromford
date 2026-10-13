#!/bin/bash
# gh-identity: app-token
# bin/lib/mc-prequeue.d/red-comment.sh — THE INVARIANT RED POSTS ITS EVIDENCE
# (BH-5439, #5429). Sourced by bin/lib/mc-prequeue.sh's hook loop, never
# executed; no side effect at source time.
#
# pq_red_comment <slug> <num> <url> <head> <main> <path> posts ONE PR comment
# for an invariant red: each failing id with its suite from the hub's
# catalog/prequeue-invariants.tsv, its first FAIL lines from <path>.fail
# (written by pq_read_run), a repro command and the marker
# `<!-- prequeue-invariant:<head>:<main> -->`. The conductor calls it once per
# (PR, head, main), inside its `pqred` attempt row, so a failed POST is never
# retried. Every outcome is one mc_log line, and the rc is always 0: the park
# never depends on the comment.
pq_red_comment() {
  local slug="$1" num="$2" head="$4" main="$5" path="$6" tmp id suite ids="" n=0 rc=0 l i
  local -a idl=() lines=()
  [ -s "$path.fail" ] || { mc_log "$slug#$num prequeue: invariant red with no fail lines, no comment"; return 0; }
  while IFS= read -r l; do
    case "$l" in
      "### "*) idl+=("${l#\#\#\# }"); lines+=("") ;;
      *) [ "${#idl[@]}" -gt 0 ] && [ -n "$l" ] && lines[${#lines[@]}-1]+="$l"$'\n' ;;
    esac
  done < "$path.fail"
  n=${#idl[@]}
  [ "$n" -gt 0 ] || { mc_log "$slug#$num prequeue: invariant red with no fail lines, no comment"; return 0; }
  tmp=$(mktemp "${TMPDIR:-/tmp}/mc-pq-comment.XXXXXX" 2>/dev/null) \
    || { mc_log "$slug#$num prequeue invariant comment NOT posted for ${head:0:8} on main ${main:0:12}: no temp file"; return 0; }
  {
    printf 'We parked this PR before the merge queue. Head %s merged onto main %s fails %s whole-repo invariant suite%s.\n' \
      "${head:0:8}" "${main:0:12}" "$n" "$([ "$n" = 1 ] || echo s)"
    for i in "${!idl[@]}"; do
      id="${idl[$i]}"
      suite=$(awk -F'\t' -v id="$id" '!/^#/ && $1 == id { split($3, a, " "); print a[1]; exit }' "${MC_H:-}/catalog/prequeue-invariants.tsv" 2>/dev/null)
      if [ -n "$suite" ]; then printf '\n**%s** (`%s`)\n' "$id" "$suite"
      else printf '\n**%s** (no catalog row on the hub for %s)\n' "$id" "$id"; fi
      printf '```text\n%s```\n' "${lines[$i]}"
      [ -n "$suite" ] && printf 'To reproduce: `git merge origin/main && HARNESS_TEST_SANDBOX=1 bash %s`\n' "$suite"
      ids="$ids${ids:+,}$id"
    done
    printf '\n<!-- prequeue-invariant:%s:%s -->\n' "$head" "$main"
  } > "$tmp"
  mc_use_token "$slug"
  gh_rest POST "repos/$slug/issues/$num/comments" -F "body=@$tmp" >/dev/null || rc=$?
  rm -f "$tmp"
  if [ "$rc" = 0 ]; then mc_log "$slug#$num prequeue invariant comment posted for ${head:0:8} on main ${main:0:12}: $ids"
  else mc_log "$slug#$num prequeue invariant comment NOT posted for ${head:0:8} on main ${main:0:12} (rc $rc, HTTP ${GH_REST_STATUS:-000}), no retry: $ids"; fi
  return 0
}
