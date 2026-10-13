#!/bin/bash
# bin/lane-fence.sh — install the act-time fence for the NON-claude build lanes
# (SDLC item 8, 2026-09-06). The per-command half is bin/lane-shims/_fence.sh;
# read its header first, it carries the why and the honest limits.
#
# WHY A GIT HOOK AS WELL AS THE SHIMS. A PATH shim only ever sees a binary
# invoked BY NAME. An absolute `/usr/bin/git`, a python subprocess, and a
# wrapper the session writes itself all walk straight past it. A pre-push hook
# is git calling US: it fires for every push however git was reached, and
# `--no-verify` is itself a `git` command the shim classifies. Belt and braces
# on the one iron law with no undo — main moving.
#
# IT DOES NOT DISABLE THE REPO'S OWN HOOKS. `core.hooksPath` replaces the whole
# directory, so pointing git at ours would silently switch husky off — and
# project-4, one of the two projects this fence exists for, has a `.husky`
# pre-push. So the installed directory FORWARDS every hook the repo already had
# and our pre-push CHAINS to the original one after its own check. A fence that
# quietly removes a project's own checks has taken more than it gave.
#
# WHY ENV AND NOT `git config`. The pointer ships as GIT_CONFIG_COUNT /
# GIT_CONFIG_KEY_n / GIT_CONFIG_VALUE_n in the lane's environment (git >= 2.31),
# so it lives exactly as long as the session does. Writing core.hooksPath into
# the repo would be a persistent edit to a checkout shared with every other
# worktree and with the box's own operators.
#
# subcommands:
#   hooks-env [repo-dir]        install the per-repo hooks dir for that repo and
#                               print the env assignments that point git at it,
#                               one KEY=VALUE per line. Nothing (rc 1) if the
#                               directory is not a git repo or the install fails.
#   pre-push [--chain <hook>] <remote> <url>
#                               the hook body itself; refs arrive on stdin.
#
# LANE_FENCE (default 1) means the same here as in the shim: 1 refuses the push,
# warn prints the reason and lets it through, 0 is never installed at all.
set -uo pipefail

HARNESS="${HARNESS:-/root/harness}"
SELF="$(cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)/$(basename -- "$0")"
FENCE="${LANE_FENCE_SHIM:-$(dirname -- "$SELF")/lane-shims/_fence.sh}"
[ -x "$FENCE" ] || FENCE="$HARNESS/bin/lane-shims/_fence.sh"

# Written, then renamed: a hook git reads half-way through a write is a hook
# that fails open on the one push it was installed to stop.
_write() { # _write <path> <body>
  printf '%s\n' "$2" > "$1.tmp.$$" 2>/dev/null || return 1
  chmod +x "$1.tmp.$$" 2>/dev/null || return 1
  mv -f "$1.tmp.$$" "$1" 2>/dev/null || { rm -f "$1.tmp.$$" 2>/dev/null; return 1; }
}

hooks_env() {
  local repo="${1:-$PWD}" top orig dest h name base chain
  command -v git >/dev/null 2>&1 || return 1
  # -u GIT_CONFIG_COUNT: read the repo's OWN hooks path even when a fence is
  # already pointing git somewhere else (a nested install, a resumed lane).
  top=$(env -u GIT_CONFIG_COUNT git -C "$repo" rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -n "$top" ] || return 1
  orig=$(env -u GIT_CONFIG_COUNT git -C "$top" rev-parse --git-path hooks 2>/dev/null) || return 1
  [ -n "$orig" ] || return 1
  case "$orig" in /*) ;; *) orig="$top/$orig" ;; esac
  # Keyed on the ORIGINAL directory, the same reason agent-call.sh keys its
  # merged settings file on its input list: parallel builds share this box, and
  # a fixed path would let one worktree's forwarders answer another's hooks.
  dest="$HARNESS/state/lane-fence-hooks-$(printf '%s' "$orig" | cksum | cut -d' ' -f1)"
  mkdir -p "$dest" 2>/dev/null || return 1
  chain=""
  # Rebuilt from scratch every install, and every forwarder checks its target
  # is still there before exec'ing it. The directory is keyed on $orig and is
  # ours alone, but it OUTLIVES the hooks it was built from: husky regenerates
  # .husky/_ on install, a branch may not carry husky at all. A stale forwarder
  # exec'ing a deleted path exits 127, and git reads 127 as "hook failed" —
  # which is a fence bricking commits it was never asked to have an opinion on.
  rm -f "$dest"/* 2>/dev/null
  if [ -d "$orig" ]; then
    for h in "$orig"/*; do
      [ -f "$h" ] && [ -x "$h" ] || continue
      name=$(basename -- "$h")
      case "$name" in *.sample) continue ;; esac
      if [ "$name" = pre-push ]; then chain="$h"; continue; fi
      _write "$dest/$name" "#!/bin/bash
# lane-fence forwarder (SDLC item 8): this repo's own $name hook, unchanged.
# Gone means gone: a hook the repo no longer has is not a failure of this one.
[ -x \"$h\" ] || exit 0
exec \"$h\" \"\$@\"" || return 1
    done
  fi
  _write "$dest/pre-push" "#!/bin/bash
# lane fence (SDLC item 8): refuse a push to main, then run the repo's own hook.
exec \"$SELF\" pre-push ${chain:+--chain \"$chain\" }\"\$@\"" || return 1
  # Append to whatever GIT_CONFIG_* the caller already had rather than
  # overwriting index 0 — clobbering someone else's key here would be a config
  # change nobody asked for, made invisibly.
  base="${GIT_CONFIG_COUNT:-0}"; case "$base" in ''|*[!0-9]*) base=0 ;; esac
  printf 'GIT_CONFIG_COUNT=%s\nGIT_CONFIG_KEY_%s=core.hooksPath\nGIT_CONFIG_VALUE_%s=%s\n' \
    "$((base + 1))" "$base" "$base" "$dest"
}

pre_push() {
  local chain="" remote refs reason rc lref lsha rref rsha
  if [ "${1:-}" = --chain ]; then chain="${2:-}"; shift 2; fi
  remote="${1:-origin}"
  refs=$(cat)
  while read -r lref lsha rref rsha; do
    [ -n "$rref" ] || continue
    # Asked as the command it IS, so the answer comes from the one classifier
    # rather than from a second, weaker copy of the same rule living here.
    reason=$("$FENCE" --classify "pre-push hook" "git push $remote ${lref:-HEAD}:$rref" "$PWD" 2>/dev/null)
    rc=$?
    [ "$rc" = 2 ] || continue
    printf '%s\n' "$reason" >&2
    if [ "${LANE_FENCE:-1}" = warn ]; then
      echo "LANE_FENCE=warn on this box: the push above was NOT stopped and the attempt was filed. Set LANE_FENCE=1 to refuse it." >&2
      continue
    fi
    return 1
  done <<<"$refs"
  # The repo's own pre-push still runs, with the refs it expects on stdin.
  if [ -n "$chain" ] && [ -x "$chain" ]; then
    { [ -n "$refs" ] && printf '%s\n' "$refs"; } | "$chain" "$@"
    return $?
  fi
  return 0
}

case "${1:-}" in
  hooks-env) shift; hooks_env "${1:-$PWD}" ;;
  pre-push)  shift; pre_push "$@" ;;
  *) echo "usage: lane-fence.sh hooks-env [repo-dir] | pre-push [--chain <hook>] <remote> <url>" >&2; exit 64 ;;
esac
