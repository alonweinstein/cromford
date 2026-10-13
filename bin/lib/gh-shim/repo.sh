#!/bin/bash
# bin/lib/gh-shim/repo.sh — `gh repo view` and `gh repo clone` (#769 chunk 2).
# Sourced by bin/gh-rest-shim step 6, never executed.
#
# `repo clone` IS THE ONE PLACE A HANDLER EXECS SOMETHING OTHER THAN gshim_api:
# cloning is git's job, and gh's own clone is a REST read plus a git exec. The
# token NEVER reaches argv or .git/config — the origin stays the bare https URL
# (bin/lib/merge-conductor-lib.sh expects exactly that) and auth arrives as a
# credential helper in the environment, so a box that never ran
# `gh auth setup-git` still clones and nothing writes a credential to disk.

GSHIM_REPO_FIELDS='name,defaultBranchRef,isArchived,url,nameWithOwner,isPrivate,description'

gshim_cmd_repo_view() {
  local arg body
  arg=$(gshim_pr_arg)
  [ -n "$GSHIM_FIELDS" ] || [ -n "$GSHIM_JQ" ] || gshim_passthru untranslated
  [ -n "$arg" ] && [ -z "$GSHIM_REPO" ] && GSHIM_REPO="$arg"
  gshim_slug ""
  gshim_fields_ok "$GSHIM_REPO_FIELDS"
  body=$(gshim_api "repos/$GSHIM_SLUG") || exit $?
  gshim_emit "$(printf '%s' "$body" | jq -c '{
    name: .name,
    defaultBranchRef: (if .default_branch == null then null else {name: .default_branch} end),
    isArchived: .archived,
    url: .html_url,
    nameWithOwner: .full_name,
    isPrivate: .private,
    description: .description
  }')"
}

gshim_cmd_repo_clone() {
  local slug="" dir="" flags=() seen_dd=0 i=2 a n
  # THE ORIGINAL ARGV, not GSHIM_REST: everything after `--` belongs to git, and
  # the contract's universal parser has already eaten a `-q` there as its own
  # --jq spelling. Only argv still knows that `-- -q` meant "clone quietly".
  while [ "$i" -lt "${#GSHIM_ARGV[@]}" ]; do
    a="${GSHIM_ARGV[$i]}"
    if [ "$seen_dd" = 1 ]; then flags+=("$a"); i=$((i+1)); continue; fi
    case "$a" in
      --) seen_dd=1 ;;
      -R|--repo) i=$((i+1)) ;;
      -*) gshim_passthru "flag:$a" ;;
      *)  if [ -z "$slug" ]; then slug="$a"; else [ -n "$dir" ] || dir="$a"; fi ;;
    esac
    i=$((i+1))
  done
  # An https URL is normalised; anything else that is not owner/repo (a bare
  # repo name for the authenticated user, an Enterprise host) is gh's to resolve
  # — guessing an owner clones the wrong repository.
  case "$slug" in
    https://github.com/*) slug="${slug#https://github.com/}"; slug="${slug%.git}"; slug="${slug%/}" ;;
  esac
  [[ "$slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || gshim_passthru no-slug
  # The class admits `.` and `..` components (gshim_slug's own trap): `../x` would
  # clone https://github.com/../x.git. Same dot-component case as the contract.
  case "$slug" in .|..|./*|../*|*/.|*/..) gshim_passthru no-slug ;; esac

  gshim_tmp_cleanup
  export GH_REST_SHIM_DEPTH=$((GSHIM_DEPTH + 1))
  # APPEND at the next index, NEVER clobber: GIT_CONFIG_* is a list the caller
  # may already own. bin/lane-fence.sh:93-94 ships `core.hooksPath` to a fenced
  # lane through exactly these variables, and hard-setting COUNT=1 with the
  # helper at index 0 threw that pointer away — the clone ran outside its fence
  # with no error to say so. Non-numeric COUNT counts as 0 (lane-fence's own
  # sanitation) rather than a bash arithmetic error on the exec path.
  n="${GIT_CONFIG_COUNT:-0}"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  export "GIT_CONFIG_KEY_$n=credential.https://github.com.helper"
  export "GIT_CONFIG_VALUE_$n=!$GH_REAL auth git-credential"
  export GIT_CONFIG_COUNT=$((n + 1))
  exec git clone "https://github.com/$slug.git" ${dir:+"$dir"} ${flags[@]+"${flags[@]}"}
}
