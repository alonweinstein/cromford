#!/bin/bash
# bin/lib/verdict-parse.sh — THE one reader of a review's verdict line (BH-1625).
#
# WHY THIS EXISTS. Every lane that consumed a review used to grep for its own
# idea of a verdict: the LAST `VERDICT` token anywhere in the text
# (bin/lib/mc/rebase.sh, bin/review-prs.sh, bin/lib/review-post.sh), the last
# one ANCHORED anywhere (review-rescue, pr-url-reconcile), `tail -1 | grep -q
# APPROVE` (run-build's lenses), `tail -3 | grep -q "VERDICT: APPROVE"`
# (merge-sweep, classify, rebase-train, pipeline-health). The first shape is the
# dangerous one: a BLOCK review that ends by quoting an earlier
# "VERDICT: APPROVE" read as APPROVE, and the head-bound merge gate trusted it.
# Twenty-odd copies of three rules is how one of them stays wrong.
#
# THE RULE, and it is the whole lib:
#   * A verdict is a line that STARTS with the label (default `VERDICT`, any
#     case, optionally bolded or after a markdown heading) followed by an
#     optional colon and then the verdict word, which must end at a non-word
#     character. `VERDICT: **APPROVE**`, `**VERDICT:** BLOCK`, `## Verdict:
#     MERGE-WITH-NOTES` are verdicts. A verdict quoted mid-sentence, in a
#     `>` blockquote, in a list item, or inside a ``` fence is NOT.
#   * Only the review's FINAL BLOCK counts: its last $VERDICT_WINDOW_LINES
#     non-empty lines (a registered knob, catalog/lanes.d/_lib.json, id
#     `verdict-parse`), plus any extra lines a caller names with -x because it
#     knows its format puts that many more lines after the verdict.
#   * Two anchored verdict lines in the final block that DISAGREE are no
#     verdict at all. That is the fail-closed answer to a review whose final
#     block both states its own verdict and quotes another one.
#   * EXCEPT for an APPENDED artifact (-L). bin/run-build.sh's re-review
#     rounds APPEND to review.md / security-review.md / refute-review.md
#     ("Re-review after fixes; append to …"), so a short re-review puts its
#     APPROVE a line or two under the BLOCK it answers. There the LATEST
#     anchored line in the final block is the verdict — the old `tail -1`
#     contract, still anchored, so a mid-sentence, blockquoted, listed or
#     fenced quote is never read. A single-shot review (a head-bound
#     re-review, a posted comment, a lane's raw output) keeps the conflict
#     rule.
#   * No verdict is `unknown` (stdout) and rc 1. EVERY caller treats unknown as
#     not-APPROVE — a review we cannot read is never an approval.
#
# Sourced, never executed. NO side effect on source (BH-1644): a lane that
# sources this lib and never parses a verdict pays nothing. A full window
# resolve is a lib_env_apply — lane-gate, the settings cache, jq over the
# registry — ~277 ms per call on the hub (#1639 review). A lane that parses in
# a loop calls verdict_prime ONCE in its parent shell, right after its own
# lane_env_apply: it resolves once and EXPORTS $_VP_WINDOW, so every later
# parse — inside $(...) and in `bash -c` children too — reuses it. An unprimed
# caller still resolves per call (verdict_window's fallback). A window no
# source can give raises ONE ALERTS line per box per UTC day
# (_vp_alert_unresolved), and every parse stays unknown (fail closed).
# shellcheck shell=bash

_VP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"
# The per-process cache. Kept across a re-source, so sourcing the lib twice does
# not buy a second resolve.
_VP_WINDOW="${_VP_WINDOW:-}"

# _vp_is_pos_int <v> — rc 0 when v is a positive decimal integer.
_vp_is_pos_int() {
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  [ "$((10#$1))" -gt 0 ] 2>/dev/null
}

# verdict_window — print the final-block size in non-empty lines, rc 1 when no
#   source can give a positive integer (and then every parse is unknown).
#   Order: the env (a lane that already ran lib_env_apply, or an operator), the
#   settings contract (row > cached row > env > registry default, via
#   bin/lib/lane-gate.sh's lib_env_apply), then the registry default read from
#   this checkout's own catalog/lanes.d/_lib.json — the one source a box whose
#   $HARNESS has no rendered registry (a suite's scratch tree) still carries.
#   There is no literal fallback: a window nobody configured is unknown.
#   An env value still wins per call (an operator, a suite); otherwise the
#   per-process $_VP_WINDOW answers without resolving again.
verdict_window() {
  local w="${VERDICT_WINDOW_LINES:-}" lg
  if ! _vp_is_pos_int "$w" && _vp_is_pos_int "${_VP_WINDOW:-}"; then
    printf '%s\n' "$((10#$_VP_WINDOW))"; return 0
  fi
  if ! _vp_is_pos_int "$w"; then
    lg=""
    [ -n "${HARNESS:-${H:-}}" ] && lg="${HARNESS:-${H:-}}/bin/lib/lane-gate.sh"
    [ -n "$lg" ] && [ -r "$lg" ] || lg="$_VP_ROOT/bin/lib/lane-gate.sh"
    w=$(
      command -v lib_env_apply >/dev/null 2>&1 || { [ -r "$lg" ] && . "$lg" >/dev/null 2>&1; }
      command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply verdict-parse >/dev/null 2>&1
      printf '%s' "${VERDICT_WINDOW_LINES:-}"
    )
  fi
  if ! _vp_is_pos_int "$w" && command -v jq >/dev/null 2>&1; then
    w=$(jq -r '.libs[]? | select(.id == "verdict-parse") | .knobs[]?
               | select(.env == "VERDICT_WINDOW_LINES") | .default // empty' \
          "$_VP_ROOT/catalog/lanes.d/_lib.json" 2>/dev/null)
  fi
  _vp_is_pos_int "$w" || return 1
  printf '%s\n' "$((10#$w))"
}

# _vp_alert_unresolved — one ALERTS line per box ($HARNESS flags dir) per UTC
#   day when no source gives the window. The line is written BEFORE the flag is
#   touched (a crash between them is a duplicate, never silence). Never fails.
_vp_alert_unresolved() {
  local h="${HARNESS:-${H:-}}" day flag msg
  # No root: no flags dir to dedupe on and no ALERTS.log or lane-alert.sh to
  # send through, so nothing is sent and nothing is stamped.
  [ -n "$h" ] || return 0
  day=$(date -u +%Y%m%d)
  flag="$h/flags/alerted-verdict-window-$day"
  [ -e "$flag" ] && return 0
  msg="verdict-parse: VERDICT_WINDOW_LINES is unresolvable (no env, no settings row, no default in catalog/lanes.d/_lib.json id verdict-parse) — every verdict reads unknown, nothing merges on review. Set the knob or restore the registry entry."
  if [ -x "$h/bin/lane-alert.sh" ]; then
    "$h/bin/lane-alert.sh" --id verdict-window-unresolved verdict-parse "$msg" >/dev/null 2>&1 || true
  else
    mkdir -p "$h/logs" 2>/dev/null
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$msg" >> "$h/logs/ALERTS.log" 2>/dev/null || true
  fi
  mkdir -p "$h/flags" 2>/dev/null && : > "$flag" 2>/dev/null
  return 0
}

# verdict_prime — resolve the window ONCE in the calling shell and export it
#   as $_VP_WINDOW. Idempotent: an already-primed shell does not resolve again.
#   The resolve runs inside $(...), so a lib_env_apply that fails closed
#   (exit 75) cannot take the lane down. rc 1 (and the alert) when unresolvable.
verdict_prime() {
  _vp_is_pos_int "${_VP_WINDOW:-}" && { export _VP_WINDOW; return 0; }
  _VP_WINDOW=$(VERDICT_WINDOW_LINES="" verdict_window 2>/dev/null) || _VP_WINDOW=""
  export _VP_WINDOW
  _vp_is_pos_int "$_VP_WINDOW" && return 0
  _vp_alert_unresolved
  return 1
}

# verdict_parse [-l LABEL] [-w WORDS] [-x EXTRA] [-L] [-c] [FILE|-]
#   Print the verdict word of the review in FILE (stdin when FILE is absent or
#   `-`), rc 0; or `unknown`, rc 1.
#     -l LABEL  the line label, default VERDICT (letters, digits, _ and - only).
#     -w WORDS  the vocabulary, `|`-separated, default APPROVE|BLOCK.
#     -x EXTRA  lines the caller's format puts after the verdict line on top of
#               the knob (bin/lib/rb/review.sh: one per lens tag), default 0.
#     -L        the file is an APPENDED artifact: the latest anchored verdict in
#               the final block wins instead of a disagreement being unknown.
#     -c        the text is a posted COMMENT BODY: everything from its last line
#               that is exactly `---` (the harness footer rule) on is dropped
#               before the final block is measured.
#   A missing, unreadable or empty file is unknown.
verdict_parse() {
  local label=VERDICT words='APPROVE|BLOCK' extra=0 comment=0 latest=0 f="-" win opt OPTIND=1
  while getopts ':l:w:x:cL' opt; do
    case "$opt" in
      L) latest=1 ;;
      l) label="$OPTARG" ;;
      w) words="$OPTARG" ;;
      x) extra="$OPTARG" ;;
      c) comment=1 ;;
      *) printf 'unknown\n'; return 1 ;;
    esac
  done
  shift $((OPTIND - 1))
  [ $# -gt 0 ] && f="$1"
  # Validated before either reaches a regex: these are the only two caller
  # strings that become pattern text.
  case "$label" in ''|*[!A-Za-z0-9_-]*) printf 'unknown\n'; return 1 ;; esac
  case "$words" in ''|*[!A-Z0-9_\|-]*|'|'*|*'|'|*'||'*) printf 'unknown\n'; return 1 ;; esac
  case "$extra" in ''|*[!0-9]*) printf 'unknown\n'; return 1 ;; esac
  win=$(verdict_window) || { _vp_alert_unresolved; printf 'unknown\n'; return 1; }
  win=$((win + 10#$extra))
  if [ "$f" != "-" ]; then
    [ -r "$f" ] || { printf 'unknown\n'; return 1; }
  fi
  awk -v label="$label" -v words="$words" -v win="$win" -v comment="$comment" -v latest="$latest" '
    function up(s) { return toupper(s) }
    {
      sub(/\r$/, "")
      raw[NR] = $0
    }
    END {
      last = NR
      if (comment == 1) {
        for (i = NR; i >= 1; i--) if (raw[i] ~ /^[ \t]*---[ \t]*$/) { last = i - 1; break }
      }
      # Fence state is a property of the WHOLE text, so it is walked from the
      # top; only then is the final block cut from the bottom.
      fence = 0; n = 0
      for (i = 1; i <= last; i++) {
        line = raw[i]
        if (line ~ /^[ \t]*(```|~~~)/) { fence = !fence; infence[i] = 1; if (line !~ /^[ \t]*$/) keep[++n] = i; continue }
        infence[i] = fence
        if (line !~ /^[ \t]*$/) keep[++n] = i
      }
      nw = split(words, W, "|")
      ulabel = up(label)
      pre = "^[ \t]*(#+[ \t]*)?(\\*\\*|__)?" ulabel "(\\*\\*|__)?:?(\\*\\*|__)?[ \t]*(\\*\\*|__|`)?"
      found = ""; conflict = 0
      start = n - win + 1; if (start < 1) start = 1
      for (k = start; k <= n; k++) {
        i = keep[k]
        if (infence[i]) continue
        line = raw[i]
        # The label is matched without regard to case; the verdict word is not.
        m = match(up(line), pre)
        if (!m) continue
        rest = substr(line, RLENGTH + 1)
        hit = ""
        for (j = 1; j <= nw; j++) {
          wl = length(W[j])
          if (substr(rest, 1, wl) != W[j]) continue
          nxt = substr(rest, wl + 1, 1)
          if (nxt ~ /[A-Za-z0-9_-]/) continue
          if (length(W[j]) > length(hit)) hit = W[j]
        }
        if (hit == "") continue
        if (found == "" || latest == 1) found = hit
        else if (found != hit) conflict = 1
      }
      if (found == "" || conflict) { print "unknown"; exit 1 }
      print found
    }' "$f"
}

# verdict_is <WORD> [verdict_parse options] [FILE|-] — rc 0 only when the parsed
#   verdict is exactly WORD. Unknown is never WORD, so `verdict_is APPROVE f`
#   is the fail-closed approval test every gate should use.
verdict_is() {
  local want="${1:-}" got
  shift || return 1
  [ -n "$want" ] || return 1
  got=$(verdict_parse "$@") || return 1
  [ "$got" = "$want" ]
}
