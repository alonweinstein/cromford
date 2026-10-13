#!/bin/bash
# bin/lib/revdep-lib.sh — REVERSE DEPENDENCIES: who was waiting on the thing that
# just closed. Sourced, never executed. Safe under `set -u`.
#
# THE DIRECTION THE EVENT PATH WAS MISSING (the operator, 2026-09-15). Every wake this
# fleet reads names the object that MOVED: an issue closed, a PR merged, a sha
# landed on main. Nothing in that row, and nothing bin/wake-loop.sh derived from
# it, ever named the tickets whose bodies say `Blocked-by: #<that object>` — and
# those are the only tickets a closure makes buildable. Two shapes of the same
# hole on project-5 today:
#
#   #721's blockers #718, #719 and #720 all closed at 05:33Z. Three wakes, three
#   ticks, each scoped to the issue that closed, and #721 never launched.
#   #671 says `Blocked-by: #670`. #670 was closed by hand and the tick that
#   followed was scoped to #670 — the one ticket with nothing left to do.
#
# bin/unblocked-children.sh already knows how to answer "who does this closure
# release", in the exact `UNBLOCKED` / `STACKABLE` vocabulary the triage prompt
# reads. What it needs is the closure, and a closure only reaches it as a
# bin/gate-diff.sh line — which the ai-build-scoped board fingerprint cannot
# carry for an issue that has lost the label (a decomposed parent) or for one the
# last consumed tick already absorbed. So these helpers carry the closure by
# hand: revdep_diff_lines() spells it in the shape that pass reads, and
# revdep_note_closed()/revdep_take_closed() carry it ACROSS BOXES, because the
# wake loop runs on the hub and the tick it buys runs on the project's own box.
#
# Nothing here writes to GitHub or launches anything. Every function answers a
# question; the CALLER decides what that means.
#
#   revdep_on [harness]                  -> 1 | 0        (kill switch)
#   revdep_diff_lines <n>...             -> gate-diff-shaped "went closed" lines
#   revdep_closed_file <harness> <proj>  -> the path the two below agree on
#   revdep_note_closed <harness> <proj> <n>...   -> record closures for one tick
#   revdep_take_closed <harness> <proj>  -> print them ONCE, then forget them
#   revdep_issue_state <repo> <n>        -> OPEN | CLOSED, rc 1 when unreadable
#   revdep_merged_closes <repo> <window> -> the issues merged PRs closed, lately
#   revdep_keys                          -> stdin: scope lines, stdout: their keys

# The App-token helper, only if the caller has not sourced it already. A lib never
# resets: the reset restores the process-start token and would un-arm its caller.
# _revdep_root -> $HARNESS, else $H, else nothing (BH-2613). A [harness]
# argument wins over it. No root loads no helper, reads no flag, and records or
# takes no closure, so nothing is ever closed on a no-root read.
_revdep_root() { printf '%s' "${HARNESS:-${H:-}}"; }
# shellcheck source=bin/lib/gh-app-auth.sh
command -v gh_auth_for >/dev/null 2>&1 || { [ -n "$(_revdep_root)" ] && [ -r "$(_revdep_root)/bin/lib/gh-app-auth.sh" ] && . "$(_revdep_root)/bin/lib/gh-app-auth.sh" 2>/dev/null; }
# BH-1651: the issue-state read is REST (gh_rest_issue_state_var), not GraphQL.
# shellcheck source=bin/lib/gh-rest-var.sh
command -v gh_rest_issue_state_var >/dev/null 2>&1 || { [ -r "${BASH_SOURCE[0]%/*}/gh-rest.sh" ] && . "${BASH_SOURCE[0]%/*}/gh-rest.sh" 2>/dev/null; } || true

# revdep_on [harness] -> 1 | 0   (DEFAULT 1 — the expansion is ON)
#
# THE KILL FLAG. 0 puts bin/wake-loop.sh and bin/unblocked-children.sh back to
# 2026-09-14 byte for byte: a wake carries only the object that moved, no closure
# is ever shipped or read, and no decompose parent is ever closed. The flag file
# sits beside the env var for the same reason flags/dep-verify-off does — an
# operator killing this at 3am should not have to edit env/global.env on a box.
revdep_on() {
  local h="${1:-$(_revdep_root)}"
  [ -n "$h" ] && [ -e "$h/flags/revdep-wake-off" ] && { printf '0\n'; return 0; }
  case "${REVDEP_WAKE:-1}" in 0|no|off|false) printf '0\n' ;; *) printf '1\n' ;; esac
}

# revdep_diff_lines <issue-number>... -> one bin/gate-diff.sh line per closure
#
# The shape is not decorative: bin/unblocked-children.sh's trigger regex is
# `CHANGED <n> … (state|status): open -> closed`, and this is the one sentence
# that says "this number went closed" in it. Same line bin/wake-loop.sh's
# closed_diff() has written for the push path since 2026-09-13; it lives here now
# because the issue and parent-close paths need to say the same thing.
revdep_diff_lines() {
  local n
  for n in "$@"; do
    case "$n" in ''|*[!0-9]*) continue ;; esac
    printf 'board issues: CHANGED %s "" (state: open -> closed)\n' "$n"
  done
}

# revdep_closed_file <harness> <project> -> state/wake-closed-<project>
#
# The twin of state/wake-keys-<project>: the keys say what the wake was ABOUT,
# this says what CLOSED. bin/wake-loop.sh writes it (locally, or over the same
# ssh that carries the un-brake) and bin/unblocked-children.sh reads it on the
# box, so a closure the board fingerprint cannot carry still reaches the pass
# that acts on it. No existence check — the writer needs the name first.
revdep_closed_file() { [ -n "${1:-}" ] || return 0; printf '%s/state/wake-closed-%s\n' "$1" "${2:-}"; }

# revdep_note_closed <harness> <project> <n>... -> rc 0 when the file was written
#
# OVERWRITES rather than accumulates, and that is deliberate: the file belongs to
# ONE launch — the closures that launch is about — and a union across wakes would
# refresh its mtime forever, which is the only thing keeping a missed file from
# scoping a tick days later.
revdep_note_closed() {
  local h="${1:-}" p="${2:-}" f n out=""
  shift 2 2>/dev/null || return 1
  f=$(revdep_closed_file "$h" "$p")
  [ -n "$f" ] || return 1
  for n in "$@"; do
    case "$n" in ''|*[!0-9]*) continue ;; esac
    [ "${#n}" -le 9 ] || continue
    case " $out " in *" $n "*) continue ;; esac
    out="$out $n"
  done
  [ -n "$out" ] || return 1
  mkdir -p "$h/state" 2>/dev/null || return 1
  printf '%s\n' $out > "$f" 2>/dev/null || return 1
  return 0
}

# revdep_take_closed <harness> <project> -> the numbers, once
#
# ONE-SHOT, exactly like state/wake-<project> and state/wake-keys-<project>: a
# closure that outlived its wake would scope some later tick to a release nobody
# rang about. REVDEP_CLOSED_TTL_S (default 3600) is the second guard, for the
# file that no tick ever came to collect — a box whose gate answered SKIP, or an
# ssh that landed on a box whose cron was wedged.
revdep_take_closed() {
  local h="${1:-}" p="${2:-}" f age body ttl="${REVDEP_CLOSED_TTL_S:-3600}"
  case "$ttl" in ''|*[!0-9]*) ttl=3600 ;; esac
  f=$(revdep_closed_file "$h" "$p")
  [ -n "$f" ] && [ -s "$f" ] || return 1
  age=$(( $(date +%s) - $(date -r "$f" +%s 2>/dev/null || echo 0) ))
  body=$(tr -s ' \t' '\n' < "$f" 2>/dev/null | grep -E '^[0-9]{1,9}$' | awk '!seen[$0]++' | head -50)
  # Removed whatever it says and whether or not it is still fresh: a file that
  # outlived its window must not be read by the NEXT tick either.
  rm -f "$f" 2>/dev/null || true
  [ "$age" -le "$ttl" ] || return 1
  [ -n "$body" ] || return 1
  printf '%s\n' "$body"
}

# revdep_issue_state <repo> <n> -> OPEN | CLOSED   (rc 1 = we could not read it)
#
# BY NUMBER, never from a label-scoped list, for the reason bin/unblocked-
# children.sh's fetch_state() gives: the size gate strips ai-build from a
# decomposed parent, so "not in the list" and "closed" are different facts and
# only this call can tell them apart. rc 1 is "unknown", and every caller here
# treats unknown as "nothing closed" — a wake that expands nothing costs a wait,
# a wake that expands on a guess costs a build.
revdep_issue_state() {
  local r="${1:-}" n="${2:-}" s
  [ -n "$r" ] || return 1
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  command -v gh >/dev/null 2>&1 || return 1
  command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$r" || true
  command -v gh_rest_issue_state_var >/dev/null 2>&1 || return 1
  s=
  gh_rest_issue_state_var s "$r" "$n" || return 1
  s=$(printf '%s' "$s" | tr -d '[:space:]' | tr 'a-z' 'A-Z')
  case "$s" in OPEN|CLOSED) printf '%s\n' "$s"; return 0 ;; esac
  return 1
}

# revdep_merged_closes <repo> [window-seconds] -> the issue numbers lately-merged
#   PRs closed, newest first, at most 20.
#
# WHY NOT JUST THE CLOSED-ISSUE LIST. bin/wake-loop.sh's closed_diff() asks for
# `--label ai-build --state closed`, and the issue a merge closes is very often
# NOT in that list: a decomposed parent has had the label stripped, and a ticket
# closed by GitHub's own `closes #N` keyword may never have carried it. The PR
# says so itself — `closingIssuesReferences` is GitHub's own resolution of the
# keyword — and the body/title scan is the fallback for a token or a gh old
# enough not to answer that field.
revdep_merged_closes() {
  local r="${1:-}" w="${2:-900}" cut
  [ -n "$r" ] || return 0
  case "$w" in ''|*[!0-9]*) w=900 ;; esac
  command -v gh >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0
  command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$r" || true
  cut=$(( $(date +%s) - w ))
  timeout 30 gh pr list -R "$r" --state merged --limit 30 \
      --json number,mergedAt,title,body,closingIssuesReferences 2>/dev/null \
    | jq -r --argjson cut "$cut" '
        .[]? | select(.mergedAt != null)
             | select((.mergedAt | try fromdateiso8601 catch 0) >= $cut)
             | ((.closingIssuesReferences // [])[]? | .number),
               (((.body // "") + " " + (.title // ""))
                 | [scan("(?i)(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)[[:space:]]+#([0-9]+)")]
                 | .[]? | .[0])' 2>/dev/null \
    | grep -E '^[0-9]{1,9}$' | awk '!seen[$0]++' | head -20
  return 0
}

# revdep_keys — stdin: UNBLOCKED/STACKABLE scope lines. stdout: their ticket keys.
#
# The key is the third field of `board <list>: <CLASS> <key> …`, which is the
# same place bin/gate-diff.sh puts it and the same place bin/wake-loop.sh's push
# path already reads it from. Bounded, because these become a filename and part
# of a remote shell command on the owning box.
revdep_keys() {
  sed -nE 's/^board [^:]+: (UNBLOCKED|STACKABLE) ([A-Za-z0-9._-]{1,48}).*/\2/p' \
    | awk '!seen[$0]++' | head -20
}
