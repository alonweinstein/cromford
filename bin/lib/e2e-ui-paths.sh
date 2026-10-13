#!/bin/bash
# bin/lib/e2e-ui-paths.sh — answers ONE question: "can this diff change a
# rendered route?" Sourced, never executed. It is deliberately NOT
# bin/lib/e2e-paths.sh, and the two must not be merged: that file answers "may a
# red E2E check block a merge" and has to stay broad, so it fires on
# package.json, lockfiles, every route.ts, workflow files and auth code — the
# things that can break a browser suite indirectly. This file is the narrow
# side. It is for deciding whether driving a preview build is worth the wait, so
# it wants a rendered surface: the app/pages trees, components, public assets,
# stylesheets, middleware and the Next config. A diff of server libraries,
# tests, stories, migrations or CI config changes nothing a browser would see
# and must not hit here, even though several of those DO hit e2e-paths.sh.
#
#   E2E_UI_GLOBS_DEFAULT  the default glob list, space-separated
#   e2e_ui_globs          prints E2E_PATHS when it holds a non-blank token,
#                         else the default; commas count as separators
#   e2e_ui_path_hit       reads newline-separated paths on STDIN; rc 0 when any
#                         path matches any glob, rc 1 when none does
#
# E2E_PATHS REPLACES the default list, it does not extend it; blank or
# whitespace-only means the default (an unset knob is not "match nothing").
E2E_UI_GLOBS_DEFAULT='src/app/** app/** pages/** components/** public/** *.css middleware.* next.config.*'

e2e_ui_globs() {
  local g="${E2E_PATHS:-}"
  g="${g//,/ }"
  case "$g" in
    *[![:space:]]*) printf '%s\n' "$g" ;;
    *)              printf '%s\n' "$E2E_UI_GLOBS_DEFAULT" ;;
  esac
}

e2e_ui_path_hit() { # stdin: one path per line
  local -a globs
  local p g
  # read -ra, NEVER `for g in $globs`: an unquoted *.css pathname-expands
  # against whatever the caller's cwd happens to hold and silently rewrites the
  # list (tests/e2e-ui-paths-lib-test.sh runs the whole matrix from a cwd with
  # an a.css in it for exactly this reason).
  IFS=' ,' read -ra globs <<<"$(e2e_ui_globs)"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    for g in "${globs[@]}"; do
      # "a,,b" yields an empty field, and */"" would match every path.
      [ -n "$g" ] || continue
      # A glob with a / matches at the start of the path or after any / — a real
      # path segment, so components/** hits src/components/Nav.tsx while app/**
      # stays off apps/web/x.ts. A glob without a / matches the basename:
      # middleware.* hits src/middleware.ts but not middleware-utils.ts.
      # * and ** both cross / inside a case pattern.
      # shellcheck disable=SC2254 # $g is unquoted on purpose: the glob IS the pattern
      case "$g" in
        */*) case "$p" in $g|*/$g) return 0 ;; esac ;;
        *)   case "${p##*/}" in $g) return 0 ;; esac ;;
      esac
    done
  done
  return 1
}
