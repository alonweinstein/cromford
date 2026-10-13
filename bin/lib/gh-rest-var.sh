#!/bin/bash
# bin/lib/gh-rest-var.sh — the variable-assigning face of bin/lib/gh-rest.sh.
# Sourced from the end of gh-rest.sh, never executed.
#
# WHY IT EXISTS (BH-1485). gh-rest.sh's header states the caller rule: run a
# helper as a plain command with `> file` and read the file, because
# GH_REST_STATUS and GH_REST_REASON are assigned in the shell that CALLS the
# helper and a `$( )` is a subshell that then dies. Twenty-one call sites had
# written `st=$(gh_rest_pr_state …)` anyway — the rc survived, so every decision
# stayed right, and the status did not, so every 403, every 5xx and every dead
# network read `HTTP 000` in the log and in ALERTS.log. BH-781 said the same
# sentence about the same bug ("every alert said HTTP 000 for a 403 the library
# had classified correctly") and it kept coming back, because the correct shape
# is four lines of mktemp/redirect/cat/rm and the wrong one is eight characters.
#
# So the correct shape is a function. `gh_rest_pr_state_var st "$slug" "$n"`
# reads exactly like the assignment it replaces, leaves the two variables real
# in the caller's shell, and is what `tests/gh-rest-no-subshell-lint.sh` leaves
# a converted site able to say.
#
# THE CONTRACT IS gh-rest.sh's, UNCHANGED. Each variant returns its helper's own
# rc — 0 / 44 / 75, and nothing else — and assigns the helper's stdout to the
# named variable with the trailing newlines stripped, byte for byte what the
# `$( )` it replaces produced. On any non-zero rc the variable is set EMPTY,
# which is what the old capture did too (a failed helper prints nothing), so no
# converted site had to change how it reads the value. Nothing here performs a
# read of its own, sniffs a body, or touches GH_REST_STATUS on a path the
# library did not already own.
#
# WHY NOT A NAMEREF. `local -n` would alias the caller's variable, but it is
# bash 4.3+ and it dies on a name collision with one of this file's own locals.
# `printf -v` is older than anything the fleet runs and resolves the name in the
# caller's scope by the same dynamic scoping every other helper here relies on.
# The `_ghrv_` prefix on every local is what keeps `gh_rest_pr_state_var t …`
# from assigning into this file's own temp-file variable; a caller that asks for
# a name in that reserved prefix gets bad-args rather than a silent wrong write.
#
# gh-rest: no-graphql
#
# No `set -e`, no `exit`, no side effect at source time, and the same errexit
# discipline as gh-rest.sh: every fallible call is `cmd || rc=$?`, never
# `cmd; rc=$?`, so a caller under `set -e` reaches the mapping and leaves no
# temp file behind.
if [ -n "${GH_REST_VAR_LIB:-}" ]; then return 0 2>/dev/null; fi
GH_REST_VAR_LIB=1

# A name this file may write into: a shell identifier, and not one of its own.
_ghrv_name_ok() { # _ghrv_name_ok <name>
  [[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  case "${1}" in _ghrv_*) return 1 ;; esac
  return 0
}

# _ghrv_finish <outvar> <tmpfile> <rc> — assign, clean up, pass the rc through.
# Declares NO local named by the caller, and the `$( )` here wraps `cat`, never
# a helper: the two variables the library set are already in this shell.
_ghrv_finish() {
  local _ghrv_v=
  if [ "${3:-1}" = 0 ]; then _ghrv_v=$(cat "$2" 2>/dev/null || true); fi
  rm -f "$2"
  printf -v "$1" '%s' "$_ghrv_v"
  return "${3:-75}"
}

# _ghrv_run <outvar> <helper> [args...] — the one place the prescribed
# mktemp/`> file`/read shape is written down.
_ghrv_run() {
  local _ghrv_out="${1:-}" _ghrv_fn="${2:-}" _ghrv_t _ghrv_rc=0
  if ! _ghrv_name_ok "$_ghrv_out" || ! command -v "$_ghrv_fn" >/dev/null 2>&1; then
    GH_REST_STATUS=000; GH_REST_REASON=bad-args; return 75
  fi
  shift 2
  _ghrv_t=$(mktemp "${TMPDIR:-/tmp}/gh-rest-var.XXXXXX") || {
    GH_REST_STATUS=000; GH_REST_REASON=bad-args; return 75; }
  "$_ghrv_fn" "$@" > "$_ghrv_t" || _ghrv_rc=$?
  _ghrv_finish "$_ghrv_out" "$_ghrv_t" "$_ghrv_rc"
}

# The four variants the converted sites need. Argument order after <outvar> is
# the helper's own, unchanged, so a site converts by moving the variable from
# the left of the `=` to the front of the argument list.
gh_rest_var()             { _ghrv_run "${1:-}" gh_rest              "${@:2}"; }
gh_rest_pr_state_var()    { _ghrv_run "${1:-}" gh_rest_pr_state     "${@:2}"; }
gh_rest_pr_list_var()     { _ghrv_run "${1:-}" gh_rest_pr_list      "${@:2}"; }
gh_rest_issue_state_var() { _ghrv_run "${1:-}" gh_rest_issue_state  "${@:2}"; }
