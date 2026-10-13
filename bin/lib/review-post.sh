#!/bin/bash
# bin/lib/review-post.sh — the review a lane posts must carry its own findings,
# and the build record must hold a copy BEFORE the network call.
#
# WHY THIS EXISTS (BH-641). Every lane in this harness that posts a review to a
# PR used to publish the agent's stdout file verbatim and check nothing about
# it: `gh pr comment "$url" --body "$(cat "$outf")" || true`. A head-bound
# re-review BLOCKed a PR with a comment that said "finding #1 is a fail-open
# authz check, finding #2 weakens a test, finding #3 is scope creep" and carried
# none of those three findings. Nothing else kept the review — the out file
# lives under state/, the resolver's is a mktemp — so the only copy of that
# adjudication was the comment that had already dropped it, and the fix round
# briefed from that comment had nothing to work from.
#
# Three rules, and they are the whole lib:
#   1. COUNT WHAT YOU POST. The findings a review carries are counted against
#      the highest `finding #N` its verdict text references. Equal or more is a
#      complete render; fewer FAILS CLOSED to a PARSE_INCOMPLETE body carrying
#      the raw review and the raw agent envelope, because a body that looks
#      clean while missing a finding is worse than an ugly one that says so.
#   2. PERSIST BEFORE YOU POST. rp_persist writes the review and the envelope
#      into the build record first. A machine that dies between the two leaves
#      the review on disk; the old order left nothing anywhere.
#   3. A MISSING RECORD NEVER COSTS THE COMMENT. rp_persist answers rc 1 and the
#      caller still posts — losing the comment to an absent record would be the
#      same evidence loss in reverse (cromford#630).
#
# Sourced, never executed. No side effects on source.
#
# NAME PREFIX: bin/lib/review-provenance.sh also uses rp_ (rp_is_claude,
# rp_out_is_claude…). The two libs are often sourced into the same shell; the
# names here are disjoint from those and must stay that way.

# GitHub refuses a comment body over 65536 chars, so both raw fences and the
# verbatim review are capped and the cap SAYS where the full copy is.
# RP_RAW_CAP (each raw fence) and RP_TEXT_CAP (the verbatim review) are registry
# knobs since BH-1940, resolved by _rp_knobs below.
# The verdict every body leads with is read by the ONE shared reader
# (bin/lib/verdict-parse.sh, BH-1625), so the comment and the merge gate can
# never disagree about what the review said.
command -v verdict_parse >/dev/null 2>&1 \
  || { [ -r "${BASH_SOURCE[0]%/*}/verdict-parse.sh" ] && . "${BASH_SOURCE[0]%/*}/verdict-parse.sh"; }

# _rp_knobs — the two caps into $_RP_RAW / $_RP_TEXT (BH-1940,
#   catalog/lanes.d/_lib.review-post.json). Order: operator row > cached row >
#   env > registry default, through lane-gate.sh's lib_env_apply in a subshell,
#   so its fail-closed exit 75 writes its one ALERTS line and cannot end the lane.
#   Then the default in THIS checkout's own registry file, the one source a
#   scratch tree with no rendered registry still has (verdict_window's
#   precedent). Neither is a literal. If both are empty the cap is left empty
#   and rp_cap's own positional default applies. Once per process per env value.
_RP_LIB="${BASH_SOURCE[0]%/*}"
_RP_KEY="none"; _RP_RAW=""; _RP_TEXT=""
_rp_digits() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; return 0; }
# _rp_default <ENV> — the knob's default in this checkout's registry file, or nothing.
_rp_default() {
  local v
  v=$(jq -r --arg e "$1" '.libs[]? | select(.id == "review-post") | .knobs[]?
                          | select(.env == $e) | .default // empty' \
        "$_RP_LIB/../../catalog/lanes.d/_lib.review-post.json" 2>/dev/null)
  _rp_digits "$v" && printf '%s' "$v"
  return 0
}
_rp_knobs() {
  local k="${RP_RAW_CAP-}|${RP_RAW_CAP+set}|${RP_TEXT_CAP-}|${RP_TEXT_CAP+set}" r
  [ "$k" = "$_RP_KEY" ] && return 0
  _RP_KEY="$k"
  r=$(
    lg="${HARNESS:-${H:-/root/harness}}/bin/lib/lane-gate.sh"
    [ -r "$lg" ] || lg="$_RP_LIB/lane-gate.sh"
    command -v lib_env_apply >/dev/null 2>&1 || { [ -r "$lg" ] && . "$lg" >/dev/null 2>&1; }
    command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply review-post >/dev/null 2>&1
    printf '%s|%s' "${RP_RAW_CAP:-}" "${RP_TEXT_CAP:-}"
  ) || r="|"
  IFS='|' read -r _RP_RAW _RP_TEXT <<<"$r"
  _rp_digits "$_RP_RAW"  || _RP_RAW=$(_rp_default RP_RAW_CAP)
  _rp_digits "$_RP_TEXT" || _RP_TEXT=$(_rp_default RP_TEXT_CAP)
  return 0
}

# rp_findings <review-file> — one line per finding, "<n><TAB><headline>".
#   A finding is a numbered item (`1.` / `2)`), a `### Finding 2` header, a
#   bullet whose first bold token is `**Finding #3**`, or a plain bullet that
#   opens with the word: `- Finding 4 still applies` (BH-1625 — the shape a
#   re-review uses to walk the earlier findings, #1577). The numbers come from the
#   text itself, so an index line and the review below it agree; duplicates keep
#   the first. Numbered steps in prose ("1. run npm test") count as findings by
#   shape: that over-renders, which is the safe direction — the failure this lib
#   exists to stop is under-rendering.
rp_findings() {
  local f="${1:-}" line n hl seen=" "
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    n=""; hl=""
    if [[ "$line" =~ ^[[:space:]]*([0-9]{1,3})[.\)][[:space:]]+(.*)$ ]]; then
      n="${BASH_REMATCH[1]}"; hl="${BASH_REMATCH[2]}"
    elif [[ "$line" =~ ^[[:space:]]*#+[[:space:]]*[Ff]([Ii][Nn][Dd][Ii][Nn][Gg])?[[:space:]]*#?([0-9]{1,3})[[:space:]]*(.*)$ ]]; then
      n="${BASH_REMATCH[2]}"; hl="${BASH_REMATCH[3]}"
      hl="${hl#"${hl%%[![:space:]—:.-]*}"}"
    elif [[ "$line" =~ ^[[:space:]]*[-*][[:space:]]*\*\*[[:space:]]*[Ff]([Ii][Nn][Dd][Ii][Nn][Gg])?[[:space:]]*#?([0-9]{1,3})[[:space:]]*\**[[:space:]]*(.*)$ ]]; then
      n="${BASH_REMATCH[2]}"; hl="${BASH_REMATCH[3]}"
      hl="${hl#"${hl%%[![:space:]—:.-]*}"}"
    elif [[ "$line" =~ ^[[:space:]]*[-*][[:space:]]+[Ff][Ii][Nn][Dd][Ii][Nn][Gg][[:space:]]*#?([0-9]{1,3})([^0-9].*)?$ ]]; then
      n="${BASH_REMATCH[1]}"; hl="${BASH_REMATCH[2]}"
      hl="${hl#"${hl%%[![:space:]—:.-]*}"}"
    else
      continue
    fi
    case "$seen" in *" $n "*) continue ;; esac
    seen="$seen$n "
    printf '%s\t%s\n' "$n" "${hl:0:200}"
  done < "$f"
}

# rp_max_ref <review-file> — the largest finding number the text REFERENCES
#   ("finding #3", "findings #1-#3", "F#2"), or 0. This is the count the render
#   is measured against: the incident's verdict paragraph referenced #3 while
#   the body listed nothing at all.
rp_max_ref() {
  local f="${1:-}" m=0 n
  [ -f "$f" ] || { printf '0\n'; return 0; }
  while read -r n; do
    [ -n "$n" ] || continue
    [ "$n" -gt "$m" ] 2>/dev/null && m="$n"
  done < <(grep -oiE 'findings?[[:space:]]*#?[0-9]+([[:space:]]*(-|and|,|to)[[:space:]]*#?[0-9]+)*|(^|[^A-Za-z])F#[0-9]+' "$f" 2>/dev/null \
           | grep -oE '[0-9]+')
  printf '%s\n' "$m"
}

# rp_cap <file> <cap> <full-copy-path-or-empty> — the file, capped, saying so.
rp_cap() {
  local f="${1:-}" cap="${2:-20000}" full="${3:-}" size=0
  [ -f "$f" ] || return 0
  size=$(( $(wc -c < "$f" 2>/dev/null || echo 0) ))
  if [ "$size" -le "$cap" ]; then cat "$f"; return 0; fi
  head -c "$cap" "$f"
  if [ -n "$full" ]; then
    printf '\n[truncated at %s of %s chars; the full copy is in the build record at %s]\n' "$cap" "$size" "$full"
  else
    printf '\n[truncated at %s of %s chars; there was no build record to keep a full copy in]\n' "$cap" "$size"
  fi
}

# rp_render <review-file> <raw-json-or-empty> <persisted-prefix-or-empty> <out-body>
#           [prior-finding-count]
#   rc 0 = complete, rc 3 = PARSE_INCOMPLETE. The third argument is the prefix
#   rp_persist printed ("<rec>/rereview-<head8>"), so a truncation line can name
#   the full copy instead of gesturing at one; empty when nothing was persisted.
#   The fifth is the highest finding number of the PRIOR review this one
#   re-reads (rp_prior_count), 0 or absent for a first review: a re-review that
#   says "Finding 5 has moved on" is talking about THAT review's finding 5, so a
#   reference at or below it is satisfied by the prior review and is not a
#   finding this body owes (BH-1625, #1577). A reference above it is this
#   review's own and still fails closed when it cannot be rendered.
#   EVERY body leads with `**Verdict:** <v>` (BH-1625), the incomplete one too:
#   the verdict is what the gate acted on, and a PARSE_INCOMPLETE that hid it
#   left GitHub with no record of the approval that merged the PR.
rp_render() {
  local rf="${1:-}" jf="${2:-}" kept="${3:-}" out="${4:-}" prior="${5:-0}"
  local idx m ref verdict n hl why
  _rp_knobs
  case "$prior" in ''|*[!0-9]*) prior=0 ;; esac
  idx=$(rp_findings "$rf")
  m=$(printf '%s' "$idx" | grep -c . 2>/dev/null) || m=0
  ref=$(rp_max_ref "$rf")
  verdict=$(verdict_parse "$rf" 2>/dev/null) || verdict="(the review states no verdict)"
  # AN EMPTY (OR ABSENT) REVIEW FILE IS NOT A COMPLETE REVIEW. 0 findings
  # against 0 references compares equal, so without this an out file the lane
  # never wrote rendered as "**Verdict:** (the review states no verdict)" /
  # "0 findings returned, 0 rendered" — a body that looks like a clean APPROVE
  # of nothing. It fails closed with the rest.
  if [ -s "$rf" ] && { [ "$ref" -le "$m" ] || [ "$ref" -le "$prior" ]; }; then
    {
      printf '**Verdict:** %s\n\n' "$verdict"
      printf '%s findings returned, %s rendered\n' "$m" "$m"
      if [ "$m" -gt 0 ]; then
        while IFS=$'\t' read -r n hl; do
          [ -n "$n" ] || continue
          printf '%s. %s\n' "$n" "$hl"
        done <<< "$idx"
      fi
      printf '\n'
      rp_cap "$rf" "$_RP_TEXT" "${kept:+$kept.md}"
    } > "$out"
    return 0
  fi
  # FAIL CLOSED. The verdict talks about findings this body cannot show, so the
  # body says exactly that on its first line and carries the raw material.
  if [ -s "$rf" ]; then
    why="the verdict references finding #$ref but only $m findings could be rendered"
  else
    why="the review file is empty or missing — this lane produced no review text at all"
  fi
  {
    printf '**Verdict:** %s\n' "$verdict"
    printf 'PARSE_INCOMPLETE: %s\n' "$why"
    printf '%s findings returned, %s rendered\n\n' "$ref" "$m"
    printf 'The review is below exactly as the lane wrote it, with its raw envelope, so nothing is lost while this is read by hand.\n\n'
    printf 'The raw review:\n\n```text\n'
    rp_cap "$rf" "$_RP_RAW" "${kept:+$kept.md}"
    printf '\n```\n\nThe raw agent envelope:\n\n```json\n'
    if [ -s "$jf" ]; then
      rp_cap "$jf" "$_RP_RAW" "${kept:+$kept.json}"
    else
      printf '(no raw JSON envelope was written by the review lane)'
    fi
    printf '\n```\n'
  } > "$out"
  return 3
}

# rp_persist <rec> <head> <out-file> — the build record's copy, written BEFORE
#   the post. Prints the prefix it wrote ("<rec>/rereview-<head8>") so the
#   caller can name it in a log line; rc 1 when there is no record to write to,
#   which is a fact to log and never a reason to skip the comment.
#   cp-then-mv: a crash mid-copy leaves a .tmp, never a half review.
rp_persist() {
  local rec="${1:-}" head="${2:-}" out="${3:-}" h8 base
  case "$rec" in ''|-) return 1 ;; esac
  [ -d "$rec" ] || return 1
  # -s, not -f: an empty out file has nothing to keep, and copying it would
  # OVERWRITE the review an earlier tick persisted at this same head with a
  # zero-byte file. rc 1 here is "no copy was made", which the caller logs and
  # which never costs the comment.
  [ -s "$out" ] || return 1
  h8="${head:0:8}"; [ -n "$h8" ] || h8=nohead
  base="$rec/rereview-$h8"
  cp "$out" "$base.md.tmp" 2>/dev/null && mv -f "$base.md.tmp" "$base.md" 2>/dev/null || {
    rm -f "$base.md.tmp" 2>/dev/null; return 1; }
  if [ -s "$out.json" ]; then
    cp "$out.json" "$base.json.tmp" 2>/dev/null && mv -f "$base.json.tmp" "$base.json" 2>/dev/null || \
      rm -f "$base.json.tmp" 2>/dev/null
  fi
  printf '%s\n' "$base"
  return 0
}

# rp_prior_count <rec> <out-file> — the highest finding number of the review
#   this re-review re-reads: the build record's own review.md. 0 when there is
#   none, or when <out-file> IS that review (a first review has no prior, and
#   counting a file against itself would satisfy every reference it makes).
rp_prior_count() {
  local rec="${1:-}" out="${2:-}" pf n m=0
  case "$rec" in ''|-) printf '0\n'; return 0 ;; esac
  pf="$rec/review.md"
  [ -s "$pf" ] || { printf '0\n'; return 0; }
  [ -n "$out" ] && [ "$pf" -ef "$out" ] && { printf '0\n'; return 0; }
  while IFS=$'\t' read -r n _; do
    [ -n "$n" ] || continue
    [ "$n" -gt "$m" ] 2>/dev/null && m="$n"
  done < <(rp_findings "$pf")
  printf '%s\n' "$m"
}

# rp_slug_num <pr-url> — "<owner/repo> <number>", or rc 1 when the URL is not
#   a PR URL. Self-contained on purpose: this lib is sourced by two lanes with
#   different helper sets and must not depend on either one's URL parser.
rp_slug_num() {
  local url="${1:-}"
  [[ "$url" =~ ^https?://[^/]+/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/([0-9]+) ]] || return 1
  printf '%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

# rp_comment <pr-url> <body-file> — THE NETWORK STEP, AND IT IS REST.
#   `gh pr comment` wraps GraphQL, which is the credential that rate-limits
#   first and answers with silence (#768) — the reason BH-783 moved this lane's
#   comments onto bin/lib/gh-rest.sh. So the post goes through gh_rest_comment
#   and its three exit codes; a tree whose lane has not sourced gh-rest.sh gets
#   rc 75 here, by which point rp_persist has already written the review to the
#   build record and the caller logs a post that did not land.
rp_comment() {
  local url="${1:-}" bf="${2:-}" sn slug num
  command -v gh_rest_comment >/dev/null 2>&1 || return 75
  sn=$(rp_slug_num "$url") || return 75
  slug="${sn% *}"; num="${sn#* }"
  gh_rest_comment "$slug" "$num" "$bf"
}

# rp_post <rec> <head> <out-file> <pr-url> <footer> — persist, render, post.
#   Prints the persisted prefix (or "-") on stdout; returns the POST's OWN exit code,
#   so a caller can log a post that did not land instead of swallowing it in
#   `|| true`. The render verdict (complete / PARSE_INCOMPLETE) does not change
#   whether we post: both bodies are worth posting, and only one of them is a
#   lie.
rp_post() {
  local rec="${1:-}" head="${2:-}" out="${3:-}" url="${4:-}" footer="${5:-}"
  local kept body rc=0
  kept=$(rp_persist "$rec" "$head" "$out") || kept=""
  body=$(mktemp) || { printf -- '-\n'; return 70; }
  rp_render "$out" "$out.json" "$kept" "$body" "$(rp_prior_count "$rec" "$out")"
  [ -n "$footer" ] && printf '\n\n---\n%s\n' "$footer" >> "$body"
  # The path of the review itself, so a caller logging a failed post names a
  # file somebody can open rather than a prefix they have to guess at.
  if [ -n "$kept" ]; then printf '%s.md\n' "$kept"; else printf -- '-\n'; fi
  rp_comment "$url" "$body" >/dev/null 2>&1; rc=$?
  rm -f "$body"
  return "$rc"
}
