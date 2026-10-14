#!/bin/bash
# bin/lib/tracker-gh-guard.sh — no GitHub ISSUE write on the app repo of a
# project whose tickets live off GitHub (settings row tracker_adapter.<project>
# = jira or linear, bin/lib/tracker.sh tracker_off_github).
#
# WHY HERE. Such a project still sits at fleet.conf column 4 `-`, and about a
# dozen lanes read that as "ticket TK-12 is GitHub issue #12 of the app repo":
# blocked-resolver, merge-conductor and merge-sweep close-outs, batch-resolve,
# unblocked-children, decompose-parent-close, hub-probe, hotfix-after-deploy,
# fly-pool, post-proposal, post-merge-verify, fc_file_issues, hold notes. They
# all reach GitHub through `gh`, and bin/gh-ledger/gh is the `gh` first on
# every lane's PATH, so it asks tgg_refuse before it runs anything.
#
# WHAT IS REFUSED, on a repo whose every column-4 `-` project is off GitHub:
#   gh issue create|comment|close|reopen|edit|delete|lock|unlock|pin|unpin|transfer|develop  -R/--repo <slug>
#   gh api <POST|PATCH|PUT|DELETE> [/]repos/<slug>/issues[/…]   (fields with no -X are a POST)
# EXCEPT a numbered path (issues/<n>/…) whose <n> is a pull request: PRs are
# still on GitHub, and REST comments on and labels of a PR go through issues/.
# Not seen: `gh issue …` with no -R (gh takes the cwd's repo), GraphQL
# mutations, and a gh run by absolute path past the shim.
#
# FAIL-OPEN, like tracker_off_github: a settings outage, no fleet.conf, no lib
# all allow the write, which is what every lane did before there was a row.
# Reads are never looked at, and only a write pays the lookups.
#
#   tgg_refuse <real gh> <gh argv…>  rc 0 = REFUSE (one stderr line, one
#                                    ALERTS line); rc 1 = let it through
# Off: GH_TRACKER_GUARD_OFF=1 or $HARNESS/flags/tracker-gh-guard-off.

# _tgg_target <argv…> — "<slug> <n or ->" for an issue write, nothing otherwise.
_tgg_target() {
  local a slug="" path="" method="" fields=0 prev="" n=""
  case "${1:-}" in
    issue)
      case "${2:-}" in create|comment|close|reopen|edit|delete|lock|unlock|pin|unpin|transfer|develop) ;; *) return 0 ;; esac
      for a in "$@"; do
        case "$prev" in -R|--repo) slug="$a" ;; esac
        case "$a" in --repo=*) slug="${a#--repo=}" ;; esac
        prev="$a"
      done
      slug="${slug#https://github.com/}"
      [ -n "$slug" ] && printf '%s -\n' "$slug"
      return 0 ;;
    api) ;;
    *) return 0 ;;
  esac
  for a in "$@"; do
    case "$prev" in -X|--method) method="$a" ;; esac
    case "$a" in
      --method=*) method="${a#--method=}" ;;
      -f|-F|--field|--raw-field|--input|--field=*|--raw-field=*|--input=*) fields=1 ;;
    esac
    [[ "$a" =~ ^/?repos/([^/]+/[^/]+)/issues(/([0-9]+))?(/|\?|$) ]] && { path="$a"; slug="${BASH_REMATCH[1]}"; n="${BASH_REMATCH[3]:-}"; }
    prev="$a"
  done
  [ -n "$path" ] || return 0
  [ -n "$method" ] || { [ "$fields" = 1 ] && method=POST; }
  case "$(printf '%s' "$method" | tr '[:lower:]' '[:upper:]')" in POST|PATCH|PUT|DELETE) ;; *) return 0 ;; esac
  printf '%s %s\n' "$slug" "${n:--}"
}

# _tgg_off_github_repo <slug> — rc 0 and the adapter when every column-4 `-`
# project with this repo has a jira or linear row.
_tgg_off_github_repo() {
  local h="${HARNESS:-/root/harness}" fc p any="" off="" a
  fc="$(dirname "${BASH_SOURCE[0]}")/../fleet-conf.sh"; [ -x "$fc" ] || fc="$h/bin/fleet-conf.sh"
  [ -x "$fc" ] || return 1
  command -v tracker_off_github >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/tracker.sh" 2>/dev/null || return 1
  for p in $("$fc" --projects 2>/dev/null); do
    [ "$("$fc" "$p" repo 2>/dev/null)" = "$1" ] && [ "$("$fc" "$p" board_prefix 2>/dev/null)" = - ] || continue
    any=1
    a=$(tracker_off_github "$p" 2>/dev/null) || return 1
    off="$a"
  done
  [ -n "$any" ] && printf '%s\n' "$off"
}

tgg_refuse() {
  local real="$1" t slug n off h="${HARNESS:-/root/harness}"
  shift
  [ "${GH_TRACKER_GUARD_OFF:-}" != 1 ] && [ ! -e "$h/flags/tracker-gh-guard-off" ] || return 1
  t=$(_tgg_target "$@"); [ -n "$t" ] || return 1
  slug="${t% *}"; n="${t#* }"
  off=$(_tgg_off_github_repo "$slug") || return 1
  # A pull request is still GitHub's, whatever the tracker.
  if [ "$n" != - ] && GH_LEDGER_DEPTH=9 "$real" api "repos/$slug/pulls/$n" --silent </dev/null >/dev/null 2>&1; then
    return 1
  fi
  echo "gh: refused — $slug's tickets live on $off (tracker_adapter), so a GitHub issue write there would hit the wrong ticket: gh $*" | cut -c1-400 >&2
  [ -x "$h/bin/alert-line.sh" ] && "$h/bin/alert-line.sh" "[tracker-gh-guard] refused a GitHub issue write on $slug (tickets on $off): gh ${1:-} ${2:-}${n:+ #$n}" >/dev/null 2>&1 </dev/null
  return 0
}
