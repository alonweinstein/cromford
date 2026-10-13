#!/bin/bash
# bin/lib/ci-batch-escalate.sh — DOES THIS CHANGED PATH MAKE A MERGE-QUEUE BATCH
# RUN THE WHOLE CORPUS? (BH-4968) Sourced, never executed; no side effects at
# source time.
#
#   cbe_reason <path>   prints `selection input: <path>` and rc 0 when an
#                       escalate row matches and no allow row does; else prints
#                       nothing, rc 1
#   cbe_affects <spa|worker> <path>
#                       rc 0 when the path can change what the console-ui job
#                       (spa) or the worker-jobs job (worker) tests, rc 1 when
#                       it cannot (BH-4969). A path is affected when it is under
#                       the job's own tree (console-ui/, worker/ — built in, so
#                       deleting a row cannot un-gate the job) or a row of that
#                       kind matches. FAILS CLOSED: an unreadable rules file or
#                       an unknown kind answers rc 0.
#
# The rules are catalog/ci-batch-escalate.tsv (see its header), or
# CI_BATCH_ESCALATE_TSV. FAILS CLOSED: a rules file that cannot be read, or one
# with no escalate row, answers `selection input: catalog/ci-batch-escalate.tsv
# unreadable` for every path, because an empty rule set must never mean
# "nothing escalates".
_CBE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# _cbe_match <path> <pattern> — a trailing / is a prefix, anything else a glob.
_cbe_match() {
  case "$2" in
    */) [[ $1 == "$2"* ]] ;;
    *)  # shellcheck disable=SC2053 # the pattern IS a glob
        [[ $1 == $2 ]] ;;
  esac
}

cbe_reason() {
  local p="$1" tsv="${CI_BATCH_ESCALATE_TSV:-$_CBE_DIR/../../catalog/ci-batch-escalate.tsv}"
  local pat kind _why rows=0 esc=0 allow=0
  if [ -r "$tsv" ]; then
    while IFS=$'\t' read -r pat kind _why; do
      case "$pat" in ''|'#'*) continue ;; esac
      case "$kind" in
        escalate) rows=$((rows + 1)); _cbe_match "$p" "$pat" && esc=1 ;;
        allow)    _cbe_match "$p" "$pat" && allow=1 ;;
      esac
    done < "$tsv"
  fi
  if [ "$rows" -eq 0 ]; then
    echo "selection input: catalog/ci-batch-escalate.tsv unreadable"; return 0
  fi
  [ "$esc" = 1 ] && [ "$allow" = 0 ] || return 1
  echo "selection input: $p"
}

cbe_affects() {
  local k="$1" p="$2" tsv="${CI_BATCH_ESCALATE_TSV:-$_CBE_DIR/../../catalog/ci-batch-escalate.tsv}"
  local pat kind _why
  case "$k" in
    spa)    _cbe_match "$p" console-ui/ && return 0 ;;
    worker) _cbe_match "$p" worker/ && return 0 ;;
    *)      return 0 ;;
  esac
  [ -r "$tsv" ] || return 0
  while IFS=$'\t' read -r pat kind _why; do
    case "$pat" in ''|'#'*) continue ;; esac
    [ "$kind" = "$k" ] && _cbe_match "$p" "$pat" && return 0
  done < "$tsv"
  return 1
}
