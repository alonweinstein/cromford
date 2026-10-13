#!/bin/bash
# bin/lib/review-saving.sh — a trivial diff gets a cheaper reviewer, and every
# review the harness does not buy at full price is a stage_events row (BH-2545).
#
# WHY THIS EXISTS. The paid review lanes (bin/review-prs.sh,
# bin/review-autopilot.sh) bought the build.review model for every head,
# whether the diff was a lockfile bump or a rewrite of the merge conductor. And
# the three places that already skip a review because the patch did not change
# (BH-2310: the two lanes' verdict replays, the conductor's rebind_patch_id)
# said so only in their own log files, so nobody could count the saving.
#
# Three functions, and they are the whole lib:
#   review_diff_class <diff-file>    -> "<docs|lock|tests|code> <changed lines>"
#   review_trivial_pick <diff-file> <project> <default-model>
#                                    -> RT_CLASS RT_LINES RT_ACTION RT_MODEL
#   review_saving_event <project> <lane> <slug> <num> <sha> <VERDICT> <detail>
#                                    -> one stage_events row, fail-open
#
# NOTHING HERE SKIPS A REVIEW. A trivial diff is still reviewed, by the model
# the review.trivial model_routes row names (seeded in worker/jobs/schema.sql),
# and only when REVIEW_TRIVIAL_MODE is `route` AND its class is one of
# REVIEW_TRIVIAL_ROUTE_CLASSES (docs by default: a lockfile or a test-dir edit
# can loosen a supply chain or a gate, so those are measured, not routed). The
# default mode is `shadow`: classify and record the event, change nothing. Only
# bin/review-prs.sh acts on `routed`, and a routed APPROVE there is advisory:
# it never merges, and the head is re-reviewed on the full model next tick. The
# autopilot lane records the event and keeps its model. No model id lives here.
#
# Knobs (catalog/lanes.d/_lib.review-saving.json, settings rows
# lib.review-saving.review_trivial_mode / .review_trivial_max_lines /
# .review_trivial_route_classes):
#   REVIEW_TRIVIAL_MODE          off | shadow | route. Anything else is off, logged.
#   REVIEW_TRIVIAL_MAX_LINES     a trivial diff has at most this many changed lines;
#                                0 means no diff is trivial. Non-digits are off, logged.
#   REVIEW_TRIVIAL_ROUTE_CLASSES the classes route mode may route, a space-separated
#                                subset of `docs lock tests`. Any other token is
#                                off, logged; a trivial class outside it is shadow.
#
# Sourced, never executed. No side effects on source.

_RS_LIB="${BASH_SOURCE[0]%/*}"
_RS_KEY="none"; _RS_MODE=""; _RS_MAX=""; _RS_CLASSES=""

_rs_log() {
  local h="${HARNESS:-${H:-/root/harness}}"
  mkdir -p "$h/logs" 2>/dev/null
  printf '%s review-saving: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$1" >> "$h/logs/review-saving.log" 2>/dev/null
  return 0
}

# _rs_path_class <path> -> docs | lock | tests | code, on stdout.
#   Exclusions first: agent instructions, CI, guard and registry inputs are not
#   documentation whatever their extension, so they are always `code`.
#   Guard inputs are matched anywhere in the path, not just the basename: an
#   allowlist DIRECTORY, a ratchet baseline, tests/known-container-failures.txt
#   (bin/lib/suite-runner.sh reads it to excuse a failing suite) and a tests-dir
#   lint, guard or ratchet script all loosen a gate when edited, so none of them
#   is an inert test.
_rs_path_class() {
  local p="$1" b="${1##*/}"
  case "$b" in
    CLAUDE.md|CLAUDE.local.md|AGENTS.md|RTK.md|SKILL.md) echo code; return ;;
  esac
  case "/$p" in
    *allowlist*|*denylist*|*baseline*|*by-design*|*known-*failures*)
      echo code; return ;;
    */rules/*|*/prompts/*|*/skills/*|*/.claude/*|*/.github/*|*/.harness/*|*/guardrails/*|*/checks/*|*/catalog/*|*/docs/verification-map/*|*/tests/lib/*)
      echo code; return ;;
    /tests/*|/test/*)
      case "$b" in *lint*|*guard*|*ratchet*) echo code; return ;; esac ;;
  esac
  case "/$p" in
    /tests/*|/test/*|/e2e/*|*/__tests__/*|*/__mocks__/*|*/fixtures/*|*/testdata/*|*/__snapshots__/*)
      echo tests; return ;;
  esac
  case "$b" in
    *.test.*|*.spec.*|*_test.*|*.snap) echo tests; return ;;
    package-lock.json|yarn.lock|pnpm-lock.yaml|bun.lockb|Cargo.lock|poetry.lock|uv.lock|composer.lock|Gemfile.lock|go.sum|requirements.lock)
      echo lock; return ;;
    *.md|*.rst|*.adoc) echo docs; return ;;
  esac
  echo code
}

# review_diff_class <diff-file> -> "<class> <lines>" on stdout, always rc 0.
#   Every path a file section names (both sides of the `diff --git` header, the
#   rename/copy lines, the ---/+++ pair) is classified, so a rename out of bin/
#   is code. One class across every path, else `code`. A quoted path, a header
#   that cannot be split, no header at all, or an unreadable file is `code`.
#   Lines: `+`/`-` lines, the per-file ---/+++ header pair excluded.
review_diff_class() {
  local f="${1:-}" line rest p cls="" c lines=0 inhdr=0 bad=0 half
  local -a paths=()
  [ -r "$f" ] || { echo "code 0"; return 0; }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "diff --git "*)
        inhdr=1; rest="${line#diff --git }"
        case "$rest" in
          \"*) bad=1 ;;
          a/*)
            # Unquoted: `a/P b/P` splits exactly in half when the path did not
            # change; otherwise it must hold exactly one " b/".
            half=$(( (${#rest} - 1) / 2 ))
            if [ $(( ${#rest} % 2 )) = 1 ] && [ "${rest:half:3}" = " b/" ] && [ "${rest:2:half-2}" = "${rest:half+3}" ]; then
              paths+=("${rest:2:half-2}")
            elif [ "$(printf '%s' "$rest" | grep -o ' b/' | wc -l)" = 1 ]; then
              p="${rest%% b/*}"; paths+=("${p#a/}" "${rest#* b/}")
            else
              bad=1
            fi ;;
          *) bad=1 ;;
        esac ;;
      "@@"*) inhdr=0 ;;
      "rename from "*|"rename to "*|"copy from "*|"copy to "*)
        [ "$inhdr" = 1 ] && { p="${line#* * }"; case "$p" in \"*) bad=1 ;; *) paths+=("$p") ;; esac; } ;;
      "--- "*|"+++ "*)
        if [ "$inhdr" = 1 ]; then
          p="${line:4}"
          case "$p" in
            /dev/null) ;;
            \"*) bad=1 ;;
            a/*|b/*) paths+=("${p#?/}") ;;
            *) bad=1 ;;
          esac
        else
          lines=$((lines + 1))
        fi ;;
      [+-]*) lines=$((lines + 1)) ;;
    esac
  done < "$f"
  if [ "$bad" = 1 ] || [ "${#paths[@]}" = 0 ]; then echo "code $lines"; return 0; fi
  for p in "${paths[@]}"; do
    c=$(_rs_path_class "$p")
    [ "$c" = code ] && { cls=code; break; }
    if [ -z "$cls" ]; then cls="$c"; elif [ "$cls" != "$c" ]; then cls=code; break; fi
  done
  echo "$cls $lines"
  return 0
}

# _rs_default <ENV> — the knob's default in this checkout's registry file, or nothing.
_rs_default() {
  jq -r --arg e "$1" '.libs[]? | select(.id == "review-saving") | .knobs[]?
                      | select(.env == $e) | .default // empty' \
    "$_RS_LIB/../../catalog/lanes.d/_lib.review-saving.json" 2>/dev/null
  return 0
}

# _rs_knobs — the three knobs into $_RS_MODE / $_RS_MAX / $_RS_CLASSES. Order: operator row >
#   cached row > env > registry default, through lane-gate.sh's lib_env_apply in
#   a subshell (its fail-closed exit 75 cannot end the lane), then the default in
#   THIS checkout's registry file (bin/lib/review-post.sh _rp_knobs is the
#   precedent). Neither is a literal. A value outside the accepted set is `off`
#   and named once in logs/review-saving.log (D11: reject, never clamp).
_rs_knobs() {
  local k="${REVIEW_TRIVIAL_MODE-}|${REVIEW_TRIVIAL_MODE+set}|${REVIEW_TRIVIAL_MAX_LINES-}|${REVIEW_TRIVIAL_MAX_LINES+set}|${REVIEW_TRIVIAL_ROUTE_CLASSES-}|${REVIEW_TRIVIAL_ROUTE_CLASSES+set}" r c
  [ "$k" = "$_RS_KEY" ] && return 0
  _RS_KEY="$k"
  r=$(
    lg="${HARNESS:-${H:-/root/harness}}/bin/lib/lane-gate.sh"
    [ -r "$lg" ] || lg="$_RS_LIB/lane-gate.sh"
    command -v lib_env_apply >/dev/null 2>&1 || { [ -r "$lg" ] && . "$lg" >/dev/null 2>&1; }
    command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply review-saving >/dev/null 2>&1
    printf '%s|%s|%s' "${REVIEW_TRIVIAL_MODE:-}" "${REVIEW_TRIVIAL_MAX_LINES:-}" "${REVIEW_TRIVIAL_ROUTE_CLASSES:-}"
  ) || r="||"
  IFS='|' read -r _RS_MODE _RS_MAX _RS_CLASSES <<<"$r"
  [ -n "$_RS_MODE" ] || _RS_MODE=$(_rs_default REVIEW_TRIVIAL_MODE)
  [ -n "$_RS_MAX" ]  || _RS_MAX=$(_rs_default REVIEW_TRIVIAL_MAX_LINES)
  [ -n "$_RS_CLASSES" ] || _RS_CLASSES=$(_rs_default REVIEW_TRIVIAL_ROUTE_CLASSES)
  for c in $_RS_CLASSES; do
    case "$c" in
      docs|lock|tests) ;;
      *) _rs_log "REVIEW_TRIVIAL_ROUTE_CLASSES has '$c', not one of docs|lock|tests — trivial routing is off"; _RS_MODE=off; break ;;
    esac
  done
  case "$_RS_MAX" in
    ''|*[!0-9]*) _rs_log "REVIEW_TRIVIAL_MAX_LINES='$_RS_MAX' is not a whole number — trivial routing is off"; _RS_MODE=off ;;
  esac
  case "$_RS_MODE" in
    off|shadow|route) ;;
    *) _rs_log "REVIEW_TRIVIAL_MODE='$_RS_MODE' is not off|shadow|route — trivial routing is off"; _RS_MODE=off ;;
  esac
  return 0
}

# review_trivial_pick <diff-file> <project> <default-model>
#   Sets RT_CLASS RT_LINES RT_ACTION RT_MODEL in the caller's shell (never run
#   it in $(...)). RT_ACTION is empty when the diff is not trivial or the mode is
#   off (RT_MODEL is the default), `shadow` (RT_MODEL is the default: shadow
#   mode, or route mode with a class outside REVIEW_TRIVIAL_ROUTE_CLASSES),
#   `routed` (RT_MODEL is the review.trivial route), or `no-route` (route mode,
#   but the role has no route: RT_MODEL is the default and the review runs as
#   before).
review_trivial_pick() {
  local diff="${1:-}" project="${2:-}" def="${3:-}" m
  RT_ACTION=""; RT_MODEL="$def"
  read -r RT_CLASS RT_LINES <<<"$(review_diff_class "$diff")"
  _rs_knobs
  [ "$_RS_MODE" = off ] && return 0
  [ "$RT_CLASS" = code ] && return 0
  [ "${_RS_MAX:-0}" -gt 0 ] && [ "${RT_LINES:-0}" -le "$_RS_MAX" ] || return 0
  if [ "$_RS_MODE" = shadow ]; then RT_ACTION=shadow; return 0; fi
  case " $_RS_CLASSES " in *" $RT_CLASS "*) ;; *) RT_ACTION=shadow; return 0 ;; esac
  if ! command -v model_for >/dev/null 2>&1; then
    # review_model loads the resolver inside $(...), so the lane's shell may not
    # have it: load it the same way, beside this lib first.
    # shellcheck source=bin/lib/model-route.sh
    if [ -r "$_RS_LIB/model-route.sh" ]; then . "$_RS_LIB/model-route.sh"
    elif [ -r "${HARNESS:-/root/harness}/bin/lib/model-route.sh" ]; then . "${HARNESS:-/root/harness}/bin/lib/model-route.sh"; fi
  fi
  m=""
  command -v model_for >/dev/null 2>&1 && m=$(model_for review.trivial "$project" 2>/dev/null)
  if [ -n "$m" ]; then RT_ACTION=routed; RT_MODEL="$m"; else RT_ACTION=no-route; fi
  return 0
}

# review_saving_event <project> <lane> <slug> <num> <sha> <VERDICT> <detail>
#   One stage_events row (stage `review-saving`) on its own jobs row
#   (kind=review-saving, ticket `review-saving/<lane>/<slug>#<num>@<sha>`), closed
#   at once. Fail-open: no jobs client, a refused or failed job_open, and nothing
#   is recorded and the caller carries on. JOB_ID is never read or set, so the
#   row a lane bills its model spend to cannot move. Always rc 0.
review_saving_event() {
  local project="${1:-}" lane="${2:-}" slug="${3:-}" num="${4:-}" sha="${5:-}" verdict="${6:-}" detail="${7:-}" id meta
  [ -n "$project" ] && [ -n "$verdict" ] || return 0
  command -v job_open >/dev/null 2>&1 && command -v job_event >/dev/null 2>&1 || return 0
  meta=$(jq -nc --arg l "$lane" --arg s "$slug" --arg n "$num" --arg h "$sha" --arg v "$verdict" \
    '{lane:$l, slug:$s, pr:$n, sha:$h, saving:$v}' 2>/dev/null) || meta=""
  id=$(job_open "$project" "review-saving/$lane/$slug#$num@$sha" review-saving review-saving "" "$meta" 2>/dev/null) || return 0
  [ -n "$id" ] || return 0
  job_event "$id" review-saving "$verdict" "$detail" >/dev/null 2>&1 || true
  command -v job_update >/dev/null 2>&1 && job_update "$id" status=done stage=done >/dev/null 2>&1
  return 0
}
