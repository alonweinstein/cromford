#!/bin/bash
# bin/lib/pr-self-check.sh — BH-5798: the pre-review self-check. Does the PR
# body match the head it is about? Decided from git and the body text alone,
# before a lead review is bought. Sourced, never executed: no `exit`, no output
# at source time. Callers: bin/pr-self-check.sh (CLI), bin/lead-review-enqueue.sh.
#
# psc_check <repo> <base-ref> <head-sha> <body-file> [ticket-file]
#   One line per finding on stdout: `REFUSE <rule>: <why>` or `NOTE <rule>: <why>`.
#   rc 0 nothing refused | 1 a rule refused | 2 could not run (no repo, the head
#   or base will not resolve, no body, no catalog).
#   The rules are rows of $PR_SELF_CHECK_CATALOG (default catalog/pr-self-check.tsv
#   beside this lib): id, mode (refuse|note|off), param (ignore globs), what. A
#   rule with no row is off. #5790's section rules join as more rows.
#
# THE RULES
#   closes-not-met  the body says Closes/Fixes/Resolves #N and an acceptance item
#                   is not met: a `- [ ]` item, or a line that is not a checked
#                   `- [x]` item and says "not met" or REFUTED, inside a section
#                   whose heading names acceptance, self-check or evidence. A
#                   partial build must say Refs.
#   evidence-head   every sha the body binds evidence to — `head <sha>` in a
#                   heading, or `<!-- evidence-head: <sha> -->` — is the head, or
#                   a sha where none of the PR's files differ from the head
#                   (param globs excepted; a tree diff, so a rebased head counts).
#                   A PR file changed after it: a human `head <sha>` claim is
#                   refused, the builder's marker (which fix rounds and rebases
#                   never rewrite) is a note. A sha the repo does not have is
#                   refused. A body with no evidence sha at all is a note.
#   body-*          (BH-5790) a PR-body section the lead review would BLOCK on:
#                   Why, an acceptance section or gate table, mutation evidence
#                   for a new suite, the D1 / kill-knob callout, the live probe
#                   the ticket names. WHEN (param) and WHAT COUNTS (match) are the
#                   row's own data (catalog header). The ticket text is the 5th
#                   argument or $PSC_TICKET_FILE; none = a NOTE for ticket=.
#                   $PR_SELF_CHECK_ONLY (an ERE on the rule id) runs a subset.
#   plan-files      every file the PR changes (base...head, param globs excepted)
#                   is named by the plan's `## Files to touch` section, or by a
#                   line under `## Files outside the plan` with a reason after it.
#                   The plan is the one .harness/specs/*/plan.md the PR changes.
#                   No plan, or no such section: a note.

_psc_lib_dir() { (cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd); }

# _psc_rows — the catalog rows, comments stripped:
#   id<TAB>mode<TAB>param<TAB>match<TAB>what   (an empty field reads `-`)
_psc_rows() {
  local cat="${PR_SELF_CHECK_CATALOG:-$(_psc_lib_dir)/../../catalog/pr-self-check.tsv}"
  [ -r "$cat" ] || return 1
  awk -F'\t' '!/^[[:space:]]*#/ && NF >= 2 && $1 != "" {
    print $1 "\t" $2 "\t" ($3 == "" ? "-" : $3) "\t" ($5 == "" ? "-" : $5) "\t" ($4 == "" ? "-" : $4) }' "$cat"
}

# _psc_any_glob <globs> <paths> — rc 0 when a path matches a glob in the list
_psc_any_glob() {
  local p
  while IFS= read -r p; do [ -n "$p" ] && _psc_ignored "$p" "$1" && return 0; done <<<"$2"
  return 1
}

# _psc_body_fires <repo> <base> <head> <param> <files> <ticket-file>
#   rc 0 the rule applies, 1 it does not, 3 it cannot tell (a ticket= trigger
#   with no ticket text and nothing else fired). The triggers are the catalog
#   header's: always, added=, touched=, knob, ticket=.
_psc_body_fires() {
  local repo="$1" base="$2" head="$3" files="$5" tk="$6" t trig=() unk=0 added kd
  IFS=';' read -r -a trig <<<"$4"
  for t in "${trig[@]}"; do
    case "$t" in
      always) return 0 ;;
      added=*)
        added=$(git -C "$repo" diff --no-renames --diff-filter=A --name-only "$base...$head" 2>/dev/null)
        _psc_any_glob "${t#added=}" "$added" && return 0 ;;
      touched=*) _psc_any_glob "${t#touched=}" "$files" && return 0 ;;
      knob)
        # Captured first: grep -q on a git pipe is a SIGPIPE race under pipefail.
        kd=$(git -C "$repo" diff --no-renames -U0 "$base...$head" -- 'catalog/lanes.d/*.json' 2>/dev/null)
        grep -qE '^\+[[:space:]]*"env"[[:space:]]*:' <<<"$kd" && return 0 ;;
      ticket=*)
        if [ -z "$tk" ] || [ ! -s "$tk" ]; then unk=1
        else _psc_section "$tk" 'done[- ]when|acceptance' | grep -qiE -- "${t#ticket=}" && return 0; fi ;;
    esac
  done
  [ "$unk" = 1 ] && return 3
  return 1
}

# _psc_body_shows <body> <match> — rc 0 when the body shows one alternative
_psc_body_shows() {
  local m alts=()
  IFS=';' read -r -a alts <<<"$2"
  for m in "${alts[@]}"; do
    case "$m" in
      section=*)
        awk -v re="${m#section=}" '
          function done_() { if (on && words >= 3) found = 1 }
          /^#+[[:space:]]/ { done_(); on = (tolower($0) ~ tolower(re)); words = 0; next }
          on { n = split($0, w, /[^A-Za-z]+/); for (i = 1; i <= n; i++) if (length(w[i]) >= 2) words++ }
          END { done_(); exit !found }' "$1" && return 0 ;;
      line=*) grep -qiE -- "${m#line=}" "$1" && return 0 ;;
      table) awk 'prev ~ /^[[:space:]]*\|/ && $0 ~ /^[[:space:]]*\|[[:space:]:|-]*-/ {f = 1} {prev = $0} END {exit !f}' "$1" && return 0 ;;
    esac
  done
  return 1
}

# _psc_ignored <path> <globs> — rc 0 when a glob in the comma list matches
_psc_ignored() {
  local p="$1" g gl=()
  [ "${2:--}" = - ] && return 1
  # read -a, never `for g in $2`: an unquoted list is pathname-expanded against
  # the caller's working directory before the match ever runs.
  IFS=, read -r -a gl <<<"$2"
  for g in "${gl[@]}"; do
    # shellcheck disable=SC2053  # the glob is the point
    [[ "$p" == $g ]] && return 0
  done
  return 1
}

# _psc_section <body> <heading-regex> — the lines under every heading matching
# the (case-insensitive) regex, up to the next heading of the same or a higher
# level (BH-6191): `### C0` under `## Files to touch` is part of it.
_psc_section() {
  awk -v re="$2" '/^#+[[:space:]]/ { lv = match($0, /[^#]/) - 1
      if (on && lv > lvl) next
      on = (tolower($0) ~ tolower(re)); lvl = lv; next } on' "$1"
}

_psc_closes_not_met() { # <body> -> the not-met lines, rc 0 when Closes + not met
  grep -qiE '(^|[^a-z])(closes|fixes|resolves)[[:space:]]+#[0-9]+' "$1" || return 1
  local nm
  # A checkbox line is decided by its box alone: `- [x] ... not met is refused`
  # is a met item that happens to name the rule. Any other line counts when it
  # says "not met" or REFUTED.
  # A table row (the builder's ## Evidence table) names claims and their
  # verdicts; its text is not an item, so it never counts (lead review
  # lr-5828). The match lower-cases the line itself: IGNORECASE is gawk only.
  nm=$(_psc_section "$1" 'acceptance|self-check|evidence' \
        | awk '/^[[:space:]]*\|/ { next }
               /^[[:space:]]*[-*][[:space:]]+\[ \]/ { print; next }
               /^[[:space:]]*[-*][[:space:]]+\[[xX]\]/ { next }
               tolower($0) ~ /not met|refuted/ { print }' | head -5)
  [ -n "$nm" ] || return 1
  printf '%s\n' "$nm"
}

_psc_evidence_shas() { # <body> -> `<kind> <sha>` a line; kind human | marker
  # human: a `head <sha>` claim in a heading. marker: the builder's
  # <!-- evidence-head: <sha> --> (bin/lib/rb/pr.sh), which no fix round or
  # conductor rebase rewrites.
  { grep -iE '^#+[[:space:]].*\bhead[[:space:]]+[0-9a-f]{7,40}\b' "$1" \
      | grep -oiE '\bhead[[:space:]]+[0-9a-f]{7,40}\b' | awk '{print "human " $2}'
    grep -oE '<!--[[:space:]]*evidence-head:[[:space:]]*[0-9a-f]{7,40}' "$1" | grep -oE '[0-9a-f]{7,40}$' | awk '{print "marker " $1}'
  } | tr 'A-F' 'a-f' | awk '!s[$0]++'
}

psc_check() {
  local repo="${1:-}" base="${2:-}" head="${3:-}" body="${4:-}" ticket="${5:-${PSC_TICKET_FILE:-}}"
  local rows id mode param match what rc=0 files plan s full later f nm reasons missing frc pf ek
  [ -d "$repo" ] && [ -r "$body" ] || { echo "pr-self-check: no repo or no body"; return 2; }
  head=$(git -C "$repo" rev-parse -q --verify "$head^{commit}" 2>/dev/null) || { echo "pr-self-check: head does not resolve"; return 2; }
  git -C "$repo" rev-parse -q --verify "$base^{commit}" >/dev/null 2>&1 || { echo "pr-self-check: base $base does not resolve"; return 2; }
  rows=$(_psc_rows) || { echo "pr-self-check: no catalog"; return 2; }
  files=$(git -C "$repo" diff --no-renames --name-only "$base...$head" 2>/dev/null) || { echo "pr-self-check: the diff will not read"; return 2; }
  _psc_say() { # <mode> <rule> <text>
    case "$1" in refuse) echo "REFUSE $2: $3"; rc=1 ;; note) echo "NOTE $2: $3" ;; esac
  }
  while IFS=$'\t' read -r id mode param match what; do
    [ "$mode" = off ] && continue
    # --only (PR_SELF_CHECK_ONLY, an ERE on the rule id): the build's fix-body
    # round and CI run the body rules alone.
    if [ -n "${PR_SELF_CHECK_ONLY:-}" ] && ! grep -qE -- "$PR_SELF_CHECK_ONLY" <<<"$id"; then continue; fi
    case "$id" in
      closes-not-met)
        if nm=$(_psc_closes_not_met "$body"); then
          _psc_say "$mode" "$id" "the body closes the issue, but an acceptance item is not met ($(printf '%s' "$nm" | head -1 | sed 's/^[[:space:]]*//' | cut -c1-120)); say Refs #N and list what is left"
        fi ;;
      evidence-head)
        s=$(_psc_evidence_shas "$body")
        if [ -z "$s" ]; then
          echo "NOTE $id: no evidence sha in the body (\`head <sha>\` in a heading, or <!-- evidence-head: <sha> -->)"
          continue
        fi
        # THE TREE DECIDES, NOT THE HISTORY (lead review lr-5828): the evidence
        # still holds when no file this PR changes differs between the
        # evidence sha and the head (param globs excepted). That keeps a
        # conductor rebase, which moves the sha out of the head's history, from
        # reading as stale. When a PR file did change after it, a human's own
        # `head <sha>` claim is refused, and the builder's marker is a NOTE: a
        # fix round pushes new heads and never rewrites the body, so holding
        # every fixed PR for it would stall them all.
        while read -r ek s; do
          [ -n "$s" ] || continue
          if ! full=$(git -C "$repo" rev-parse -q --verify "$s^{commit}" 2>/dev/null); then
            # The hub clone fetches only the base and the head, so after a
            # rebase the builder's old marker sha is not there (lead review
            # lr-5828-da3826282). The marker is the build's own record: a NOTE.
            # A human's own claim still has to name a sha the repo has.
            if [ "$ek" = marker ]; then
              echo "NOTE $id: the builder's evidence is on ${s:0:12}, which this clone does not have (an older head before a rebase); the lead review reads the head"
            else
              _psc_say "$mode" "$id" "evidence names ${s:0:12}, which this repo does not have"
            fi
            continue
          fi
          [ "$full" = "$head" ] && continue
          later=""
          while IFS= read -r f; do
            [ -n "$f" ] || continue
            _psc_ignored "$f" "$param" && continue
            grep -qxF -- "$f" <<<"$files" && later="$later $f"
          done < <(git -C "$repo" diff --no-renames --name-only "$full" "$head" 2>/dev/null)
          [ -z "$later" ] && continue
          if [ "$ek" = marker ]; then
            echo "NOTE $id: the builder's evidence is on ${s:0:12}, and the PR's files changed after it:$(printf '%s' "$later" | cut -c1-200); the lead review reads the head"
          elif git -C "$repo" merge-base --is-ancestor "$full" "$head" 2>/dev/null; then
            _psc_say "$mode" "$id" "evidence names ${s:0:12}, but the PR's files changed after it:$(printf '%s' "$later" | cut -c1-200); rerun it on ${head:0:12}"
          else
            _psc_say "$mode" "$id" "evidence names ${s:0:12}, which is not in the head's history and whose PR files differ from the head:$(printf '%s' "$later" | cut -c1-200)"
          fi
        done <<<"$s" ;;
      plan-files)
        plan=$(grep -E '^\.harness/specs/[^/]+/plan\.md$' <<<"$files" | head -1)
        # Into a file first, never `git show | grep -q`: the early exit is a
        # SIGPIPE on git, and pipefail would turn a found section into "none".
        # A private temp file: the caller's body directory may be read-only.
        pf=$(mktemp "${TMPDIR:-/tmp}/psc-plan.XXXXXX" 2>/dev/null) || { echo "NOTE $id: no temp file for the plan"; continue; }
        [ -n "$plan" ] && git -C "$repo" show "$head:$plan" > "$pf" 2>/dev/null
        if ! grep -qiE '^#+[[:space:]]+files to touch' "$pf"; then
          rm -f "$pf"
          echo "NOTE $id: no plan with a \"Files to touch\" section in this PR"; continue
        fi
        reasons=$(_psc_section "$body" 'files outside the plan')
        missing=""
        while IFS= read -r f; do
          [ -n "$f" ] || continue
          _psc_ignored "$f" "$param" && continue
          _psc_section "$pf" 'files to touch' | grep -qF -- "$f" && continue
          # a reason line names the path and says something after it
          grep -F -- "$f" <<<"$reasons" | grep -qE "$(printf '%s' "$f" | sed 's/[.[\*^$/]/\\&/g')[\`]*[[:space:]]*[:—-]+[[:space:]]*[^[:space:]]" && continue
          missing="$missing $f"
        done <<<"$files"
        rm -f "$pf"
        [ -z "$missing" ] || _psc_say "$mode" "$id" "files not in the plan's \"Files to touch\" and with no reason under \"## Files outside the plan\":$(printf '%s' "$missing" | cut -c1-300)" ;;
      body-*)
        # BH-5790: a PR-body section the lead review would BLOCK on. When it
        # applies (param) the body must show it (match); both are catalog data.
        _psc_body_fires "$repo" "$base" "$head" "$param" "$files" "$ticket"; frc=$?
        case "$frc" in
          0) _psc_body_shows "$body" "$match" \
               || _psc_say "$mode" "$id" "the body is missing $what (add it to the PR body; catalog/pr-self-check.tsv says what counts)" ;;
          3) echo "NOTE $id: no ticket text, so whether the ticket asks for it is unknown ($what)" ;;
        esac ;;
      *) echo "NOTE $id: no such rule in bin/lib/pr-self-check.sh (catalog row ignored)" ;;
    esac
  done <<<"$rows"
  return "$rc"
}
